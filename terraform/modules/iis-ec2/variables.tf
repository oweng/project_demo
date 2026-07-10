variable "app_name" {
  description = "Application name — used in resource names and DNS record (e.g. 'claims-portal')"
  type        = string
}

variable "ami_id" {
  description = "Windows Server 2022 AMI ID (region-specific)"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "m6i.xlarge"
}

variable "instance_count" {
  description = "Number of IIS EC2 instances. Set to 2+ for HA across AZs."
  type        = number
  default     = 2

  validation {
    condition     = var.instance_count >= 1
    error_message = "At least one instance is required."
  }
}

variable "subnet_ids" {
  description = "Private subnet IDs for the EC2 instances. Provide one per AZ when instance_count > 1."
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "alb_subnet_ids" {
  description = "Private subnet IDs for the internal ALB. Should span at least 2 AZs."
  type        = list(string)

  validation {
    condition     = length(var.alb_subnet_ids) >= 2
    error_message = "Internal ALB requires subnets in at least 2 AZs."
  }
}

variable "vpn_cidr" {
  description = "On-premises VPN CIDR — restricts RDP access to this range only"
  type        = string
  default     = "10.0.0.0/8"
}

variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB on port 80/443. Default allows internal VPC traffic only."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "health_check_path" {
  description = "HTTP path the ALB uses to health check IIS instances (e.g. '/health', '/ping')"
  type        = string
  default     = "/health"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB. IIS app deployments often grow the C: drive — size accordingly."
  type        = number
  default     = 100
}

variable "route53_zone_id" {
  description = "Route 53 private hosted zone ID for the internal DNS record"
  type        = string
}

variable "dns_name" {
  description = "DNS hostname for the application (e.g. 'claims-portal.internal.example.com')"
  type        = string
}

variable "key_name" {
  description = "EC2 key pair name. Leave empty to use SSM Session Manager (recommended)."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Environment label"
  type        = string
}

variable "tags" {
  description = "Additional tags merged with defaults"
  type        = map(string)
  default     = {}
}
