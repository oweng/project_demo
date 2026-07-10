# ─── VPC ──────────────────────────────────────────────────────────────────────
# 3 public subnets (NAT Gateways + Packer build instances) and 3 private subnets
# (EKS nodes, EC2 SQL Server, IIS hosts, and eventually RDS) across 3 AZs.
# VPC endpoints keep AWS API traffic off the public internet — required for HIPAA
# and meaningfully reduces NAT GW data costs for ECR image pulls.

module "vpc" {
  source = "../../modules/vpc"

  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  eks_cluster_name     = var.eks_cluster_name
  single_nat_gateway   = false # HA: one NAT GW per AZ
  enable_vpc_endpoints = true
  environment          = var.environment
  tags                 = var.common_tags
}

# ─── SQL Server EC2 Hosts ──────────────────────────────────────────────────────
# The module is called once per host. Add additional blocks for sql-server-02, etc.
# To import an existing instance: terraform import module.sql_server_01.aws_instance.this <id>

module "sql_server_01" {
  source = "../../modules/ec2-sql-server"

  host_name      = "sql-server-01"
  ami_id         = var.windows_ami_id
  instance_type  = "m6i.2xlarge"
  subnet_id      = module.vpc.private_subnet_ids[0]
  vpc_id         = module.vpc.vpc_id
  vpn_cidr       = var.vpn_cidr
  app_tier_cidrs = var.app_tier_cidrs
  alert_email    = var.alert_email
  environment    = var.environment

  root_volume_size_gb    = 200
  root_volume_type       = "gp3"
  root_volume_iops       = 3000
  root_volume_throughput = 125

  disk_warning_free_pct  = 20
  disk_critical_free_pct = 10
  drive_letter           = "C:"

  tags = var.common_tags
}

# ─── EKS Cluster ──────────────────────────────────────────────────────────────

module "eks_cluster" {
  source = "../../modules/eks-cluster"

  cluster_name       = var.eks_cluster_name
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnet_ids
  environment        = var.environment

  # Private-only endpoint — accessed over VPN. No public exposure.
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = false

  # Windows IPAM must be enabled in vpc-cni when Windows node groups are present.
  enable_windows_support = true

  log_retention_days = 90

  tags = var.common_tags
}

# ─── Node Group: System (Linux, On-Demand) ────────────────────────────────────
# Runs cluster-critical add-ons: CoreDNS, kube-proxy, Datadog agent DaemonSet.
# Tainted CriticalAddonsOnly so only explicitly tolerating pods land here.
# Never use Spot for this group — a simultaneous interruption of all system nodes
# would take down CoreDNS and break all in-cluster DNS for all workloads.

module "eks_system_nodes" {
  source = "../../modules/eks-nodegroup"

  cluster_name    = module.eks_cluster.cluster_name
  cluster_version = module.eks_cluster.cluster_version
  node_group_name = "system"
  subnet_ids      = module.vpc.private_subnet_ids
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  instance_types  = ["m6i.xlarge"]
  min_size        = 3 # One per AZ — required for HA
  max_size        = 5
  desired_size    = 3
  disk_size_gb    = 50
  environment     = var.environment

  labels = {
    role = "system"
  }

  taints = [{
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }]

  tags = var.common_tags
}

# ─── Node Group: Linux Apps (On-Demand + Spot) ────────────────────────────────
# Runs .NET 8 / .NET Core services on Linux containers.
# Two sub-groups: a stable On-Demand baseline and a cost-optimized Spot pool.
# The Spot group uses instance type diversification across families to reduce
# simultaneous interruption probability — m6i, m6a, and m5 rarely get interrupted
# at the same time for the same size.

module "eks_linux_nodes_ondemand" {
  source = "../../modules/eks-nodegroup"

  cluster_name    = module.eks_cluster.cluster_name
  cluster_version = module.eks_cluster.cluster_version
  node_group_name = "linux-apps-ondemand"
  subnet_ids      = module.vpc.private_subnet_ids
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  instance_types  = ["m6i.2xlarge"]
  min_size        = 2
  max_size        = 10
  desired_size    = 3
  disk_size_gb    = 50
  environment     = var.environment

  labels = {
    role            = "app"
    "os-type"       = "linux"
    "capacity-type" = "on-demand"
  }

  tags = var.common_tags
}

module "eks_linux_nodes_spot" {
  source = "../../modules/eks-nodegroup"

  cluster_name    = module.eks_cluster.cluster_name
  cluster_version = module.eks_cluster.cluster_version
  node_group_name = "linux-apps-spot"
  subnet_ids      = module.vpc.private_subnet_ids
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "SPOT"
  instance_types  = ["m6i.2xlarge", "m6a.2xlarge", "m5.2xlarge", "m6i.4xlarge", "m6a.4xlarge"]
  min_size        = 0
  max_size        = 30
  desired_size    = 2
  disk_size_gb    = 50
  environment     = var.environment

  labels = {
    role            = "app"
    "os-type"       = "linux"
    "capacity-type" = "spot"
  }

  tags = var.common_tags
}

# ─── Node Group: Windows Apps (On-Demand) ─────────────────────────────────────
# Runs .NET Framework 4.8 applications that cannot be moved to Linux containers.
# Windows Server 2022 Core is used (smaller image than Full; no GUI needed).
#
# Tainted with os=windows:NoSchedule — pods must explicitly tolerate this to land
# here. This prevents Linux pods from being accidentally scheduled on Windows nodes
# (they would fail to start since Linux binaries can't run on Windows).
#
# Spot is NOT used for Windows nodes because:
# 1. Windows Spot instance availability is lower than Linux equivalents.
# 2. Windows nodes take longer to start (~5-10 min vs ~90 sec for Linux) due to
#    image size, so Spot interruptions are more disruptive.
# 3. .NET Framework 4.8 apps are typically legacy and stateful — not ideal for Spot.
#
# min_size=0 allows the group to scale to zero during off-hours if no Windows
# workloads are active. Set min_size=1 if Windows services need 24/7 availability.

module "eks_windows_nodes" {
  source = "../../modules/eks-nodegroup"

  cluster_name    = module.eks_cluster.cluster_name
  cluster_version = module.eks_cluster.cluster_version
  node_group_name = "windows-apps"
  subnet_ids      = module.vpc.private_subnet_ids
  ami_type        = "WINDOWS_CORE_2022_x86_64"
  capacity_type   = "ON_DEMAND"
  instance_types  = ["m6i.2xlarge"]
  min_size        = 1
  max_size        = 10
  desired_size    = 2
  disk_size_gb    = 100 # Windows Server 2022 Core image requires ~40 GB; 100 GB provides headroom
  environment     = var.environment

  labels = {
    role      = "app"
    "os-type" = "windows"
  }

  taints = [{
    key    = "os"
    value  = "windows"
    effect = "NO_SCHEDULE"
  }]

  tags = var.common_tags
}

# ─── ECR Repositories ─────────────────────────────────────────────────────────
# One repository per deployable image. Add a module block for each new service.
# All repositories use IMMUTABLE tags — every push must use a unique tag (git SHA).
# The windows-dotnet48 base image is built by the Packer workflow; app teams build
# their images on top of it.

module "ecr_windows_dotnet48_base" {
  source = "../../modules/ecr-repository"

  name        = "windows-dotnet48"
  environment = var.environment
  tags        = var.common_tags
}

# Example .NET 8 service repository — duplicate this block for each service.
module "ecr_api_gateway" {
  source = "../../modules/ecr-repository"

  name        = "api-gateway"
  environment = var.environment
  tags        = var.common_tags
}

# ─── EKS Pod Identity: .NET 8 Applications ────────────────────────────────────
# One eks-app-iam module call per service. Each service gets its own IAM role
# scoped to only the AWS resources it needs — no shared roles, no broad permissions
# inherited from the node. The Pod Identity agent on each node intercepts credential
# requests and returns short-lived credentials for the associated role.
#
# The service account named here must exist in the cluster (created by the Helm
# chart for that service). Pod Identity resolves the binding at runtime.

module "iam_api_gateway" {
  source = "../../modules/eks-app-iam"

  app_name             = "api-gateway"
  cluster_name         = module.eks_cluster.cluster_name
  namespace            = "production"
  service_account_name = "api-gateway"
  ssm_path_prefix      = "/production/api-gateway"
  environment          = var.environment
  tags                 = var.common_tags
}

# ─── Packer IAM ───────────────────────────────────────────────────────────────
# Instance profile attached to the temporary Packer build instance. Grants SSM
# Session Manager access (Packer's SSH tunnel) and ECR pull for image pre-caching.
# The profile name is output so it can be set as PACKER_INSTANCE_PROFILE in CI.

module "packer_iam" {
  source = "../../modules/packer-iam"

  environment = var.environment
  ecr_repository_arns = [
    module.ecr_windows_dotnet48_base.repository_arn,
    module.ecr_api_gateway.repository_arn,
  ]
  tags = var.common_tags
}

# ─── ASP.NET 4.8: IIS on EC2 ─────────────────────────────────────────────────
# .NET Framework 4.8 applications stay on EC2 behind internal ALBs during the
# migration window. Add one module block per application.
#
# The dns_name output is what EKS pods and other EC2 services call — never the
# ALB hostname directly. When this app is eventually ported to .NET 8 and moved
# to EKS, only the Route 53 record changes; every caller is unaffected.

module "iis_claims_portal" {
  source = "../../modules/iis-ec2"

  app_name        = "claims-portal"
  ami_id          = var.windows_ami_id
  instance_type   = "m6i.xlarge"
  instance_count  = 2
  subnet_ids      = module.vpc.private_subnet_ids
  alb_subnet_ids  = module.vpc.private_subnet_ids
  vpc_id          = module.vpc.vpc_id
  vpn_cidr        = var.vpn_cidr
  route53_zone_id = var.route53_zone_id
  dns_name        = "claims-portal.${var.internal_domain}"
  environment     = var.environment
  tags            = var.common_tags
}
