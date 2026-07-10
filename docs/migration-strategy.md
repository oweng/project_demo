# Migration Strategy

## Part 3A: .NET Applications to EKS

### 1. Options for .NET Framework 4.8 on Kubernetes

.NET Framework 4.8 is Windows-only — it cannot run on Linux containers. Three viable paths exist:

---

**Option A: Windows node groups in EKS**

EKS supports Windows Server node groups alongside Linux node groups in the same cluster. .NET Framework 4.8 applications run in Windows containers on Windows nodes.

*Tradeoffs:*
- **Pro:** Lowest code-change path. The application runs as-is in a container.
- **Pro:** Unified Kubernetes control plane manages both Windows and Linux workloads.
- **Con:** Windows EC2 instances carry Windows Server licensing, making them significantly more expensive than equivalent Linux nodes (~30-40% higher EC2 cost).
- **Con:** Windows container images are large (5–10GB vs. 50–500MB for Linux), slowing pull times and cold-start latency.
- **Con:** Not all Kubernetes ecosystem tooling works on Windows nodes (e.g., some CSI drivers, eBPF-based network policies, Falco). Operational complexity increases.
- **Con:** You're containerizing a legacy application without modernizing it — the technical debt remains, now wrapped in Docker.

---

**Option B: Keep .NET Framework 4.8 on EC2, expose via internal ALB**

Don't migrate .NET Framework 4.8 applications to Kubernetes at all during this cycle. Keep them on EC2, register them behind an internal Application Load Balancer, and let EKS workloads reach them over standard VPC routing via the ALB DNS name.

*Tradeoffs:*
- **Pro:** Zero risk of destabilizing legacy applications during a high-change period.
- **Pro:** No Windows container complexity, no Windows node groups.
- **Pro:** Buys time to modernize the applications properly without creating pressure for a rushed containerization.
- **Con:** Two deployment models to operate simultaneously (Terraform EC2 infra + Kubernetes). Each app team needs to know which model applies to their service.
- **Con:** These applications don't get any of the Kubernetes deployment benefits (rolling deploys, self-healing, HPA).

---

**Option C: Rewrite to .NET 8 (the real fix)**

Migrate .NET Framework 4.8 applications to .NET 8, which runs on Linux. Microsoft's [.NET Upgrade Assistant](https://dotnet.microsoft.com/en-us/platform/upgrade-assistant) automates much of the mechanical conversion. Once on .NET 8, these apps can use standard Linux containers and Linux EKS node groups.

*Tradeoffs:*
- **Pro:** Eliminates the architectural debt permanently. These apps become first-class Kubernetes citizens.
- **Pro:** Reduces long-term operational cost (no Windows nodes or separate EC2 fleet).
- **Con:** Development effort varies widely — simple CRUD services may convert in days; apps using Windows-specific APIs (COM interop, Windows Forms, WCF services with NetTcpBinding) may require weeks or significant refactoring.
- **Con:** Requires developer time that may compete with feature work.

---

**Recommendation: Option B short-term, Option C medium-term, Option A only as a last resort.**

During the 6-12 month migration window, keep .NET Framework 4.8 apps on EC2 behind an internal ALB. In parallel, triage the apps: most will be straightforward .NET 8 ports; a few may have genuine blockers (COM interop, legacy dependencies). Use the migration to EKS for .NET 8 services as a forcing function to build the platform, then migrate the ported apps into the cluster rather than ever running Windows nodes in production.

Windows EKS nodes (Option A) should only be considered for apps with genuine technical blockers to .NET 8 migration — not as a default path.

---

### 2. EKS Cluster Design for .NET 8 Services

#### Node Group Strategy

The cluster runs four node groups, each serving a distinct purpose. The Terraform `eks-nodegroup` module is called once per group, making additions and removals explicit in code review.

**System — On-Demand, static**
`m6i.xlarge`, min=3/max=3, one node per AZ. Runs CoreDNS, kube-proxy, AWS Load Balancer Controller, and the Datadog agent DaemonSet. Tainted `CriticalAddonsOnly:NoSchedule` so application pods never land here. Never Spot — losing all three nodes simultaneously would take down in-cluster DNS for every workload.

**Linux apps — On-Demand baseline**
`m6i.2xlarge`, min=2/max=10. For latency-sensitive or stateful .NET 8 services that cannot tolerate a Spot interruption. Pod Disruption Budgets are set to `maxUnavailable: 1` on these workloads to guarantee availability during node group rolling updates.

**Linux apps — Spot burst pool**
`m6i.2xlarge`, `m6a.2xlarge`, `m5.2xlarge`, `m6i.4xlarge`, `m6a.4xlarge`, min=0/max=30. Spot interruption rates are correlated within a single instance family at a given size in a given AZ — spreading across three families (`m6i`, `m6a`, `m5`) significantly reduces the probability of simultaneous interruptions. Targets stateless .NET 8 APIs and SQS-backed background workers that can restart within 30 seconds. At steady state, approximately 70% of application pods run on Spot.

**Windows apps — On-Demand**
`m6i.2xlarge`, min=1/max=10, `WINDOWS_CORE_2022_x86_64` AMI. Reserved for .NET Framework 4.8 workloads that cannot be ported to Linux during the migration window. Tainted `os=windows:NoSchedule` — pods must carry a matching toleration, preventing Linux images from being accidentally scheduled here. Not Spot for three reasons: (1) Windows Spot availability is lower than Linux equivalents — the effective instance pool is smaller, making interruptions more likely; (2) Windows nodes take 5–10 minutes to start from a cold AMI pull — even with the custom Packer AMI reducing this to ~60 seconds, that is still 4× slower than Linux and unacceptable as a recovery path after interruption; (3) .NET Framework 4.8 applications tend to be stateful or have slow startup sequences, making a Spot-driven pod restart more disruptive than for stateless .NET 8 APIs.

**Scaling**

Karpenter manages the Spot pool — it provisions nodes directly from the EC2 API, handles mixed instance families natively, and responds to pending pods faster than Cluster Autoscaler. The On-Demand groups use standard EKS Managed Node Group autoscaling. Terraform ignores `desired_size` after initial apply so autoscalers can manage it without Terraform fighting them on every plan.

HPA scales pods on CPU/memory for synchronous request workloads. KEDA scales on SQS queue depth for background workers — a common pattern in .NET architectures where jobs are enqueued via SQS and processed by worker services.

---

#### Namespace Design

```
kube-system      — cluster add-ons only; no application workloads
monitoring       — Datadog agent, CloudWatch Container Insights
ingress          — AWS Load Balancer Controller, external-dns
production       — all production application workloads
staging          — staging workloads (separate cluster preferred; shared if cost-constrained)
shared-services  — internal tooling, common infrastructure services
```

Network policies are deny-by-default at the namespace level. Pods in `production` that process PHI data require explicit ingress/egress allow rules scoped to the specific service accounts that need access — a HIPAA requirement, not just good practice.

RBAC is scoped to label selectors rather than per-team namespaces. At this scale (~30 services), per-team namespaces add operational fragmentation without meaningful isolation benefit. Teams own their deployments via label-based RBAC; the namespace structure stays flat and readable.

---

#### Hybrid Transition Period (EC2 ↔ EKS Coexistence)

EKS pods and EC2 instances share the same VPC, so east-west connectivity exists without a service mesh or any additional networking configuration. The critical constraint is that service addresses must not be IP-based — pod IPs are ephemeral and EC2 instance IPs change — so all cross-substrate communication is routed through stable DNS names.

**EKS → EC2 (most traffic during migration)**

EC2 applications are fronted by internal ALBs with DNS records in a Route 53 private hosted zone. EKS pods call the ALB hostname. When an EC2 host is replaced or scaled, the DNS record updates transparently — no pod reconfiguration needed.

**EC2 → EKS**

EKS services are exposed via internal ALBs provisioned by the AWS Load Balancer Controller (`alb.ingress.kubernetes.io/scheme: internal`). The ALB DNS name is registered in the same Route 53 private hosted zone. EC2 applications call that hostname; the underlying pod IPs are invisible to them.

**The migration pattern this enables:** to migrate a service from EC2 to EKS, update the Route 53 record from the EC2 ALB to the EKS ALB. Every other service continues calling the same DNS name. The cutover is a DNS update, not a configuration change in every caller. This makes individual service migrations low-risk and independently reversible.

A service mesh (Istio, Linkerd) is not required for this transition. It should only be introduced if mutual TLS between services becomes a compliance requirement — not as a default, as the operational overhead is significant.

---

## Part 3B: SQL Server to RDS

### 1. Recommended RDS Instance Class and Storage

**Instance class: `db.r6i.4xlarge`** (16 vCPU, 128 GB RAM)

SQL Server OLTP is memory-bound before it is CPU-bound. The buffer pool cache is the primary performance lever — larger RAM means more of the 400GB database's hot data stays in memory, reducing physical reads. A `db.r6i.4xlarge` gives 128GB of RAM, enough to cache a substantial portion of the hot working set for a 400GB database.

Before finalizing this choice, pull the current EC2 instance's `BufferPoolHitRate` counter from SQL Server's performance DMVs and the `VolumeReadOps` metric from CloudWatch. If cache hit rate is already >99%, a smaller instance class may suffice. If it's lower, go larger.

`db.r6i.2xlarge` (64GB RAM) is a reasonable starting point if budget is constrained — but plan to scale up if p99 latency degrades during load testing.

**Storage: `gp3` with provisioned IOPS**

For a 400GB high-throughput OLTP database:
- Start with `gp3`, 2TB provisioned (headroom for growth + required overhead for Multi-AZ)
- IOPS: pull actual numbers from the EC2 host (`VolumeReadOps` + `VolumeWriteOps` in CloudWatch). A 400GB transactional database is often in the 2,000–8,000 IOPS range. `gp3` supports up to 16,000 IOPS independently of volume size — no need for `io2` unless peak IOPS exceed that ceiling.
- Throughput: `gp3` up to 1,000 MB/s is typically sufficient

`io2 Block Express` is the right call only if sustained IOPS > 16,000 or sub-millisecond I/O consistency is required. At that point the workload likely also needs an `io2`-optimized instance class.

**Multi-AZ:** Yes, mandatory. RDS Multi-AZ with two readable standbys (Multi-AZ DB Cluster) is available for SQL Server and provides both HA and the ability to offload reads if needed.

**License:** RDS License Included (Standard Edition or Enterprise Edition based on features required). Healthcare environments commonly need Enterprise Edition for features like TDE (Transparent Data Encryption), which is required for HIPAA encryption-at-rest on database files.

---

### 2. EC2 Volume Layout → RDS Mapping

The standard EC2 SQL Server practice of separate EBS volumes (data files on a high-IOPS `io2`, transaction logs on a second `io2`, tempdb on a local NVMe SSD or separate volume) does not have a direct equivalent in RDS.

**What maps over:**
- Data files and transaction logs share the single provisioned RDS storage volume. RDS manages file placement internally.
- You control IOPS and throughput at the volume level, not per-file-group.

**What is lost:**

| Capability | EC2 + EBS | RDS |
|---|---|---|
| Separate IOPS per file type | Yes — tune data and log independently | No — single volume |
| TempDB placement | Configurable; often local NVMe | Local SSD (AWS manages this; tempdb is on instance storage, which is actually good) |
| Direct filesystem access | Yes — snapshot, rsync, etc. | No filesystem access |
| Per-volume snapshots | Yes | Single RDS snapshot covers everything |
| Custom startup parameters | Yes — SQL Server Configuration Manager | No — use RDS Parameter Groups (limited subset) |
| DBCC CHECKDB to file | Full control | Restricted; CHECKDB runs differently on RDS |
| Trace flags at startup | Yes | No — some trace flags available via Parameter Groups |

The most operationally significant loss is fine-grained I/O tuning. On EC2, a DBA can tune read/write separation, pre-allocate log files to avoid autogrowth, and set tempdb file count to match CPU cores. On RDS, you configure the aggregate volume IOPS and trust RDS's internal management. For most workloads this is acceptable; for highly tuned OLTP it may require adjustment of query patterns instead.

---

### 3. Biggest Risk and Pre-Cutover Performance Validation

**Biggest risk: write latency regression**

RDS Multi-AZ performs synchronous replication to a standby before acknowledging commits. This adds 1–3ms of write latency per commit compared to single-node EC2 SQL Server. For a high-throughput OLTP workload that issues many small, frequent commits, this latency can materially reduce TPS.

The second risk is EBS I/O consistency. RDS uses EBS-backed storage with slightly different I/O characteristics than directly managed EBS on EC2. `WRITELOG` wait times (the SQL Server wait type for log I/O) are the key signal.

**Validation approach:**

1. Build the RDS instance at target spec 4 weeks before cutover.
2. Restore the most recent full backup to RDS. Bring transaction logs current.
3. Collect a baseline from the EC2 instance: TPS from `sys.dm_os_performance_counters`, p50/p99 query duration from Query Store, dominant wait types from `sys.dm_os_wait_stats`, and `VolumeWriteOps` / `VolumeReadOps` from CloudWatch.
4. Replay production-representative load against RDS using either:
   - **SQL Server Distributed Replay** (replays actual captured workload traces)
   - **HammerDB** (synthetic OLTP benchmarking — use as a relative comparison tool, not an absolute benchmark)
5. Run for at least 48 hours to include daily batch jobs, end-of-month reports, or other periodic heavy operations.
6. Compare: TPS, p99 latency, `WRITELOG` wait time (must not exceed EC2 baseline by >20%), buffer pool hit rate.
7. Get explicit sign-off from the application team and DBA team on the performance results before any cutover date is set.

---

### 4. Cutover Strategy

**Phased cutover with a short maintenance window** — not big-bang, not a week-long parallel run.

The risk of a big-bang cutover on a 400GB production OLTP database is too high. The risk of a multi-week parallel run is data divergence and operational complexity. A phased approach with a defined maintenance window gives the best risk/reversibility balance.

**Timeline:**

| Phase | Action |
|---|---|
| T-4 weeks | RDS provisioned, DBA team completes initial bulk load, ongoing log shipping established |
| T-2 weeks | Performance validation complete, stakeholder sign-off obtained |
| T-1 week | Maintenance window booked, change management submitted, connection string updates prepared in SSM Parameter Store (not deployed yet) |
| Cutover night | See steps below |
| T+7 days | Decommission EC2 SQL Servers (if no rollback required) |

**Cutover window steps (target: 2-4 hour window, off-peak):**

1. Notify stakeholders: maintenance starts.
2. Put application in maintenance mode (HTTP 503 at load balancer) to stop new writes.
3. Wait for final transaction log to synchronize to RDS. Confirm lag is zero.
4. Update connection strings in AWS SSM Parameter Store (or Secrets Manager) — all apps pull from Parameter Store, so this is a single atomic change.
5. Bounce application services (or trigger config reload) to pick up new connection string.
6. Run smoke tests against RDS via the application layer.
7. Monitor: CloudWatch, Datadog, application error rates for 30 minutes.
8. If clean: remove maintenance mode, open traffic.
9. **Do not decommission EC2 SQL Servers yet.** Keep them running (read-only mode) for 7 days.

**Rollback plan:**

Connection strings are in SSM Parameter Store — rollback is a single `aws ssm put-parameter` call followed by an application restart. Recovery time is under 5 minutes.

The data loss window on rollback is writes that occurred on RDS between cutover and rollback. This cannot be automatically replicated back to EC2. For this reason, rollback after day 2 becomes increasingly risky as data diverges. If performance problems emerge late (after 48+ hours), the decision is more complex — at that point you're likely fixing the problem on RDS rather than rolling back.

**HIPAA note:** Ensure RDS audit logging (SQL Server Audit) is configured and actively writing to S3 before cutover. Audit log continuity is a compliance requirement — a gap in the audit trail during migration must be documented and justified.
