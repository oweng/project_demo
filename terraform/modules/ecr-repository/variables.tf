variable "name" {
  description = "ECR repository name (e.g. 'api-gateway', 'windows-dotnet48')"
  type        = string
}

variable "image_tag_mutability" {
  description = "IMMUTABLE prevents tags from being overwritten. Use IMMUTABLE for production — every push must use a unique tag (git SHA)."
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "Must be MUTABLE or IMMUTABLE."
  }
}

variable "scan_on_push" {
  description = "Enable ECR basic scanning on every image push. Findings surface in the AWS console and can be queried via the API."
  type        = bool
  default     = true
}

variable "keep_image_count" {
  description = "Number of tagged images to retain per repository. Older images beyond this count are expired by the lifecycle policy."
  type        = number
  default     = 30
}

variable "untagged_expiry_days" {
  description = "Days after which untagged images (e.g. intermediate build layers) are deleted."
  type        = number
  default     = 7
}

variable "read_access_arns" {
  description = "IAM principal ARNs (roles, accounts) that need pull access — used for cross-account access or CI runners in other accounts."
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
