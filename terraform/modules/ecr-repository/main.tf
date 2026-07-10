locals {
  common_tags = merge(
    {
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags
  )
}

resource "aws_ecr_repository" "this" {
  name                 = var.name
  image_tag_mutability = var.image_tag_mutability

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  # HIPAA: ECR repositories containing application images should be encrypted.
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.common_tags
}

# Lifecycle policy keeps the last N tagged images and expires untagged images
# quickly. Without this, ECR storage accumulates indefinitely — especially
# relevant for Windows base images which are 5-9GB each.
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last ${var.keep_image_count} tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-", "v", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = var.keep_image_count
        }
        action = { type = "expire" }
      }
    ]
  })
}

# Optional cross-account or cross-role read access (e.g. for a staging account
# pulling production base images, or a self-hosted runner in another account).
resource "aws_ecr_repository_policy" "read_access" {
  count      = length(var.read_access_arns) > 0 ? 1 : 0
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "CrossAccountPull"
      Effect = "Allow"
      Principal = {
        AWS = var.read_access_arns
      }
      Action = [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
      ]
    }]
  })
}
