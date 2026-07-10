variable "cluster_name" {
  description = "EKS cluster name this node group belongs to"
  type        = string
}

variable "cluster_version" {
  description = "EKS cluster Kubernetes version — node groups must match the cluster version"
  type        = string
}

variable "node_group_name" {
  description = "Short identifier for this node group (e.g. 'system', 'linux-apps', 'windows-apps')"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs where nodes will launch. Spread across AZs for HA."
  type        = list(string)
}

variable "ami_type" {
  description = <<-EOT
    EKS-managed AMI type. Determines the OS and architecture of nodes.
    Common values:
      AL2023_x86_64_STANDARD  — Amazon Linux 2023 (recommended for Linux workloads)
      AL2023_ARM_64_STANDARD  — Amazon Linux 2023 on Graviton (ARM)
      WINDOWS_CORE_2022_x86_64 — Windows Server 2022 Core (for .NET Framework 4.8)
      WINDOWS_FULL_2022_x86_64 — Windows Server 2022 Full (with GUI, larger image)
  EOT
  type        = string

  validation {
    condition = contains([
      "AL2023_x86_64_STANDARD",
      "AL2023_ARM_64_STANDARD",
      "AL2_x86_64",
      "AL2_x86_64_GPU",
      "WINDOWS_CORE_2019_x86_64",
      "WINDOWS_FULL_2019_x86_64",
      "WINDOWS_CORE_2022_x86_64",
      "WINDOWS_FULL_2022_x86_64",
    ], var.ami_type)
    error_message = "ami_type must be a valid EKS AMI type."
  }
}

variable "capacity_type" {
  description = "ON_DEMAND or SPOT. Use ON_DEMAND for system and Windows nodes; SPOT for stateless Linux workloads."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "instance_types" {
  description = <<-EOT
    EC2 instance types for this node group.
    For SPOT: provide 3+ types across families (e.g. m6i, m6a, m5) to reduce simultaneous
    interruption risk. For ON_DEMAND: a single type is fine.
  EOT
  type        = list(string)
}

variable "min_size" {
  description = "Minimum number of nodes"
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum number of nodes"
  type        = number
  default     = 10
}

variable "desired_size" {
  description = "Initial desired number of nodes. Cluster Autoscaler or Karpenter manages this after initial apply."
  type        = number
  default     = 2
}

variable "disk_size_gb" {
  description = <<-EOT
    Root EBS volume size in GB.
    Windows nodes require at least 50 GB for the OS image alone; 100 GB+ recommended.
    Linux nodes: 50 GB is sufficient for most workloads.
  EOT
  type        = number
  default     = 50
}

variable "labels" {
  description = "Kubernetes node labels applied to all nodes in this group"
  type        = map(string)
  default     = {}
}

variable "taints" {
  description = <<-EOT
    Kubernetes taints applied to all nodes. Use to restrict pod scheduling.
    Example for Windows nodes: [{ key = "os", value = "windows", effect = "NO_SCHEDULE" }]
    Pods must have a matching toleration to schedule on tainted nodes.
  EOT
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []

  validation {
    condition = alltrue([
      for t in var.taints : contains(["NO_SCHEDULE", "NO_EXECUTE", "PREFER_NO_SCHEDULE"], t.effect)
    ])
    error_message = "Taint effect must be NO_SCHEDULE, NO_EXECUTE, or PREFER_NO_SCHEDULE."
  }
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
