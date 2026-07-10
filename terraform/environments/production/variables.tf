variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment label applied to all resources"
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZ suffixes to deploy into — must be 3"
  type        = list(string)
  default     = ["a", "b", "c"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the 3 public subnets (NAT Gateways, Packer builds)"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the 3 private subnets (EKS nodes, EC2, RDS)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
}

variable "vpn_cidr" {
  description = "On-premises VPN CIDR — restricts RDP access on SQL Server and IIS hosts"
  type        = string
  default     = "10.0.0.0/8"
}

variable "app_tier_cidrs" {
  description = "CIDRs for application-tier subnets that need SQL Server access (port 1433)"
  type        = list(string)
  default     = []
}

variable "windows_ami_id" {
  description = <<-EOT
    Windows Server 2022 AMI ID (region-specific). Used for SQL Server and IIS EC2 hosts.
    Find the current AMI with:
      aws ec2 describe-images --owners amazon \
        --filters "Name=name,Values=Windows_Server-2022-English-Full-Base-*" \
        --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text
  EOT
  type        = string
}

variable "alert_email" {
  description = "Email address for disk utilization alarm notifications"
  type        = string
}

variable "eks_cluster_name" {
  description = "EKS cluster name — must be unique per account/region"
  type        = string
  default     = "production-healthcare-eks"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Update deliberately — test in staging first."
  type        = string
  default     = "1.31"
}

variable "route53_zone_id" {
  description = "Route 53 private hosted zone ID for internal DNS records"
  type        = string
}

variable "internal_domain" {
  description = "Internal domain suffix for service DNS names (e.g. 'internal.example.com')"
  type        = string
}

variable "common_tags" {
  description = "Tags applied to all resources in this environment"
  type        = map(string)
  default = {
    Team        = "platform"
    Application = "healthcare"
  }
}
