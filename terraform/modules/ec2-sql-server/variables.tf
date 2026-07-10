variable "ami_id" {
  description = "Windows Server 2022 AMI ID (region-specific)"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "m6i.2xlarge"
}

variable "subnet_id" {
  description = "Private subnet ID for the EC2 instance"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for security group scope"
  type        = string
}

variable "key_name" {
  description = "EC2 key pair name. Leave empty to use SSM Session Manager exclusively (recommended)."
  type        = string
  default     = ""
}

variable "vpn_cidr" {
  description = "On-premises VPN CIDR — restricts RDP ingress to this range only"
  type        = string
  default     = "10.0.0.0/8"
}

variable "app_tier_cidrs" {
  description = "CIDR blocks for application-tier hosts that need SQL Server access (port 1433)"
  type        = list(string)
  default     = []
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 200

  validation {
    condition     = var.root_volume_size_gb >= 80
    error_message = "Root volume must be at least 80 GB."
  }
}

variable "root_volume_type" {
  description = "EBS volume type. gp3 is recommended — same baseline IOPS as gp2 at lower cost."
  type        = string
  default     = "gp3"

  validation {
    condition     = contains(["gp2", "gp3", "io1", "io2"], var.root_volume_type)
    error_message = "Volume type must be gp2, gp3, io1, or io2."
  }
}

variable "root_volume_iops" {
  description = "Provisioned IOPS. gp3 baseline is 3000; increase only if OS I/O is a bottleneck."
  type        = number
  default     = 3000
}

variable "root_volume_throughput" {
  description = "Throughput in MiB/s (gp3 only). Baseline is 125."
  type        = number
  default     = 125
}

variable "environment" {
  description = "Environment label — used in resource names and tags"
  type        = string
  default     = "production"
}

variable "host_name" {
  description = "Short host identifier included in all resource names — enables reuse across hosts"
  type        = string
}

variable "alert_email" {
  description = "Email for disk alarm SNS notifications. Requires manual subscription confirmation."
  type        = string
}

# CloudWatch Agent reports "LogicalDisk % Free Space", so thresholds are expressed
# as % free to match the metric directly. 80% utilized = 20% free.

variable "disk_warning_free_pct" {
  description = "Free disk % that triggers WARNING (default 20 = 80% utilized)"
  type        = number
  default     = 20

  validation {
    condition     = var.disk_warning_free_pct > 0 && var.disk_warning_free_pct < 100
    error_message = "Must be between 1 and 99."
  }
}

variable "disk_critical_free_pct" {
  description = "Free disk % that triggers CRITICAL (default 10 = 90% utilized)"
  type        = number
  default     = 10

  validation {
    condition     = var.disk_critical_free_pct > 0 && var.disk_critical_free_pct < 100
    error_message = "Must be between 1 and 99."
  }
}

variable "drive_letter" {
  description = "Windows drive letter to monitor, with colon (e.g. 'C:'). Must match CloudWatch Agent config."
  type        = string
  default     = "C:"

  validation {
    condition     = can(regex("^[C-Zc-z]:$", var.drive_letter))
    error_message = "Drive letter must be a letter C-Z followed by a colon."
  }
}

variable "tags" {
  description = "Additional tags merged with defaults on all resources"
  type        = map(string)
  default     = {}
}
