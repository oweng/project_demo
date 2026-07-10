output "role_arn" {
  description = "IAM role ARN — annotate the Kubernetes service account with this value"
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "IAM role name — used to attach additional policies if needed"
  value       = aws_iam_role.this.name
}

output "pod_identity_association_id" {
  description = "Pod Identity association ID"
  value       = aws_eks_pod_identity_association.this.association_id
}
