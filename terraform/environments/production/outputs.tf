# ─── VPC Outputs ──────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs — pass to Packer as PKR_VAR_subnet_id (use public_subnet_ids instead) or for debugging"
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs — used by NAT Gateways and Packer build instances"
  value       = module.vpc.public_subnet_ids
}

output "nat_gateway_public_ips" {
  description = "NAT Gateway Elastic IPs — add to external allowlists for outbound traffic"
  value       = module.vpc.nat_gateway_public_ips
}

output "packer_subnet_id" {
  description = "Subnet ID for Packer build instances. Self-hosted runner connects via SSM — no public IP required."
  value       = module.vpc.private_subnet_ids[0]
}

output "packer_instance_profile_name" {
  description = "IAM instance profile for Packer build instances — set as PACKER_INSTANCE_PROFILE repo variable in GitHub Actions"
  value       = module.packer_iam.instance_profile_name
}

# ─── SQL Server Outputs ───────────────────────────────────────────────────────

output "sql_server_01_instance_id" {
  description = "EC2 instance ID for sql-server-01"
  value       = module.sql_server_01.instance_id
}

output "sql_server_01_root_volume_id" {
  description = "Root EBS volume ID — pass as VolumeId to the SSM Automation document"
  value       = module.sql_server_01.root_volume_id
}

output "sql_server_01_extend_partition_document" {
  description = "SSM Run Command document for partition extension on sql-server-01"
  value       = module.sql_server_01.ssm_extend_partition_document
}

output "sql_server_01_automation_document" {
  description = "SSM Automation document for combined EBS resize + partition extension"
  value       = module.sql_server_01.ssm_automation_document
}

# ─── EKS Outputs ─────────────────────────────────────────────────────────────

output "eks_cluster_name" {
  description = "EKS cluster name — used in kubectl and Helm commands"
  value       = module.eks_cluster.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks_cluster.cluster_endpoint
}

output "eks_cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate"
  value       = module.eks_cluster.cluster_ca_certificate
  sensitive   = true
}

output "eks_node_group_names" {
  description = "All EKS node group names"
  value = {
    system         = module.eks_system_nodes.node_group_name
    linux_ondemand = module.eks_linux_nodes_ondemand.node_group_name
    linux_spot     = module.eks_linux_nodes_spot.node_group_name
    windows        = module.eks_windows_nodes.node_group_name
  }
}

output "eks_node_role_arns" {
  description = "IAM role ARNs for each node group — required in aws-auth ConfigMap for self-managed nodes"
  value = {
    system         = module.eks_system_nodes.node_role_arn
    linux_ondemand = module.eks_linux_nodes_ondemand.node_role_arn
    linux_spot     = module.eks_linux_nodes_spot.node_role_arn
    windows        = module.eks_windows_nodes.node_role_arn
  }
}

output "kubeconfig_update_cmd" {
  description = "AWS CLI command to update your local kubeconfig for this cluster"
  value       = "aws eks update-kubeconfig --name ${module.eks_cluster.cluster_name} --region ${var.aws_region}"
}

# ─── ECR Outputs ──────────────────────────────────────────────────────────────

output "ecr_repository_urls" {
  description = "ECR repository URLs keyed by service name — use these in Dockerfile FROM and CI push commands"
  value = {
    windows_dotnet48_base = module.ecr_windows_dotnet48_base.repository_url
    api_gateway           = module.ecr_api_gateway.repository_url
  }
}

# ─── Pod Identity Outputs ─────────────────────────────────────────────────────

output "pod_identity_role_arns" {
  description = "IAM role ARNs for each .NET 8 service — annotate the matching Kubernetes service account with eks.amazonaws.com/role-arn"
  value = {
    api_gateway = module.iam_api_gateway.role_arn
  }
}

# ─── IIS EC2 Outputs ──────────────────────────────────────────────────────────

output "iis_service_dns_names" {
  description = "Internal DNS names for ASP.NET 4.8 IIS services — use these in all service-to-service calls"
  value = {
    claims_portal = module.iis_claims_portal.dns_name
  }
}
