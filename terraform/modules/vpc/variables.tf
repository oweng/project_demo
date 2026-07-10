variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "Must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  description = "List of AZ suffixes to deploy into (e.g. ['a', 'b', 'c']). Must have exactly 3."
  type        = list(string)
  default     = ["a", "b", "c"]

  validation {
    condition     = length(var.availability_zones) == 3
    error_message = "Exactly 3 availability zones are required."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the 3 public subnets — one per AZ. Must be within var.vpc_cidr."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 3
    error_message = "Exactly 3 public subnet CIDRs are required."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the 3 private subnets — one per AZ. Must be within var.vpc_cidr."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == 3
    error_message = "Exactly 3 private subnet CIDRs are required."
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    Deploy a single NAT Gateway instead of one per AZ.
    Set to true for non-production environments to reduce cost.
    Leave false for production — a single NAT GW is a single point of failure for all
    private subnet egress, which would take down SSM, CloudWatch, and ECR pulls if its
    AZ has an issue.
  EOT
  type        = bool
  default     = false
}

variable "enable_vpc_endpoints" {
  description = <<-EOT
    Create VPC endpoints for S3 (gateway), SSM, ECR, CloudWatch Logs, and STS.
    Recommended for production: keeps AWS API traffic off the public internet,
    reduces NAT Gateway data processing costs, and is required for HIPAA environments
    where traffic to AWS services must not traverse the public internet.
  EOT
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "EKS cluster name — used to tag subnets for EKS and AWS Load Balancer Controller discovery"
  type        = string
}

variable "environment" {
  description = "Environment label"
  type        = string
}

variable "tags" {
  description = "Additional tags merged with defaults on all resources"
  type        = map(string)
  default     = {}
}
