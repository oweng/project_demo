# Incident Analysis

## 1. Why is a nearly full C: drive dangerous on a Windows SQL Server host?

A full C: drive is dangerous on any Windows host, but SQL Server introduces additional failure modes because the engine depends on the OS drive for critical runtime operations even when data and log files live elsewhere.

**TempDB exhaustion (error 1105)**

TempDB is frequently left on C: after installation even when user databases are moved elsewhere. SQL Server uses TempDB internally for sort spills, hash joins, cursors, row versioning (required for snapshot isolation and RCSI), temp tables, and online index rebuilds. When TempDB autogrowth events fail because C: is full, queries fail mid-execution with error 1105. Partial transactions hold locks, lock waits accumulate, and new connections requiring row versioning cannot open — the instance appears up but no queries complete. This cascade is indistinguishable from a total outage at the application layer.

**ERRORLOG write failure and inability to restart**

SQL Server writes a startup header to `C:\Program Files\Microsoft SQL Server\MSSQL{version}.{instance}\MSSQL\Log\ERRORLOG` before accepting any connections. If C: is full when the service attempts to start — as it would be after the reboot that follows Windows patching — the write fails and the service enters a failed state. The EC2 instance is healthy, the Windows service entry exists, but SQL Server is not running. Recovery requires freeing disk space before a restart is even possible, turning a planned maintenance window into an unplanned outage.

**Additional operationally significant risks**

- Windows Update staging (`C:\Windows\SoftwareDistribution`) cannot download patch files — the patching process that triggered this incident fails or corrupts mid-download
- SQL Server crash dumps cannot be written to the Log directory, eliminating post-mortem diagnostics for any crash that occurs while C: is full
- SQL Server Agent job step output files fail silently, making failed maintenance jobs (DBCC, index rebuild, backups) appear to succeed with no output to investigate
- The Windows pagefile cannot expand under memory pressure, potentially causing kernel-level instability

At 92% utilization on an 80GB volume, the remaining ~7GB is easily consumed by any one of these — a single patch download, a TempDB autogrowth event, or a routine ERRORLOG rotation — before the patching window even begins.

---

## 2. What happens if you skip the OS-level partition extension after an EBS resize?

**Nothing changes from the OS or application perspective — and that invisibility is the problem.**

EBS volume modification increases the underlying block device at the storage layer. Once the modification reaches `optimizing` or `completed` state, the hypervisor exposes a larger block device to the guest OS. But Windows maintains a partition table (GPT) that maps the C: partition to a specific sector range — the original 80GB worth of sectors. The new blocks are outside that range and appear as **unallocated space** in Disk Management.

The C: partition still reports 80GB. `Get-PSDrive -Name C` returns the old capacity. SQL Server, IIS, and Windows cannot use any of the new space. The CloudWatch disk alarm fires again at the next collection interval because utilization is unchanged. An operator who verified the AWS console showed 200GB and closed the ticket has not actually resolved the problem.

`Resize-Partition` extends the partition table entry to claim the unallocated blocks. This is online — no reboot, no SQL Server restart, no I/O disruption. After it runs, `Get-PSDrive` immediately reports the new total size.

There is one ordering constraint: `Get-PartitionSupportedSize` returns a `SizeMax` equal to the current partition size if the EBS modification is still in `modifying` state. The extension appears to succeed but nothing grows. The SSM Automation document (`ebs-resize-and-extend`) handles this by using `aws:waitForAwsResourceProperty` to confirm the modification is `optimizing` or `completed` before running `Resize-Partition` — this is why the Automation document exists rather than running the Run Command document immediately after `terraform apply`.

`validate-disk.ps1` explicitly checks for this gap by comparing `Get-PartitionSupportedSize SizeMax` against the current partition size and warns if unclaimed space exists.

---

## 3. Reconciling Terraform state (80GB) vs. AWS console reality (120GB)

This is state drift — Terraform's state file is out of sync with actual infrastructure. Someone expanded the volume manually and neither updated the Terraform variable nor ran `terraform apply` afterward.

**What not to do:**
- Apply with the variable still at 80GB — Terraform will attempt to shrink the volume from 120GB to 80GB. EBS does not support shrinking; the apply fails with `InvalidParameterValue: New size cannot be smaller than existing size`.
- `terraform state rm` + re-import — more disruptive than necessary, loses resource history, and still requires the same variable update.

**The correct approach:**

**Step 1 — Sync state to reality without touching infrastructure:**
```bash
terraform apply -refresh-only
```
This reads current resource state from AWS and updates the state file to match. No infrastructure changes are made. Terraform now correctly knows the volume is 120GB.

**Step 2 — Set the variable to the actual target:**

Update `root_volume_size_gb = 200` in `terraform.tfvars`. Do not set it to 120 to match current state — that creates an accurate but pointless intermediate commit.

**Step 3 — Validate the plan shows exactly one change:**
```bash
terraform plan
```
Expected output:
```
~ root_block_device {
    ~ volume_size = 120 -> 200
  }
```
If anything else appears — instance replacement, security group changes — stop and investigate. The `prevent_destroy = true` lifecycle rule blocks instance replacement, but understanding unexpected plan output is always the right call before applying to a production SQL Server.

**Step 4 — Apply and extend the partition:**
```bash
terraform apply
```
EBS expansion is online. After the modification completes, run the partition extension via SSM as documented in the runbook.

**Step 5 — Document and prevent recurrence:**

Commit the variable change with a message that records the history of the manual change and the drift reconciliation. Going forward, a scheduled `terraform plan -detailed-exitcode` in CI detects drift before it becomes a production mystery — exit code 2 means changes exist and should trigger an alert. Restricting `ec2:ModifyVolume` to the CI/CD IAM role via least-privilege prevents this class of drift from being created in the first place.
