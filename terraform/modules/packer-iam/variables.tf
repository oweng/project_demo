variable "environment" {
  description = "Environment label"
  type        = string
}

variable "ecr_repository_arns" {
  description = "ECR repository ARNs the build instance is allowed to pull from during image pre-caching"
  type        = list(string)
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
