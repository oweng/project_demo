# Base image for .NET Framework 4.8 / ASP.NET applications on Windows Server 2022.
# Application teams build their images FROM this rather than directly from Microsoft's
# registry — gives us a single place to add company-wide tooling, security config,
# and observability agents without repeating it in every app Dockerfile.
#
# Built daily by .github/workflows/build-windows-ami.yml and pushed to ECR.
# The Packer EKS node AMI pre-caches this image so cold-start time is under 60s.

FROM mcr.microsoft.com/dotnet/framework/aspnet:4.8-windowsservercore-ltsc2022

SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# ─── Timezone ────────────────────────────────────────────────────────────────
# UTC avoids drift between containers, nodes, and CloudWatch log timestamps.
RUN Set-TimeZone -Id 'UTC'

# ─── IIS baseline ────────────────────────────────────────────────────────────
# Remove the default site — every app container defines its own bindings.
RUN Remove-WebSite -Name 'Default Web Site' -ErrorAction SilentlyContinue

# Disable IIS static compression to avoid temp file growth on C: drive.
# This was a real failure mode on the EC2 hosts; prevent it in containers too.
RUN Set-WebConfigurationProperty `
      -pspath 'MACHINE/WEBROOT/APPHOST' `
      -filter 'system.webServer/httpCompression' `
      -name 'directory' `
      -value 'C:\inetpub\temp\IIS Temporary Compressed Files'; `
    Disable-WebConfigurationProperty `
      -pspath 'MACHINE/WEBROOT/APPHOST' `
      -filter 'system.webServer/httpCompression/staticTypes' `
      -name 'enabled' `
      -ErrorAction SilentlyContinue

# ─── Datadog .NET APM ─────────────────────────────────────────────────────────
# Install at base image level so every app gets distributed tracing without
# each team configuring it individually. Matches the Datadog monitoring stack.
ARG DD_TRACER_VERSION=2.55.0

RUN Invoke-WebRequest `
      -Uri "https://github.com/DataDog/dd-trace-dotnet/releases/download/v$env:DD_TRACER_VERSION/datadog-dotnet-apm-$env:DD_TRACER_VERSION-x64.msi" `
      -OutFile C:\datadog-apm.msi; `
    Start-Process msiexec.exe -Wait -ArgumentList '/i C:\datadog-apm.msi /quiet /norestart'; `
    Remove-Item C:\datadog-apm.msi -Force

# ─── AWS CLI v2 ───────────────────────────────────────────────────────────────
# Required for apps that read config from SSM Parameter Store or Secrets Manager
# at startup (preferred over baking secrets into images or env vars).
RUN Invoke-WebRequest -Uri 'https://awscli.amazonaws.com/AWSCLIV2.msi' -OutFile C:\AWSCLIV2.msi; `
    Start-Process msiexec.exe -Wait -ArgumentList '/i C:\AWSCLIV2.msi /quiet /norestart'; `
    Remove-Item C:\AWSCLIV2.msi -Force

# ─── Health check ─────────────────────────────────────────────────────────────
# Application images should override this with their specific health endpoint.
# This default covers the common case of an IIS app on port 80.
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD ["powershell", "-Command", \
       "try { (Invoke-WebRequest -Uri http://localhost/health -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200 } catch { exit 1 }"]

EXPOSE 80 443
