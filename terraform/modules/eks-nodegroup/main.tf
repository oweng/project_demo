locals {
  name_prefix = "${var.cluster_name}-${var.node_group_name}"

  is_windows = can(regex("^WINDOWS_", var.ami_type))

  # Root device name differs between Windows (/dev/sda1) and Linux (/dev/xvda)
  root_device_name = local.is_windows ? "/dev/sda1" : "/dev/xvda"

  common_tags = merge(
    {
      Environment                                 = var.environment
      ManagedBy                                   = "terraform"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
      "karpenter.sh/discovery"                    = var.cluster_name
    },
    var.tags
  )
}

# ─── IAM: Node group role ─────────────────────────────────────────────────────

resource "aws_iam_role" "node_group" {
  name = "${local.name_prefix}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "worker_node_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "cni_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# SSM gives the ops team shell access to nodes without opening inbound SSH.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ─── Launch Template ──────────────────────────────────────────────────────────
# Managed node groups can take a launch template for settings not exposed directly
# on the node group resource: EBS encryption and IMDSv2 enforcement.

resource "aws_launch_template" "node_group" {
  name_prefix = "${local.name_prefix}-"
  description = "EKS node launch template for ${local.name_prefix} (${var.ami_type})"

  block_device_mappings {
    device_name = local.root_device_name

    ebs {
      volume_size           = var.disk_size_gb
      volume_type           = "gp3"
      encrypted             = true # HIPAA: all node volumes encrypted at rest
      delete_on_termination = true
    }
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # 2 hops needed for pods to reach IMDS via the node
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${local.name_prefix}-node"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.common_tags, {
      Name = "${local.name_prefix}-node-volume"
    })
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = local.common_tags
}

# ─── EKS Node Group ───────────────────────────────────────────────────────────

resource "aws_eks_node_group" "this" {
  cluster_name    = var.cluster_name
  node_group_name = var.node_group_name
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.subnet_ids

  ami_type       = var.ami_type
  capacity_type  = var.capacity_type
  instance_types = var.instance_types
  version        = var.cluster_version

  scaling_config {
    min_size     = var.min_size
    max_size     = var.max_size
    desired_size = var.desired_size
  }

  update_config {
    # Allow up to 33% of nodes to be unavailable during rolling updates.
    # For small node groups (min=1), this forces sequential replacement.
    max_unavailable_percentage = 33
  }

  launch_template {
    id      = aws_launch_template.node_group.id
    version = aws_launch_template.node_group.latest_version
  }

  labels = merge(
    {
      "node.kubernetes.io/node-group" = var.node_group_name
      "node.kubernetes.io/os-type"    = local.is_windows ? "windows" : "linux"
    },
    var.labels
  )

  dynamic "taint" {
    for_each = var.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  # Cluster Autoscaler or Karpenter manages desired_size after the initial apply.
  # Ignoring it prevents Terraform from fighting with the autoscaler on every plan.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.worker_node_policy,
    aws_iam_role_policy_attachment.cni_policy,
    aws_iam_role_policy_attachment.ecr_read_only,
    aws_iam_role_policy_attachment.ssm_core,
  ]

  tags = local.common_tags
}
