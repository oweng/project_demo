output "instance_profile_name" {
  description = "IAM instance profile name — set as PACKER_INSTANCE_PROFILE repo variable in GitHub Actions"
  value       = aws_iam_instance_profile.packer.name
}

output "role_arn" {
  description = "IAM role ARN for the Packer build instance"
  value       = aws_iam_role.packer.arn
}
