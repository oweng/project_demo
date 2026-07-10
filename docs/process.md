# Process and Communication

## 1. Fleet-Wide Disk Monitoring Proposal

We have a point problem (one host at 92%) and a systemic problem (no disk monitoring across ~30 Windows hosts). These need to be addressed in parallel, not sequentially.

---

**Immediate (this week)**
- Identify all hosts currently above 80% using existing CloudWatch data (if CWAgent is installed) or a one-time SSM Run Command fleet-wide scan:
  ```
  aws ssm send-command \
    --document-name AWS-RunPowerShellScript \
    --targets Key=tag:OS,Values=Windows \
    --parameters commands='Get-PSDrive -Name C | Select-Object Name,Used,Free,@{n="PctUsed";e={[math]::Round($_.Used/($_.Used+$_.Free)*100,1)}}'
  ```
- Triage results: hosts above 90% need disk expansion scheduled this week; 80-90% need monitoring deployed and a schedule for expansion within 30 days.
- Apply this Terraform pattern to the three other known hosts above 80% immediately (reusable via `host_name` variable).

**Short term (2 weeks)**
- Deploy CloudWatch Agent to all 30 Windows EC2 hosts via SSM State Manager (enforces desired state; re-applies after reboot). This is the prerequisite for CloudWatch disk alarms.
- Extend the Terraform pattern to manage monitoring for all hosts — use a `for_each` over a map of host configurations in `terraform.tfvars`.
- Build a single CloudWatch Dashboard showing `LogicalDisk % Free Space` for all 30 hosts. One screen, one glance.
- Add this dashboard link to the on-call runbook.

**Medium term (4 weeks)**
- Create a monthly CloudWatch Scheduled Query that reports any host below 40% free. Sends a digest to the team Slack channel (not a page — a heads-up).
- Document the disk expansion procedure (this repo) and add it to the team wiki under "Runbooks."
- Add disk monitoring deployment as a required step in the "new EC2 instance" provisioning checklist.

**Preventive / structural**
- Every new instance provisioned via Terraform automatically gets the disk alarm module — make it a non-optional component of the base EC2 module.
- Set the warning threshold at 30% free (not 20%) on the fleet monitoring — more lead time for planning, fewer emergency maintenance windows.
- Include disk utilization trend in quarterly infrastructure reviews: are hosts growing toward the threshold? Size preemptively.

---

## 2. Change Management Ticket

---

**Title:** EBS Root Volume Expansion — prod-sql-server-01 | C: Drive 80GB → 200GB

**Type:** Standard Change (infrastructure expansion, no code changes)
**Priority:** High — host at 92% disk utilization; upcoming patching window at risk
**Requested By:** Platform Engineering
**Maintenance Window:** Sunday [DATE] 02:00–06:00 UTC

---

**Description**

The production SQL Server host `prod-sql-server-01` (Windows Server 2022, m6i.2xlarge) has its C: drive at 92% utilization on an 80GB gp3 EBS volume. The monthly Windows patching window requires approximately 8–12GB of free space to download and stage update packages. A prior incident resulted in a multi-hour SQL Server outage when disk exhaustion occurred during patching.

This change expands the root volume from 80GB to 200GB and extends the Windows partition to consume the new space, resolving the immediate risk and providing headroom for the next 12–18 months.

**Changes being made:**

1. Terraform apply: `root_volume_size_gb` variable set to 200. EBS ModifyVolume API call — online, no instance disruption.
2. SSM Run Command: `extend-partition.ps1` via `${environment}-sql-server-01-extend-partition` document. Extends the C: partition from 80GB to 200GB.
3. Validate via `validate-disk.ps1` — confirm C: reports ~200GB and free% is above 50%.
4. Proceed with scheduled Windows patching (previously blocked by disk state).

SQL Server does **not** need to stop for the EBS resize or partition extension. A service restart is included in the patching process itself (step 4), not required for this change.

---

**Risk Assessment**

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| EBS resize fails | Very Low | Low — existing state preserved | AWS EBS ModifyVolume is a well-tested operation; retry if needed |
| Partition extension fails | Low | Low — drive stays at 80GB, still functional | Script is idempotent; investigate error output, retry manually |
| SQL Server fails to start after restart | Low | High — service outage | See rollback plan; error log captured via SSM |
| Increased disk size causes unexpected cost | None | None | EBS gp3 200GB ~$16/month vs ~$6.40 for 80GB — pre-approved |

Overall risk: **Low**. The EBS-level operation is online and non-destructive. The partition extension is additive. The service restart is part of the normal patching process.

---

**Rollback Plan**

| Scenario | Rollback Action |
|---|---|
| EBS volume resize fails | No rollback needed; volume unchanged. Reschedule after investigating AWS Health events. |
| Partition extension fails or errors | Partition remains at 80GB. Drive still functional. Investigate error output in SSM command output. Re-run script after fixing root cause. |
| SQL Server fails to start after restart | RDP to instance via VPN or SSM Session Manager. Check `C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Log\ERRORLOG`. Common causes: TempDB autogrowth failed during startup (check for error 1105), or a startup parameter is misconfigured. Start SQL Server in single-user mode if needed. Escalate to DBA on-call if not resolved within 30 minutes. |
| EBS volume cannot be shrunk | Not required. The expansion is permanent and intentional. |

---

**Validation Steps**

Execute in order after each step before proceeding:

1. **Post-Terraform apply:** Confirm EBS volume shows 200GB in AWS Console (`EC2 > Volumes > vol-xxxxx`). Confirm Terraform output shows no further changes.
2. **Post-partition extension:** Run `validate-disk.ps1` via SSM Run Command. Expected output: `Total: 200.0 GB`, `Used: ~74 GB`, `Free: ~126 GB (~63%)`, `STATUS: OK`.
3. **Post-Windows patching:** Confirm SQL Server service is running (`Get-Service MSSQLSERVER`). Confirm SQL Server Agent is running. Confirm no error-level events in ERRORLOG within the last hour.
4. **Application smoke test:** Run the [application health check endpoint] and confirm HTTP 200 response. Check Datadog dashboard for error rate spike.
5. **Alarm state:** Confirm CloudWatch alarms `prod-sql-server-01-disk-warning` and `prod-sql-server-01-disk-critical` are in `OK` state.
6. **Sign-off:** Notify #oncall-platform and update the change ticket as completed.
