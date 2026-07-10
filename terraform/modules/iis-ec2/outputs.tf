output "instance_ids" {
  description = "EC2 instance IDs for all IIS instances in this group"
  value       = aws_instance.this[*].id
}

output "alb_arn" {
  description = "Internal ALB ARN"
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "Internal ALB DNS name — use the Route 53 record instead of this directly"
  value       = aws_lb.this.dns_name
}

output "dns_name" {
  description = "Route 53 DNS name for this application — the stable address all callers should use"
  value       = aws_route53_record.this.fqdn
}

output "target_group_arn" {
  description = "ALB target group ARN — useful for attaching additional instances or for CodeDeploy blue/green deployments"
  value       = aws_lb_target_group.this.arn
}

output "instance_security_group_id" {
  description = "Security group ID for the IIS instances — add ingress rules here for any direct instance access needed"
  value       = aws_security_group.instance.id
}

output "iam_role_name" {
  description = "IAM role name — attach additional policies here for app-specific AWS access (SSM parameters, S3, etc.)"
  value       = aws_iam_role.this.name
}
