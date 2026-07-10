# CLAUDE.md — Healthcare Infrastructure Platform

This file gives Claude (and engineers) the context needed to understand what this repository
contains, why decisions were made the way they were, and how to safely extend or deploy it.

---

## What This Repository Is

Infrastructure-as-code and CI/CD for a HIPAA-regulated healthcare platform undergoing a
migration from traditional EC2-based deployments to EKS. The repository covers:

- A modular Terraform library (`terraform/modules/`) reusable across any AWS account
- A production environment composition (`terraform/environments/production/`)
- A custom Windows EKS node AMI pipeline (Packer + GitHub Actions)
- A base Windows container image (Docker) for ASP.NET 4.8 workloads
- Operational scripts for SQL Server disk management
- Written documentation covering incident response, migration strategy, and change management

All data handled by this platform is classified PHI. Every resource is tagged `DataClass=PHI`.
Encryption at rest is mandatory on all EBS volumes, SNS topics, and ECR repositories.

---

## Repository Structure

```
terraform/
  modules/
    vpc/              VPC, public/private subnets, NAT GWs, VPC endpoints
    eks-cluster/      EKS control plane, Pod Identity agent, EBS CSI driver
    eks-nodegroup/    Reusable managed node group (Linux and Windows)
    eks-app-iam/      Pod Identity IAM role per .NET 8 service
    ec2-sql-server/   SQL Server EC2 host with CloudWatch alarms and SSM automation
    iis-ec2/          ASP.NET 4.8 IIS hosts behind an internal ALB with Route 53
    ecr-repository/   ECR repository with lifecycle policies
    packer-iam/       IAM instance profile for Packer build instances
  environments/
    production/       Wires all modules together for the production account

packer/
  windows-eks-node.pkr.hcl   Custom Windows EKS node AMI definition
  scripts/
    configure-node.ps1        Pre-caches container images into containerd

docker/
  windows-dotnet48/
    Dockerfile                Base Windows container image for ASP.NET 4.8

scripts/
  extend-partition.ps1        Idempotent PowerShell for EBS partition extension
  validate-disk.ps1           Nagios-compatible disk health check

.github/workflows/
  build-windows-ami.yml       Daily AMI build pipeline (3 jobs)

docs/
  incident-analysis.md        SQL Server disk failure modes and Terraform drift
  migration-strategy.md       .NET to EKS and SQL Server to RDS migration plans
  process.md                  Fleet monitoring and change management process
```

---

## Architecture Decisions

### Terraform: modules + environments split

**Decision:** All reusable infrastructure lives in `terraform/modules/`. Environments are thin
compositions in `terraform/environments/` that call modules with environment-specific values.

**Why:** Modules can be called multiple times with different inputs (multiple SQL Server hosts,
multiple node groups, multiple ECR repos) without duplicating resource definitions. A new
environment (staging, dev) is a new directory under `environments/` that sources the same
modules — no copy-paste. Changes to a module roll out to all environments on their next apply,
which is intentional and reviewable in the PR.

**Rule for contributors:** Resource definitions go in modules. Environment directories contain
only module calls, variable values, and outputs. No `resource` blocks in `environments/`.

---

### Networking: VPC with 3 public + 3 private subnets

**Decision:** The VPC module creates 3 public subnets (one per AZ) and 3 private subnets (one
per AZ). All workloads (EKS nodes, EC2, RDS) run in private subnets. NAT Gateways in public
subnets provide outbound internet access. VPC endpoints (S3 gateway, SSM/ECR/CloudWatch/STS
interface endpoints) keep AWS API traffic off the public internet.

**Why public subnets exist:** Originally for NAT Gateways (which require a public subnet) and
initially considered for Packer build instances. Packer builds were later moved to private
subnets, so the public subnets are now exclusively for NAT Gateways and future internet-facing
load balancers if needed.

**HIPAA relevance:** VPC endpoints ensure that ECR image pulls, SSM connections, and CloudWatch
metric writes never traverse the public internet. This is both a compliance requirement and a
meaningful cost reduction (ECR traffic through NAT GW is expensive at scale).

**NAT Gateway HA:** `single_nat_gateway = false` (default) deploys one NAT GW per AZ. Set to
`true` in non-production environments to save ~$100/month per AZ.

---

### EKS IAM: Pod Identity (not IRSA)

**Decision:** EKS Pod Identity is used for all service account IAM bindings. IRSA (IAM Roles
for Service Accounts) was explicitly removed.

**Why:** Pod Identity is the current AWS-recommended approach. Key advantages over IRSA:
- No OIDC provider to provision or maintain (no TLS certificate thumbprint rotation)
- Trust policies are cluster-agnostic — the same IAM role works across multiple clusters
  without changing the trust policy
- Bindings are managed via `aws_eks_pod_identity_association` resources rather than service
  account annotations, keeping IAM config in Terraform rather than Kubernetes manifests

**How it works:** The `eks-pod-identity-agent` DaemonSet (deployed as an EKS add-on) intercepts
credential requests from pods and returns short-lived credentials for the associated IAM role.
Trust policies trust `pods.eks.amazonaws.com` and require both `sts:AssumeRole` and
`sts:TagSession`.

**For new services:** Call the `eks-app-iam` module once per service. It creates the IAM role
and the pod identity association. The Kubernetes service account (created by the Helm chart for
that service) just needs to exist — no annotation required.

---

### Node Groups: separate module calls (not a single consolidated block)

**Decision:** Each node group is a separate `module` block in `environments/production/main.tf`,
not a `for_each` over a map.

**Why:** Node groups have meaningfully different configurations (AMI type, capacity type, taints,
labels, disk size). A `for_each` over a map would require all of those fields for every group,
making the map unwieldy and losing the clarity of explicit per-group documentation. Separate
module calls also mean `terraform plan` output is scoped to the specific node group being
changed — easier to review and approve. Adding or removing a node group is a one-line PR change,
not a map key deletion that Terraform might misinterpret.

---

### Windows Node Groups: On-Demand only, no Spot

**Decision:** Windows EKS nodes use `capacity_type = "ON_DEMAND"`. Spot is not used.

**Why:**
1. Windows Spot instance availability is lower than Linux equivalents in most regions.
2. Windows nodes take 5–10 minutes to start due to image size (10GB+ vs. <1GB for Linux).
   A Spot interruption on Windows is far more disruptive than on Linux.
3. The Packer AMI pipeline pre-caches images into containerd to reduce cold start, but that
   only brings Windows start time down to ~60 seconds — still not appropriate for Spot workloads
   where you need rapid node replacement after interruption.

---

### Custom Windows AMI via Packer

**Decision:** A custom Windows EKS node AMI is built daily and pushed to SSM Parameter Store.
The Windows node group's launch template reads the AMI ID from SSM rather than hardcoding it.

**Why:** Windows container images are 5–10GB. Pulling them from ECR at node start time takes
10–15 minutes on a cold node — unacceptable for any scaling event. Pre-caching in containerd's
content store (via `ctr -n k8s.io images pull` during the Packer build) reduces cold start to
under 60 seconds. The daily build also ensures the node base AMI includes the latest AWS
security patches without any manual AMI management.

**Packer connectivity:** The build instance runs in a private subnet with no public IP. Packer
connects via SSH tunneled through SSM Session Manager. The self-hosted GitHub Actions runner
inside the VPC initiates the SSM session. The IAM instance profile (`packer-iam` module)
grants `AmazonSSMManagedInstanceCore` and scoped ECR pull permissions.

**AMI handoff:** After a successful build, the GitHub Actions workflow writes the AMI ID to
`/eks/<version>/windows-node-ami` in SSM Parameter Store. A Terraform data source reads this
path when the node group is next applied. The SHA-pinned path (`/eks/<version>/windows-node-ami/<sha>`)
is also written for rollback purposes — to roll back, update the SSM parameter to a previous
AMI ID and run `terraform apply`.

---

### ASP.NET 4.8: EC2 behind ALB, not Windows EKS nodes

**Decision:** .NET Framework 4.8 applications run on EC2 (IIS) behind an internal ALB with a
Route 53 A record. They are not migrated to Windows EKS nodes.

**Why:** Windows EKS nodes carry significant operational cost and complexity (Windows licensing
premium, no Spot, no eBPF networking, limited ecosystem tooling). EC2 behind an ALB is simpler
to operate for legacy apps during a migration window. The Route 53 DNS abstraction is the key
design element: every other service calls the DNS name, never the ALB hostname or EC2 IP. When
an app is ported to .NET 8 and moved to EKS, only the Route 53 record changes — every caller
is unaffected.

**Migration path:** Option B (keep on EC2) short-term → Option C (.NET 8 port) medium-term.
Windows EKS nodes (Option A) are the last resort, only for apps with genuine blockers to
.NET 8 migration. See `docs/migration-strategy.md` for full analysis.

---

### SQL Server: `prevent_destroy` + SSM automation for disk operations

**Decision:** The EC2 SQL Server instance has `prevent_destroy = true` and
`ignore_changes = [ami, user_data]`. Disk extension is handled by an SSM Automation document,
not by Terraform.

**Why:** SQL Server instances hold production data. `prevent_destroy` catches accidental
`terraform destroy` commands. `ignore_changes` on `ami` and `user_data` prevents Terraform from
replacing the instance when a new Windows base AMI is released — AMI updates on SQL Server
hosts go through a separate patching process (SSM Patch Manager or manual), not through
Terraform instance replacement.

The SSM Automation document (`ebs-resize-and-extend`) handles the two-step EBS resize process:
it calls `ec2:ModifyVolume`, waits for the modification to reach `optimizing` or `completed`
(the prerequisite for the OS to see new blocks), then runs `Resize-Partition` inside the
instance. This ordering is non-negotiable — `Resize-Partition` will silently do nothing if
called before the EBS modification completes.

---

### GitHub Actions: secrets vs. variables

**Decision:** Only genuinely sensitive values use GitHub Secrets. Non-sensitive infrastructure
identifiers use GitHub Variables (`vars.*`).

**Secrets (sensitive):**
- `AWS_ROLE_ARN` — IAM role ARN for OIDC authentication

**Variables (non-sensitive):**
- `AWS_REGION`
- `ECR_REGISTRY` — registry hostname, not a credential
- `EKS_VERSION`
- `PACKER_SUBNET_ID` — subnet ID from `terraform output -raw packer_subnet_id`
- `PACKER_INSTANCE_PROFILE` — profile name from `terraform output -raw packer_instance_profile_name`

**Why this matters:** Secrets are masked in logs and hidden from repo members with read access.
Overusing secrets obscures non-sensitive values unnecessarily, makes debugging harder (masked
output), and creates confusion about what actually needs to be protected.

---

## Deployment: First-Time Setup

### Prerequisites

- AWS CLI configured with credentials for the target account
- Terraform >= 1.5.0
- An S3 bucket and DynamoDB table for Terraform state (one-time setup, done manually)

### Step 1: Enable the S3 backend

Uncomment the `backend "s3"` block in `terraform/environments/production/backend.tf` and
fill in the bucket name, key, region, and DynamoDB table name.

### Step 2: Create `terraform.tfvars`

```bash
cp terraform/environments/production/terraform.tfvars.example \
   terraform/environments/production/terraform.tfvars
```

Fill in account-specific values. The file is gitignored — do not commit it.

### Step 3: Apply

```bash
cd terraform/environments/production
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

The first apply creates everything: VPC, EKS cluster, node groups, ECR repos, IAM roles,
SQL Server EC2 host, IIS EC2 hosts, and the Packer IAM instance profile.

### Step 4: Configure GitHub Actions

After the first apply, populate GitHub repo variables and secrets:

```bash
# Variables (Settings > Secrets and variables > Actions > Variables)
terraform output -raw packer_subnet_id          # → PACKER_SUBNET_ID
terraform output -raw packer_instance_profile_name  # → PACKER_INSTANCE_PROFILE

# Also set: AWS_REGION, ECR_REGISTRY, EKS_VERSION
# Secret: AWS_ROLE_ARN (the IAM role ARN for GitHub Actions OIDC)
```

### Step 5: Build the first Windows AMI

Trigger the `Build Windows EKS Node AMI` workflow manually from the Actions tab. This builds
the base Windows container image, then the Packer AMI, then writes the AMI ID to SSM Parameter
Store. Subsequent `terraform apply` runs on the node group will pick up the new AMI.

---

## Deployment: Adding a New .NET 8 Service to EKS

1. Add an ECR repository in `environments/production/main.tf`:
   ```hcl
   module "ecr_my_service" {
     source      = "../../modules/ecr-repository"
     name        = "my-service"
     environment = var.environment
     tags        = var.common_tags
   }
   ```

2. Add a Pod Identity IAM role:
   ```hcl
   module "iam_my_service" {
     source               = "../../modules/eks-app-iam"
     app_name             = "my-service"
     cluster_name         = module.eks_cluster.cluster_name
     namespace            = "production"
     service_account_name = "my-service"
     ssm_path_prefix      = "/production/my-service"
     environment          = var.environment
     tags                 = var.common_tags
   }
   ```

3. Add the ECR URL and IAM role ARN to `outputs.tf` so they are visible after apply.

4. Run `terraform apply`. The Kubernetes service account just needs to exist in the cluster
   (created by the Helm chart) — no annotation required for Pod Identity.

---

## Deployment: Adding an ASP.NET 4.8 App on EC2

Add a module call to `environments/production/main.tf`:

```hcl
module "iis_my_app" {
  source          = "../../modules/iis-ec2"
  app_name        = "my-app"
  ami_id          = var.windows_ami_id
  instance_type   = "m6i.xlarge"
  instance_count  = 2
  subnet_ids      = module.vpc.private_subnet_ids
  alb_subnet_ids  = module.vpc.private_subnet_ids
  vpc_id          = module.vpc.vpc_id
  vpn_cidr        = var.vpn_cidr
  route53_zone_id = var.route53_zone_id
  dns_name        = "my-app.${var.internal_domain}"
  environment     = var.environment
  tags            = var.common_tags
}
```

The `dns_name` output is the stable address every other service should call. When this app is
eventually ported to .NET 8 and moved to EKS, only the Route 53 record changes.

---

## Operational Notes

### Expanding a SQL Server disk

Use the SSM Automation document — do not attempt to resize via Terraform directly.

```bash
# 1. Get the document name and volume ID from Terraform outputs
DOCUMENT=$(terraform output -raw sql_server_01_automation_document)
VOLUME_ID=$(terraform output -raw sql_server_01_root_volume_id)

# 2. Run the automation (fills to 300 GB in this example)
aws ssm start-automation-execution \
  --document-name "$DOCUMENT" \
  --parameters "VolumeId=${VOLUME_ID},TargetSizeGB=300"
```

After the automation completes, update `root_volume_size_gb` in `main.tf` and run
`terraform apply -refresh-only` to sync Terraform state. See `docs/incident-analysis.md`
for the full state drift reconciliation procedure.

### Rolling back a Windows AMI

```bash
# List available AMI IDs stored in SSM
aws ssm get-parameters-by-path --path "/eks/1.31/windows-node-ami" --recursive

# Pin to a previous build
aws ssm put-parameter \
  --name "/eks/1.31/windows-node-ami" \
  --value "ami-0abc123previousbuild" \
  --overwrite

# Apply to update the node group launch template
cd terraform/environments/production
terraform apply -target=module.eks_windows_nodes
```

### Updating kubeconfig

```bash
$(terraform output -raw kubeconfig_update_cmd)
```

### Terraform state drift

If someone modifies infrastructure outside of Terraform (console, AWS CLI), reconcile with:

```bash
terraform apply -refresh-only
```

This updates state to match reality without changing any resources. Do not use
`terraform state rm` unless you intend to permanently abandon management of that resource.

---

## What Is Not in This Repository

- **Kubernetes manifests and Helm charts** — application deployment configs live in a separate
  repo. This repo provisions the cluster; application teams own their workload definitions.
- **RDS Terraform** — the SQL Server to RDS migration is documented in `docs/migration-strategy.md`
  but not yet provisioned. When ready, add an `rds-sql-server` module following the same pattern.
- **Staging environment** — add `terraform/environments/staging/` sourcing the same modules
  with `single_nat_gateway = true` and smaller instance types.
- **Self-hosted GitHub Actions runner** — the Packer workflow requires a self-hosted runner
  inside the VPC to reach the build instance via WinRM over SSM. Provisioning that runner
  is outside the scope of this repository.
