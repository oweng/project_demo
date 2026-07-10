locals {
  role_name = "${var.environment}-${var.cluster_name}-${var.app_name}"

  common_tags = merge(
    {
      Environment = var.environment
      ManagedBy   = "terraform"
      Application = var.app_name
    },
    var.tags
  )
}

# ─── IAM Role ─────────────────────────────────────────────────────────────────
# Pod Identity trust policy is cluster-agnostic — it trusts pods.eks.amazonaws.com
# rather than embedding a cluster-specific OIDC issuer URL. The same role can be
# reused across clusters or reassigned to a different service account without
# modifying the trust policy.

resource "aws_iam_role" "this" {
  name = local.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = local.common_tags
}

# ─── SSM Parameter Store access ───────────────────────────────────────────────
# Scoped to the app's path prefix only — apps cannot read each other's parameters.
# This is the preferred pattern for config and secrets over environment variables.

resource "aws_iam_role_policy" "ssm" {
  count = var.ssm_path_prefix != "" ? 1 : 0

  name = "ssm-read"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = "arn:aws:ssm:*:*:parameter${var.ssm_path_prefix}/*"
      },
      {
        # KMS decrypt required if parameters are SecureString
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.*.amazonaws.com"
          }
        }
      }
    ]
  })
}

# ─── S3 access ────────────────────────────────────────────────────────────────

resource "aws_iam_role_policy" "s3" {
  count = length(var.s3_bucket_arns) > 0 ? 1 : 0

  name = "s3-access"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      Resource = concat(
        var.s3_bucket_arns,
        [for arn in var.s3_bucket_arns : "${arn}/*"]
      )
    }]
  })
}

# ─── Additional managed policies ──────────────────────────────────────────────

resource "aws_iam_role_policy_attachment" "additional" {
  for_each = toset(var.additional_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

# ─── Pod Identity Association ──────────────────────────────────────────────────
# Binds the Kubernetes service account to the IAM role. The Pod Identity agent
# DaemonSet intercepts credential requests from pods using this service account
# and returns short-lived credentials for the associated role — no secrets, no
# static credentials, no OIDC thumbprint maintenance.

resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account_name
  role_arn        = aws_iam_role.this.arn

  tags = local.common_tags
}
