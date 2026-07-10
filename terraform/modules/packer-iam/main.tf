resource "aws_iam_role" "packer" {
  name = "packer-eks-node-builder-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "packer-eks-node-builder-${var.environment}" })
}

# Enables SSM Session Manager on the build instance — Packer tunnels its SSH
# connection through SSM so no inbound ports or public IP are required.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.packer.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ECR pull — scoped to specific repositories the build pre-caches.
# GetAuthorizationToken has no resource-level scope in ECR, so it stays on *.
resource "aws_iam_role_policy" "ecr_pull" {
  name = "ecr-pull"
  role = aws_iam_role.packer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = var.ecr_repository_arns
      }
    ]
  })
}

resource "aws_iam_instance_profile" "packer" {
  name = "packer-eks-node-builder-${var.environment}"
  role = aws_iam_role.packer.name

  tags = merge(var.tags, { Name = "packer-eks-node-builder-${var.environment}" })
}
