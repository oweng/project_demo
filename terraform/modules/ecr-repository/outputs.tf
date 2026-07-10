output "repository_url" {
  description = "Full ECR repository URL — use as the base for docker push/pull and image references in pod specs"
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "ECR repository ARN — use when granting ECR pull access in IAM policies"
  value       = aws_ecr_repository.this.arn
}

output "repository_name" {
  description = "ECR repository name"
  value       = aws_ecr_repository.this.name
}
