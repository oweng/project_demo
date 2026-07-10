locals {
  common_tags = merge(
    {
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags
  )

  # Build full AZ names from the region (pulled at runtime) and the suffix list.
  azs = [for suffix in var.availability_zones : "${data.aws_region.current.name}${suffix}"]

  # The NAT GW used by each private subnet:
  # - HA mode: one NAT GW per AZ, index matches the subnet index
  # - Single mode: all private subnets route to the single NAT GW in AZ[0]
  nat_gateway_ids = var.single_nat_gateway ? [aws_nat_gateway.this[0].id, aws_nat_gateway.this[0].id, aws_nat_gateway.this[0].id] : aws_nat_gateway.this[*].id
}

data "aws_region" "current" {}

# ─── VPC ──────────────────────────────────────────────────────────────────────

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both must be true for EKS — the cluster and nodes use internal DNS resolution
  # for service discovery and for reaching the EKS API server endpoint.
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${var.environment}-vpc"
  })
}

# ─── Internet Gateway ─────────────────────────────────────────────────────────

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${var.environment}-igw"
  })
}

# ─── Public Subnets ───────────────────────────────────────────────────────────
# Public subnets host:
#   - NAT Gateways (which must be in a public subnet by design)
#   - Packer build instances (temporary; need outbound internet for image pulls)
# All other workloads (EKS nodes, EC2 apps, RDS) stay in private subnets.
#
# Tagging:
#   kubernetes.io/role/elb = 1  → AWS Load Balancer Controller uses this to discover
#                                  subnets for internet-facing ALBs (if ever needed)

resource "aws_subnet" "public" {
  count = 3

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false # Explicit public IPs requested per resource; no blanket auto-assign

  tags = merge(local.common_tags, {
    Name                                            = "${var.environment}-public-${var.availability_zones[count.index]}"
    Tier                                            = "public"
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  })
}

# ─── Private Subnets ──────────────────────────────────────────────────────────
# Private subnets host:
#   - EKS node groups (system, linux-apps, windows-apps)
#   - EC2 SQL Server and IIS instances
#   - Internal ALBs
#   - RDS instances (when migrated)
#
# Tagging:
#   kubernetes.io/role/internal-elb = 1  → AWS Load Balancer Controller uses this
#                                           to provision internal ALBs for EKS services

resource "aws_subnet" "private" {
  count = 3

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.common_tags, {
    Name                                            = "${var.environment}-private-${var.availability_zones[count.index]}"
    Tier                                            = "private"
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  })
}

# ─── NAT Gateways ─────────────────────────────────────────────────────────────
# Private subnets need NAT GW for outbound internet: SSM agent, CloudWatch Agent,
# ECR image pulls, Windows Update, and the AWS APIs used by EKS components.
#
# HA mode (default): one NAT GW per AZ. If an AZ fails, the other two AZs retain
# full egress capability. Each EIP and NAT GW is in the public subnet of the same AZ.
#
# Single mode: one NAT GW in AZ[0]. Cheaper but all private egress routes through
# one AZ — an AZ failure takes down SSM and CloudWatch for the entire environment.

resource "aws_eip" "nat" {
  count  = var.single_nat_gateway ? 1 : 3
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.environment}-nat-eip-${var.availability_zones[count.index]}"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = var.single_nat_gateway ? 1 : 3

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.common_tags, {
    Name = "${var.environment}-nat-${var.availability_zones[count.index]}"
  })

  depends_on = [aws_internet_gateway.this]
}

# ─── Route Tables ─────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.environment}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count = 3

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One route table per private subnet so each AZ routes through its own NAT GW
# in HA mode. In single-NAT mode all three route tables point to the same NAT GW
# but keeping them separate means upgrading to HA later is a route table update,
# not a structural change.

resource "aws_route_table" "private" {
  count  = 3
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = local.nat_gateway_ids[count.index]
  }

  tags = merge(local.common_tags, {
    Name = "${var.environment}-private-rt-${var.availability_zones[count.index]}"
  })
}

resource "aws_route_table_association" "private" {
  count = 3

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ─── VPC Endpoints ────────────────────────────────────────────────────────────
# Endpoint types:
#   Gateway endpoints (S3, DynamoDB) — free, attached to route tables
#   Interface endpoints (everything else) — $0.01/hr per AZ per endpoint
#
# These are critical for a HIPAA environment: traffic to AWS APIs stays on the
# AWS private network rather than traversing the public internet via NAT GW.
# They also materially reduce NAT GW data processing costs for ECR image pulls
# (Windows images are 5-9GB; routing them through a gateway endpoint is free).

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(local.common_tags, { Name = "${var.environment}-vpce-s3" })
}

resource "aws_security_group" "vpc_endpoints" {
  count = var.enable_vpc_endpoints ? 1 : 0

  name        = "${var.environment}-vpce-sg"
  description = "HTTPS from within the VPC to interface VPC endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.environment}-vpce-sg" })
}

locals {
  # Interface endpoints needed in this environment:
  #   ssm / ssmmessages / ec2messages — SSM agent on every EC2 and EKS node
  #   ecr.api / ecr.dkr             — EKS node image pulls (especially large Windows images)
  #   logs                           — CloudWatch Agent log shipping
  #   sts                            — Pod Identity credential vending
  interface_endpoints = var.enable_vpc_endpoints ? {
    ssm         = "com.amazonaws.${data.aws_region.current.name}.ssm"
    ssmmessages = "com.amazonaws.${data.aws_region.current.name}.ssmmessages"
    ec2messages = "com.amazonaws.${data.aws_region.current.name}.ec2messages"
    ecr_api     = "com.amazonaws.${data.aws_region.current.name}.ecr.api"
    ecr_dkr     = "com.amazonaws.${data.aws_region.current.name}.ecr.dkr"
    logs        = "com.amazonaws.${data.aws_region.current.name}.logs"
    sts         = "com.amazonaws.${data.aws_region.current.name}.sts"
  } : {}
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.this.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "${var.environment}-vpce-${each.key}" })
}
