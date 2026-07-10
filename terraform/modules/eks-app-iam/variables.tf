variable "app_name" {
  description = "Application name — used in the IAM role name and tags"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — used in the Pod Identity association"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace the application runs in"
  type        = string
  default     = "production"
}

variable "service_account_name" {
  description = "Kubernetes service account name that will assume this role. Must match the serviceAccountName in the pod spec."
  type        = string
}

variable "ssm_path_prefix" {
  description = "SSM Parameter Store path prefix the app is allowed to read (e.g. /production/my-app). Leave empty to skip SSM policy."
  type        = string
  default     = ""
}

variable "s3_bucket_arns" {
  description = "S3 bucket ARNs the app needs read/write access to. Leave empty to skip S3 policy."
  type        = list(string)
  default     = []
}

variable "additional_policy_arns" {
  description = "Additional managed policy ARNs to attach to the role"
  type        = list(string)
  default     = []
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
