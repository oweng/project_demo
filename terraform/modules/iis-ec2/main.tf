locals {
  name_prefix = "${var.environment}-${var.app_name}"

  common_tags = merge(
    {
      Name        = local.name_prefix
      Environment = var.environment
      ManagedBy   = "terraform"
      AppType     = "iis-dotnet48"
      DataClass   = "PHI"
    },
    var.tags
  )
}

# ─── IAM ─────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "this" {
  name = "${local.name_prefix}-role"

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

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "this" {
  name = "${local.name_prefix}-instance-profile"
  role = aws_iam_role.this.name

  tags = local.common_tags
}

# ─── Security Groups ──────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "IIS internal ALB for ${var.app_name}"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from internal networks"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.alb_ingress_cidrs
  }

  ingress {
    description = "HTTPS from internal networks"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.alb_ingress_cidrs
  }

  egress {
    description = "All outbound to IIS instances"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-alb-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "instance" {
  name        = "${local.name_prefix}-instance-sg"
  description = "IIS EC2 instances for ${var.app_name}: HTTP from ALB only, RDP from VPN"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP from ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "RDP restricted to on-premises VPN range"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.vpn_cidr]
  }

  egress {
    description = "All outbound required for SSM, CloudWatch, Windows Update, SQL Server"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-instance-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# ─── EC2 Instances ────────────────────────────────────────────────────────────
# One instance per subnet (AZ) up to instance_count. Spread across AZs by
# indexing into subnet_ids — the first instance goes to subnet_ids[0], etc.

resource "aws_instance" "this" {
  count = var.instance_count

  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_ids[count.index % length(var.subnet_ids)]
  key_name               = var.key_name != "" ? var.key_name : null
  iam_instance_profile   = aws_iam_instance_profile.this.name
  vpc_security_group_ids = [aws_security_group.instance.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = false

    tags = merge(local.common_tags, {
      Name = "${local.name_prefix}-${count.index}-root"
    })
  }

  metadata_options {
    http_tokens = "required"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ami, user_data]
  }

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-${count.index}"
    OS      = "Windows Server 2022"
    AppType = "iis-dotnet48"
  })
}

# ─── Internal ALB ─────────────────────────────────────────────────────────────

resource "aws_lb" "this" {
  name               = "${local.name_prefix}-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.alb_subnet_ids

  # Access logs are a HIPAA audit requirement for systems touching PHI.
  # Uncomment and set the S3 bucket once a centralized logging bucket is provisioned.
  # access_logs {
  #   bucket  = "your-alb-access-logs-bucket"
  #   prefix  = local.name_prefix
  #   enabled = true
  # }

  tags = local.common_tags
}

resource "aws_lb_target_group" "this" {
  name     = "${local.name_prefix}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = var.health_check_path
    protocol            = "HTTP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    matcher             = "200"
  }

  tags = local.common_tags
}

resource "aws_lb_target_group_attachment" "this" {
  count = var.instance_count

  target_group_arn = aws_lb_target_group.this.arn
  target_id        = aws_instance.this[count.index].id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = local.common_tags
}

# ─── Route 53: Internal DNS ───────────────────────────────────────────────────
# All services use DNS names, never ALB hostnames directly. This is what allows
# EKS pods and other EC2 instances to call this service at a stable address, and
# what makes the EC2 → EKS migration a DNS cutover rather than a config change
# in every caller.

resource "aws_route53_record" "this" {
  zone_id = var.route53_zone_id
  name    = var.dns_name
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
