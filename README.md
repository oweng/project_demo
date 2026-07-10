# Healthcare Infrastructure Platform

Infrastructure-as-code for a HIPAA-regulated healthcare environment undergoing migration from
EC2-based deployments to EKS. Covers immediate operational needs (SQL Server disk management)
and the full migration path (.NET services to EKS, SQL Server to RDS).

---

## Repository Structure

```
terraform/
  modules/
    vpc/              VPC, subnets, NAT Gateways, VPC endpoints
    eks-cluster/      EKS control plane, Pod Identity agent, EBS CSI driver
    eks-nodegroup/    Reusable managed node group (Linux and Windows)
    eks-app-iam/      Pod Identity IAM role per .NET 8 service
    ec2-sql-server/   SQL Server EC2 host with CloudWatch alarms and SSM automation
    iis-ec2/          ASP.NET 4.8 IIS hosts behind internal ALB and Route 53
    ecr-repository/   ECR repository with lifecycle policies
    packer-iam/       IAM instance profile for Packer build instances
  environments/
    production/       Wires all modules together for the production account

packer/
  windows-eks-node.pkr.hcl   Custom Windows EKS node AMI
  scripts/
    configure-node.ps1        Pre-caches container images into containerd

docker/
  windows-dotnet48/
    Dockerfile                Base Windows container image for ASP.NET 4.8

scripts/
  extend-partition.ps1        Idempotent EBS partition extension (PowerShell)
  validate-disk.ps1           Nagios-compatible disk health check

.github/workflows/
  build-windows-ami.yml       Daily Windows AMI build pipeline

docs/
  incident-analysis.md        Part 2: SQL Server disk failure modes and Terraform drift
  migration-strategy.md       Part 3: .NET to EKS and SQL Server to RDS migration
  process.md                  Part 4: Fleet monitoring and change management process
```

---

## Part 1: SQL Server EC2 — Disk Management and Monitoring

### What the Terraform Manages

The `ec2-sql-server` module provisions and monitors a Windows Server SQL Server host:

- **200GB gp3 root volume** — encrypted, `delete_on_termination = false`
- **`prevent_destroy = true`** — Terraform refuses to destroy the instance; protecting a
  400GB OLTP database from accidental `terraform destroy` is the correct default
- **`ignore_changes = [ami, user_data]`** — AMI updates go through SSM Patch Manager, not
  Terraform instance replacement; patching should never trigger a destroy/recreate cycle on a
  database host
- **IMDSv2 enforced** (`http_tokens = "required"`) — prevents SSRF-based credential theft
- **CloudWatch Agent** configured via SSM Parameter Store, applied by State Manager Association
- **Disk alarms** on `LogicalDisk % Free Space`:
  - WARNING: ≤ 20% free (80% utilized), 2 evaluation periods to reduce noise
  - CRITICAL: ≤ 10% free (90% utilized), 1 evaluation period for immediate notification
  - `treat_missing_data = "breaching"` on both — if the agent stops reporting, alert rather
    than silently assume healthy
- **Two SSM documents** for partition extension:
  - Run Command document: extends the partition after a manual EBS resize
  - Automation document: combines `ec2:ModifyVolume` + wait for completion + `Resize-Partition`
    in a single auditable operation

### Why Two-Step Disk Extension

EBS volume modification and OS partition extension are independent operations. The EBS API
resizes the block device; the Windows partition table is unaware of this until `Resize-Partition`
is called. Critically, `Resize-Partition` must not be called until the EBS modification reaches
`optimizing` or `completed` — it will silently do nothing if called while the modification is
still `in-progress`. The SSM Automation document handles this ordering with a
`aws:waitForAwsResourceProperty` step.

`validate-disk.ps1` detects the gap between EBS size and partition size, allowing CloudWatch
alarms to catch the "volume resized but partition not extended" state before disk exhaustion
actually occurs.

### Extending a Disk in Production

```bash
cd terraform/environments/production

# Get the SSM Automation document and volume ID from outputs
DOCUMENT=$(terraform output -raw sql_server_01_automation_document)
VOLUME_ID=$(terraform output -raw sql_server_01_root_volume_id)

# Run combined resize + extend (no maintenance window required — online operation)
aws ssm start-automation-execution \
  --document-name "$DOCUMENT" \
  --parameters "VolumeId=${VOLUME_ID},TargetSizeGB=300"

# After automation completes, sync Terraform state
terraform apply -refresh-only
```

---

## Part 2: Incident Analysis

See [`docs/incident-analysis.md`](docs/incident-analysis.md) for:

- SQL Server disk failure modes (TempDB exhaustion, ERRORLOG write failure at startup, Agent
  jobs, backup paths)
- Why EBS resize does not automatically extend the Windows partition and how to detect the gap
- Terraform state drift reconciliation procedure when EBS volumes are resized outside Terraform

---

## Part 3: Migration Strategy

See [`docs/migration-strategy.md`](docs/migration-strategy.md) for the full analysis. Summary
of decisions made:

### .NET Applications

**.NET Framework 4.8** apps stay on EC2 (IIS) behind internal ALBs during the migration window.
They are not moved to Windows EKS nodes.

Windows EKS nodes carry significant cost and complexity: Windows Server licensing premium,
no Spot capacity, 5–10 minute cold start times due to image size, and limited Kubernetes
ecosystem support. EC2 behind an internal ALB is a simpler operational model for legacy apps.

The key design element is DNS abstraction: every service calls the Route 53 DNS name for the
ALB, never the ALB hostname or EC2 IP directly. When an app is ported to .NET 8 and moved to
EKS, only the Route 53 record changes — every caller is unaffected. Migration becomes a DNS
cutover, not a coordinated reconfiguration across all callers.

The recommended path: EC2 (now) → port to .NET 8 (medium-term) → EKS Linux node group (once
ported). Windows EKS nodes are the last resort for apps with genuine technical blockers to .NET 8
migration, not a default migration target.

**.NET 8** services run on Linux EKS node groups. Linux containers are first-class Kubernetes
citizens: Spot-eligible, fast to start, full ecosystem support, standard tooling.

### EKS Cluster Design

Four node groups, each with a distinct purpose:

| Node Group | Instance | Capacity | Purpose |
|---|---|---|---|
| system | m6i.xlarge | On-Demand, min=3 | CoreDNS, kube-proxy, Datadog DaemonSet |
| linux-apps-ondemand | m6i.2xlarge | On-Demand, min=2 | Latency-sensitive .NET 8 services |
| linux-apps-spot | m6i/m6a/m5 2xl+4xl | Spot, min=0 | Stateless APIs and background workers |
| windows-apps | m6i.2xlarge | On-Demand, min=1 | .NET Framework 4.8 (if needed) |

The system node group is tainted `CriticalAddonsOnly:NoSchedule` — losing all three nodes
simultaneously (Spot interruption) would take down in-cluster DNS for every workload.
On-Demand and one node per AZ are non-negotiable here.

The Spot pool uses three instance families (`m6i`, `m6a`, `m5`) to reduce the probability of
simultaneous interruption — capacity events within a single family at a given size in a given
AZ are correlated.

Node groups are separate Terraform module calls rather than a `for_each` map. Each group has
meaningfully different configuration; separate calls produce explicit, scoped `terraform plan`
output and make adding or removing a group a one-line PR change.

### Spot vs. On-Demand Decision

**System nodes: always On-Demand.**
CoreDNS and kube-proxy run as DaemonSets on these nodes. If all three system nodes are
interrupted simultaneously (possible with Spot — a capacity event can reclaim all instances of
a given type in an AZ at once), in-cluster DNS goes down for every workload in the cluster.
The cost of three `m6i.xlarge` On-Demand instances is trivial compared to the blast radius of
a cluster-wide DNS outage. On-Demand and one node per AZ are non-negotiable here.

**Linux app On-Demand baseline: min=2, stable floor.**
Latency-sensitive services and anything with a Pod Disruption Budget that cannot tolerate
simultaneous pod evictions run here. At steady state this group is intentionally undersized —
the Spot pool handles burst. The On-Demand group ensures there is always a safe landing zone
if Spot capacity disappears entirely.

**Linux app Spot pool: the cost lever.**
At steady state, approximately 70% of application pods run on Spot. Five instance types across
three families (`m6i`, `m6a`, `m5`) are configured. This diversification is intentional: Spot
interruption events are correlated within a single family at a given size in a given AZ. Spreading
across families and sizes significantly reduces the probability of simultaneous interruptions
across all nodes. `min=0` allows the pool to scale to zero when load drops — Karpenter will
reprovision within seconds when pending pods appear.

**Windows nodes: On-Demand only.**
Three reasons Spot is not viable for Windows nodes:
1. Windows Spot availability is lower than Linux equivalents in most regions — the effective
   instance type pool is smaller.
2. Windows nodes take 5–10 minutes to start from a cold AMI pull. With the custom Packer AMI
   (pre-cached images), this drops to ~60 seconds — but that is still 4× slower than Linux
   node start times and unacceptable as a recovery path after Spot interruption.
3. .NET Framework 4.8 applications tend to be stateful or have slow startup sequences. A Spot
   interruption causing a 2-minute pod restart gap is more disruptive for these workloads than
   for stateless .NET 8 APIs.

### Scaling Strategy

**Karpenter** manages the Spot pool. It provisions nodes directly from the EC2 Fleet API,
handles mixed instance families natively, and responds to pending pods faster than Cluster
Autoscaler (seconds vs. minutes). Karpenter is tagged via `karpenter.sh/discovery` on the
cluster for automatic node pool discovery.

**HPA** (Horizontal Pod Autoscaler) scales pod count on CPU and memory for synchronous
request-handling workloads — the standard pattern for .NET 8 HTTP APIs. HPA drives pending
pods onto the cluster; Karpenter provisions nodes to satisfy them.

**KEDA** scales on SQS queue depth for background worker services — a common pattern in .NET
architectures where jobs are enqueued to SQS and processed by long-running worker pods. KEDA
scales to zero when the queue is empty, which pairs naturally with the Spot pool's `min=0`.

**`desired_size` is excluded from Terraform lifecycle management** (`ignore_changes =
[scaling_config[0].desired_size]`). After the initial apply sets the starting count, autoscalers
own this value. Without this exclusion, every `terraform apply` would reset `desired_size` to
the value in code, fighting the autoscaler and potentially draining nodes mid-traffic.

### IAM: EKS Pod Identity (not IRSA)

Pod Identity is the current AWS-recommended approach for pod-level IAM and replaces IRSA. Key
differences:

- No OIDC provider to provision or maintain
- Trust policies are cluster-agnostic — the same IAM role works across clusters without
  changing the trust policy
- Bindings are managed as `aws_eks_pod_identity_association` Terraform resources rather than
  Kubernetes service account annotations

Each .NET 8 service gets its own IAM role via the `eks-app-iam` module, scoped to only the
AWS resources it needs (SSM paths, S3 buckets). No shared roles, no permissions inherited from
the node role.

### SQL Server to RDS

Key decisions and assumptions:

- **Instance class: `db.r6i.4xlarge`** (128GB RAM) — SQL Server OLTP is memory-bound before
  CPU-bound; buffer pool hit rate is the primary performance lever
- **Storage: gp3 with provisioned IOPS** — pull actual IOPS numbers from
  `VolumeReadOps`/`VolumeWriteOps` CloudWatch metrics on the current EC2 host before finalizing
- **Multi-AZ: mandatory** — healthcare data cannot tolerate single-AZ failure
- **Biggest risk: write latency** — Multi-AZ synchronous replication adds 1–3ms per commit;
  validate against production-representative load for 48 hours before setting a cutover date
- **Cutover: phased with a maintenance window** — connection strings are in SSM Parameter Store;
  rollback is a single `aws ssm put-parameter` call followed by an application restart

---

## Part 4: Fleet Monitoring and Change Management

See [`docs/process.md`](docs/process.md) for the fleet-wide disk monitoring proposal (SSM
Run Command + State Manager) and the structured change management ticket template.

---

## Custom Windows EKS AMI Pipeline

Windows container images are 5–10GB. Pulling from ECR at node start time takes 10–15 minutes
— unacceptable for any scaling event. The Packer pipeline pre-caches images into containerd
during the AMI build, reducing cold start to under 60 seconds.

**Pipeline (`.github/workflows/build-windows-ami.yml`):**

1. **Job 1** (windows-2022 runner): Builds and pushes the ASP.NET 4.8 base Docker image to ECR
   with two tags — `<git-sha>` (immutable, pinned for deployments) and `latest` (mutable,
   convenience reference). Runs on Windows because Windows container images cannot be
   cross-compiled from Linux.

2. **Job 2** (self-hosted runner inside VPC): Runs Packer to build the Windows EKS node AMI.
   Packer connects to the build instance via SSH tunneled through SSM Session Manager — no
   public IP, no inbound ports. After a successful build, the AMI ID is written to SSM
   Parameter Store at `/eks/<version>/windows-node-ami` for Terraform to consume.

3. **Job 3** (self-hosted runner): Deregisters AMIs older than the last 7 builds and deletes
   their EBS snapshots.

The pipeline runs daily to pick up the latest AWS-patched base AMI. The self-hosted runner is
required for Job 2 and 3 because the Packer build instance is in a private subnet with no
public IP — a GitHub-hosted runner cannot reach it over WinRM.

---

## Assumptions

- **HIPAA compliance is a hard constraint.** All EBS volumes are encrypted. All SNS topics are
  encrypted. VPC endpoints keep AWS API traffic (ECR, SSM, CloudWatch, STS) off the public
  internet. All resources are tagged `DataClass=PHI`.

- **IMDSv2 is enforced everywhere.** `http_tokens = "required"` on all EC2 instances and node
  group launch templates. `http_put_response_hop_limit = 2` on node groups so pods can reach
  the metadata service through the network namespace boundary.

- **No SSH keys.** Operational access to all EC2 instances (SQL Server, IIS, Packer build) goes
  through SSM Session Manager. No inbound 22 or 3389 from the internet. RDP from VPN CIDR only,
  for cases where Session Manager is insufficient.

- **Terraform state is remote.** The S3 backend block in `backend.tf` is commented out and must
  be configured before first use. Local state is not appropriate for a team environment. A
  DynamoDB table is required for state locking.

- **The self-hosted GitHub Actions runner exists.** The Packer AMI build job assumes a
  self-hosted runner labeled `self-hosted` is running inside the VPC. Provisioning that runner
  is outside the scope of this repository.

- **`desired_size` on node groups is managed by autoscalers after initial apply.** Terraform
  ignores `scaling_config[0].desired_size` after creation so Karpenter and EKS managed
  autoscaling can operate without Terraform resetting counts on every plan.

---

## Deployment

### Prerequisites

- Terraform >= 1.5.0
- Packer >= 1.10.0 (for local AMI validation only)
- AWS CLI configured for the target account
- S3 bucket and DynamoDB table for Terraform state (created once, manually)

### First Apply

```bash
# 1. Configure the S3 backend (uncomment block in backend.tf, fill in values)

# 2. Create tfvars
cp terraform/environments/production/terraform.tfvars.example \
   terraform/environments/production/terraform.tfvars
# Edit with account-specific values — do not commit this file

# 3. Apply
cd terraform/environments/production
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### Configure GitHub Actions

After the first apply, set these in GitHub (Settings → Secrets and variables → Actions):

**Variables** (non-sensitive):
```
AWS_REGION                 = us-east-1
ECR_REGISTRY               = <account>.dkr.ecr.us-east-1.amazonaws.com
EKS_VERSION                = 1.31
PACKER_SUBNET_ID           = $(terraform output -raw packer_subnet_id)
PACKER_INSTANCE_PROFILE    = $(terraform output -raw packer_instance_profile_name)
```

**Secrets** (sensitive):
```
AWS_ROLE_ARN               = <IAM role ARN for GitHub Actions OIDC>
```

Then trigger the `Build Windows EKS Node AMI` workflow manually to build the first AMI before
applying the Windows node group.

### Validation

```bash
cd terraform/environments/production
terraform init -backend=false
terraform validate    # No AWS credentials required

cd ../../..
terraform fmt -check -recursive terraform/

packer init packer/windows-eks-node.pkr.hcl
packer validate \
  -var "ecr_registry=123456789012.dkr.ecr.us-east-1.amazonaws.com" \
  -var "image_tag=abc123" \
  -var "subnet_id=subnet-0abc123" \
  -var "iam_instance_profile=packer-eks-node-builder-production" \
  packer/windows-eks-node.pkr.hcl
```

All three pass cleanly.
