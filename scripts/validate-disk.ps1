<#
.SYNOPSIS
    Validates disk utilization and reports partition vs. EBS block device size discrepancy.

.DESCRIPTION
    Exits with Nagios-compatible exit codes:
      0 = OK (below warning threshold)
      1 = WARNING (above warning, below critical)
      2 = CRITICAL (at or above critical threshold)
      3 = UNKNOWN (error reading disk state)

    Also detects the gap between EBS block device size and partition size — a common sign
    that extend-partition.ps1 has not been run after an EBS resize.

.PARAMETER DriveLetter
    Drive letter to inspect. Single letter, no colon. Defaults to C.

.PARAMETER WarningThresholdPct
    Utilization percentage above which WARNING is raised. Defaults to 80.

.PARAMETER CriticalThresholdPct
    Utilization percentage above which CRITICAL is raised. Defaults to 90.

.EXAMPLE
    .\validate-disk.ps1 -DriveLetter C -WarningThresholdPct 80 -CriticalThresholdPct 90
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[C-Zc-z]$')]
    [string]$DriveLetter = "C",

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 99)]
    [int]$WarningThresholdPct = 80,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 99)]
    [int]$CriticalThresholdPct = 90
)

if ($WarningThresholdPct -ge $CriticalThresholdPct) {
    Write-Error "WarningThresholdPct ($WarningThresholdPct) must be less than CriticalThresholdPct ($CriticalThresholdPct)"
    exit 3
}

$drive = $DriveLetter.ToUpper()

Write-Output "=== Disk Validation Report ==="
Write-Output "Timestamp : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output "Host      : $($env:COMPUTERNAME)"
Write-Output "Drive     : $($drive):"
Write-Output ""

try {
    $psDrive   = Get-PSDrive -Name $drive -ErrorAction Stop
    $total     = $psDrive.Used + $psDrive.Free
    $totalGB   = [math]::Round($total / 1GB, 1)
    $usedGB    = [math]::Round($psDrive.Used / 1GB, 1)
    $freeGB    = [math]::Round($psDrive.Free / 1GB, 1)
    $pctUsed   = [math]::Round(($psDrive.Used / $total) * 100, 1)
    $pctFree   = [math]::Round(($psDrive.Free / $total) * 100, 1)

    # Detect unextended partition (EBS was resized but partition wasn't extended)
    $partition    = Get-Partition -DriveLetter $drive -ErrorAction SilentlyContinue
    $supportedMax = Get-PartitionSupportedSize -DriveLetter $drive -ErrorAction SilentlyContinue
    $partSizeGB   = [math]::Round($partition.Size / 1GB, 1)
    $ebsMaxGB     = [math]::Round($supportedMax.SizeMax / 1GB, 1)
    $unclaimedGB  = [math]::Round(($supportedMax.SizeMax - $partition.Size) / 1GB, 1)

    Write-Output "Partition size  : $partSizeGB GB"
    Write-Output "EBS block size  : $ebsMaxGB GB"
    Write-Output "Total (usable)  : $totalGB GB"
    Write-Output "Used            : $usedGB GB ($pctUsed%)"
    Write-Output "Free            : $freeGB GB ($pctFree%)"
    Write-Output ""

    # Flag unextended partition — this is the silent problem the assessment specifically calls out
    if ($unclaimedGB -gt 1) {
        Write-Warning "NOTICE: $unclaimedGB GB of EBS space is not yet claimed by the partition."
        Write-Warning "Run extend-partition.ps1 to extend the $($drive): partition to use this space."
        Write-Warning "Until extended, this space is invisible to Windows and SQL Server."
        Write-Output ""
    }

    if ($pctUsed -ge $CriticalThresholdPct) {
        Write-Output "STATUS: CRITICAL — $($drive): is $pctUsed% utilized (threshold: $CriticalThresholdPct%)"
        exit 2
    } elseif ($pctUsed -ge $WarningThresholdPct) {
        Write-Output "STATUS: WARNING — $($drive): is $pctUsed% utilized (threshold: $WarningThresholdPct%)"
        exit 1
    } else {
        Write-Output "STATUS: OK — $($drive): is $pctUsed% utilized"
        exit 0
    }

} catch {
    Write-Output "STATUS: UNKNOWN — Error reading drive $($drive): $_"
    exit 3
}
