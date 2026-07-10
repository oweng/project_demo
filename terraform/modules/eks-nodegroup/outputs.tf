output "node_group_name" {
  description = "EKS node group name"
  value       = aws_eks_node_group.this.node_group_name
}

output "node_group_arn" {
  description = "EKS node group ARN"
  value       = aws_eks_node_group.this.arn
}

output "node_role_arn" {
  description = "IAM role ARN for nodes in this group — add to aws-auth ConfigMap if using self-managed nodes"
  value       = aws_iam_role.node_group.arn
}

output "node_role_name" {
  description = "IAM role name for nodes — useful for attaching additional policies"
  value       = aws_iam_role.node_group.name
}

output "launch_template_id" {
  description = "Launch template ID"
  value       = aws_launch_template.node_group.id
}

output "is_windows" {
  description = "True if this node group runs Windows nodes"
  value       = local.is_windows
}
