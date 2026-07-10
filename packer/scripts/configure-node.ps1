# Runs as a Packer PowerShell provisioner on the temporary build EC2 instance.
# Pre-pulls Windows container images into containerd's image store so that
# nodes launched from the resulting AMI can start pods without a cold image pull.
#
# Without this, a cold Windows EKS node takes 10-15 minutes to pull
# mcr.microsoft.com/dotnet/framework/aspnet:4.8 (~8GB) before the first pod starts.
# With pre-cached images the same pod starts in under 60 seconds.

$ErrorActionPreference = "Stop"

$Region      = $env:AWS_DEFAULT_REGION
$EcrRegistry = $env:ECR_REGISTRY
$ImageTag    = $env:IMAGE_TAG

# containerd ships with the EKS Windows Optimized AMI
$ctr = "C:\Program Files\containerd\ctr.exe"

if (-not (Test-Path $ctr)) {
    Write-Error "containerd not found at $ctr — is this an EKS Windows Optimized AMI?"
    exit 1
}

Write-Output "=== Pre-caching container images into containerd ==="
Write-Output "ECR Registry : $EcrRegistry"
Write-Output "Image tag    : $ImageTag"
Write-Output "Region       : $Region"
Write-Output ""

# ─── ECR login ───────────────────────────────────────────────────────────────
Write-Output "Authenticating to ECR..."
$ecrPassword = aws ecr get-login-password --region $Region
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to get ECR credentials"
    exit 1
}

# ─── Images to pre-cache ─────────────────────────────────────────────────────
# Pull layers in dependency order so shared layers are cached before child images.
# The Microsoft base images account for the bulk of the pull time (~7-8 GB).
$images = @(
    # Microsoft base layers — pulled unauthenticated from MCR
    @{ uri = "mcr.microsoft.com/windows/servercore:ltsc2022"; auth = $null },
    @{ uri = "mcr.microsoft.com/dotnet/framework/runtime:4.8-windowsservercore-ltsc2022"; auth = $null },
    @{ uri = "mcr.microsoft.com/dotnet/framework/aspnet:4.8-windowsservercore-ltsc2022"; auth = $null },

    # Company base image from ECR — requires ECR credentials
    @{ uri = "$EcrRegistry/windows-dotnet48:$ImageTag"; auth = "AWS:$ecrPassword" },
    @{ uri = "$EcrRegistry/windows-dotnet48:latest"; auth = "AWS:$ecrPassword" }
)

foreach ($image in $images) {
    Write-Output "Pulling $($image.uri)..."

    $pullArgs = @("-n", "k8s.io", "images", "pull")

    if ($image.auth) {
        $pullArgs += @("--user", $image.auth)
    }

    $pullArgs += $image.uri

    & $ctr @pullArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to pull $($image.uri)"
        exit 1
    }

    Write-Output "  OK"
}

# ─── Verify ───────────────────────────────────────────────────────────────────
Write-Output ""
Write-Output "=== Cached images in containerd (k8s.io namespace) ==="
& $ctr -n k8s.io images list

Write-Output ""
Write-Output "=== Disk usage after pre-cache ==="
Get-PSDrive -Name C | Select-Object `
    Name, `
    @{n="UsedGB"; e={[math]::Round($_.Used/1GB, 1)}}, `
    @{n="FreeGB"; e={[math]::Round($_.Free/1GB, 1)}}, `
    @{n="TotalGB"; e={[math]::Round(($_.Used + $_.Free)/1GB, 1)}}

Write-Output ""
Write-Output "Node configuration complete."
