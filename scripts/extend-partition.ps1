<#
.SYNOPSIS
    Extends a Windows disk partition to use all available space after an EBS volume resize.

.DESCRIPTION
    After an EBS volume is resized (via Terraform or AWS Console), the new blocks are visible
    to the OS as unallocated space but are NOT automatically claimed by the existing partition.
    This script extends the partition using PowerShell's Resize-Partition cmdlet.

    The script is idempotent — safe to run multiple times. If the partition is already at
    maximum size it exits cleanly with no changes.

    Run via SSM Run Command (preferred in production) or directly on the instance.

.PARAMETER DriveLetter
    Drive letter to extend. Single letter, no colon. Defaults to C.

.EXAMPLE
    # Run locally on the instance
    .\extend-partition.ps1 -DriveLetter C

.EXAMPLE
    # Run via SSM from your workstation
    aws ssm send-command `
      --document-name AWS-RunPowerShellScript `
      --targets "Key=InstanceIds,Values=i-0abc123456" `
      --parameters commands="C:\scripts\extend-partition.ps1 -DriveLetter C"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[C-Zc-z]$')]
    [string]$DriveLetter = "C"
)

$ErrorActionPreference = "Stop"
$drive = $DriveLetter.ToUpper()

Write-Output "=== Windows Partition Extension Script ==="
Write-Output "Target drive  : $($drive):"
Write-Output "Timestamp     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output "Running as    : $($env:USERNAME)"
Write-Output ""

try {
    $partition     = Get-Partition -DriveLetter $drive
    $supportedSize = Get-PartitionSupportedSize -DriveLetter $drive
    $currentGB     = [math]::Round($partition.Size / 1GB, 2)
    $maxGB         = [math]::Round($supportedSize.SizeMax / 1GB, 2)
    $diskNumber    = $partition.DiskNumber

    Write-Output "Disk number         : $diskNumber"
    Write-Output "Current size        : $currentGB GB"
    Write-Output "Max available (EBS) : $maxGB GB"
    Write-Output ""

    if ($supportedSize.SizeMax -le $partition.Size) {
        Write-Output "Partition is already at maximum size. No action required."
        Write-Output "If you expected more space, verify the EBS volume was resized in AWS first."
        exit 0
    }

    $growthGB = [math]::Round(($supportedSize.SizeMax - $partition.Size) / 1GB, 2)
    Write-Output "Extending partition by $growthGB GB..."

    Resize-Partition -DriveLetter $drive -Size $supportedSize.SizeMax

    $newSizeGB = [math]::Round((Get-Partition -DriveLetter $drive).Size / 1GB, 2)
    Write-Output "Partition extended to $newSizeGB GB"
    Write-Output ""

    $psDrive = Get-PSDrive -Name $drive
    $total   = $psDrive.Used + $psDrive.Free
    $freeGB  = [math]::Round($psDrive.Free / 1GB, 1)
    $pctFree = [math]::Round(($psDrive.Free / $total) * 100, 1)
    $pctUsed = [math]::Round(($psDrive.Used / $total) * 100, 1)

    Write-Output "=== Post-Extension Summary ==="
    Write-Output "Drive $($drive): total=$newSizeGB GB, free=$freeGB GB ($pctFree%), used=$pctUsed%"

    if ($pctFree -lt 10) {
        Write-Warning "CRITICAL: Drive $drive is still below 10% free. The EBS resize may not have been large enough."
    } elseif ($pctFree -lt 20) {
        Write-Warning "WARNING: Drive $drive is below 20% free. Monitor closely."
    } else {
        Write-Output "STATUS: OK"
    }

} catch {
    Write-Error "Failed to extend partition $($drive): $_"
    exit 1
}
