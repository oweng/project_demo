variable "cluster_name" {
  description = "EKS cluster name — must be unique within the AWS account"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Pin this and update deliberately — don't use 'latest'."
  type        = string
  default     = "1.31"
}

variable "vpc_id" {
  description = "VPC ID for the cluster"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs across at least 2 AZs for control plane ENIs and node groups"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS requires subnets in at least 2 Availability Zones."
  }
}

variable "cluster_endpoint_private_access" {
  description = "Enable private API server endpoint (required for VPN-only environments)"
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access" {
  description = "Enable public API server endpoint. Disable in production; use VPN + private endpoint instead."
  type        = bool
  default     = false
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public endpoint (if enabled). Restrict tightly."
  type        = list(string)
  default     = []
}

variable "enable_windows_support" {
  description = "Configure vpc-cni for Windows IPAM. Required when running Windows node groups."
  type        = bool
  default     = false
}

variable "cluster_log_types" {
  description = "Control plane log types to send to CloudWatch Logs"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "log_retention_days" {
  description = "CloudWatch log retention for control plane logs"
  type        = number
  default     = 90
}

variable "environment" {
  description = "Environment label — used in resource names and tags"
  type        = string
}

variable "tags" {
  description = "Additional tags merged with defaults on all resources"
  type        = map(string)
  default     = {}
}
