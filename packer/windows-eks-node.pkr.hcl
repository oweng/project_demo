packer {
  required_version = ">= 1.10.0"

  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.3"
    }
  }
}

# ─── Variables ────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to build the AMI in"
  type        = string
  default     = "us-east-1"
}

variable "eks_version" {
  description = "EKS Kubernetes version — must match the cluster version in Terraform"
  type        = string
  default     = "1.31"
}

variable "ecr_registry" {
  description = "ECR registry hostname (e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com)"
  type        = string
}

variable "image_tag" {
  description = "Tag of the windows-dotnet48 ECR image to pre-cache (git SHA from CI)"
  type        = string
}

variable "subnet_id" {
  description = "Private subnet ID for the temporary Packer build instance. Connectivity is via SSM — no public IP required."
  type        = string
}

variable "instance_type" {
  description = "Instance type for the Packer build instance. m6i.xlarge provides enough RAM for concurrent image pulls."
  type        = string
  default     = "m6i.xlarge"
}

variable "iam_instance_profile" {
  description = "IAM instance profile name for the Packer build instance. Must include AmazonSSMManagedInstanceCore and ECR pull permissions."
  type        = string
}

# ─── Data Sources ─────────────────────────────────────────────────────────────
# Resolve the latest AWS EKS Windows Optimized AMI for the configured k8s version.
# Using SSM Parameter Store means we always build on the latest patched base —
# important for HIPAA environments where base AMI currency is an audit requirement.

data "amazon-parameterstore" "eks_windows_ami" {
  name   = "/aws/service/eks/optimized-ami/${var.eks_version}/windows-core-2022/amazon-eks-node-windows/recommended/image_id"
  region = var.aws_region
}

# ─── Locals ───────────────────────────────────────────────────────────────────

locals {
  timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())
  ami_name  = "custom-windows-eks-${var.eks_version}-${local.timestamp}"
}

# ─── Source ───────────────────────────────────────────────────────────────────

source "amazon-ebs" "windows_eks_node" {
  ami_name        = local.ami_name
  ami_description = "Custom Windows Server 2022 Core EKS node (k8s ${var.eks_version}) with pre-cached container images. Built by Packer on ${local.timestamp}."
  instance_type   = var.instance_type
  region          = var.aws_region
  source_ami      = data.amazon-parameterstore.eks_windows_ami.value

  subnet_id                   = var.subnet_id
  iam_instance_profile        = var.iam_instance_profile
  associate_public_ip_address = false

  # Connect via SSH tunneled through SSM Session Manager. No inbound ports are
  # opened on the build instance — all traffic flows through the SSM control plane.
  # Requires the SSM Session Manager Plugin on the machine running Packer (the runner).
  communicator    = "ssh"
  ssh_username    = "Administrator"
  ssh_interface   = "session_manager"
  ssh_timeout     = "15m"

  # Enable OpenSSH before Packer connects. Windows Server 2022 ships OpenSSH as
  # an installable capability — this user data installs it and sets PowerShell as
  # the default shell so provisioner scripts run in the expected environment.
  user_data = <<-EOF
    <powershell>
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
    Start-Service sshd
    Set-Service -Name sshd -StartupType Automatic
    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" `
      -Name DefaultShell `
      -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
      -PropertyType String -Force
    </powershell>
    EOF

  # The build instance needs extra headroom for concurrent image pulls.
  # The node group's launch template controls the actual node disk size at runtime.
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 150
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  # The AMI root volume — smaller than the build volume since the image layers
  # are stored efficiently in containerd's content store (not as loose files).
  # Node group launch template overrides this to 100 GB at runtime.
  ami_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Name      = local.ami_name
    EKSVersion = var.eks_version
    ManagedBy = "packer"
    BaseAMI   = data.amazon-parameterstore.eks_windows_ami.value
    OS        = "Windows Server 2022 Core"
    DataClass = "PHI"
  }

  run_tags = {
    Name      = "packer-build-windows-eks-${var.eks_version}"
    ManagedBy = "packer"
    Temporary = "true"
  }
}

# ─── Build ────────────────────────────────────────────────────────────────────

build {
  name    = "windows-eks-node"
  sources = ["source.amazon-ebs.windows_eks_node"]

  # Pre-cache container images into containerd.
  # Environment variables pass ECR coordinates to the script.
  provisioner "powershell" {
    environment_vars = [
      "AWS_DEFAULT_REGION=${var.aws_region}",
      "ECR_REGISTRY=${var.ecr_registry}",
      "IMAGE_TAG=${var.image_tag}",
    ]
    script = "${path.root}/scripts/configure-node.ps1"

    # Allow up to 30 minutes — pulling ~10 GB of Windows layers takes time
    # even with good network throughput inside AWS.
    timeout = "30m"
  }

  # Write the built AMI ID to manifest.json so the CI step can read it
  # and store it in SSM Parameter Store for Terraform to consume.
  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
    custom_data = {
      eks_version = var.eks_version
      image_tag   = var.image_tag
      built_at    = local.timestamp
    }
  }
}
