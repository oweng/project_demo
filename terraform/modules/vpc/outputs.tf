output "vpc_id" {
  description = "VPC ID — pass to all other modules that require a vpc_id"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs (3 AZs) — use for EKS node groups, EC2 instances, internal ALBs, and RDS"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (3 AZs) — use for NAT Gateways and Packer build instances"
  value       = aws_subnet.public[*].id
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs — one per AZ in HA mode, one total in single-NAT mode"
  value       = aws_nat_gateway.this[*].id
}

output "nat_gateway_public_ips" {
  description = "Elastic IP addresses of NAT Gateways — add these to any external allowlists for outbound traffic"
  value       = aws_eip.nat[*].public_ip
}

output "availability_zones" {
  description = "Availability zones used, in the same order as subnet outputs"
  value       = local.azs
}

output "s3_endpoint_id" {
  description = "S3 gateway VPC endpoint ID (empty string if endpoints disabled)"
  value       = var.enable_vpc_endpoints ? aws_vpc_endpoint.s3[0].id : ""
}
