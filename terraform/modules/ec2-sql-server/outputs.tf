output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.this.id
}

output "instance_private_ip" {
  description = "Private IP address"
  value       = aws_instance.this.private_ip
}

output "root_volume_id" {
  description = "EBS root volume ID — pass to the SSM Automation document as VolumeId"
  value       = aws_instance.this.root_block_device[0].volume_id
}

output "iam_role_arn" {
  description = "IAM role ARN — also serves as AutomationAssumeRole for the SSM Automation document"
  value       = aws_iam_role.this.arn
}

output "ssm_extend_partition_document" {
  description = "SSM Run Command document for partition extension"
  value       = aws_ssm_document.extend_partition.name
}

output "ssm_automation_document" {
  description = "SSM Automation document — combines EBS resize + partition extension"
  value       = aws_ssm_document.ebs_resize_and_extend.name
}

output "disk_warning_alarm" {
  description = "CloudWatch alarm name for disk WARNING (80% utilized)"
  value       = aws_cloudwatch_metric_alarm.disk_warning.alarm_name
}

output "disk_critical_alarm" {
  description = "CloudWatch alarm name for disk CRITICAL (90% utilized)"
  value       = aws_cloudwatch_metric_alarm.disk_critical.alarm_name
}

output "sns_topic_arn" {
  description = "SNS topic ARN — confirm email subscription before relying on alerts"
  value       = aws_sns_topic.disk_alerts.arn
}
