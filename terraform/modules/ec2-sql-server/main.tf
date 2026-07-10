locals {
  name_prefix = "${var.environment}-${var.host_name}"

  drive_letter_bare = trimsuffix(upper(var.drive_letter), ":")

  common_tags = merge(
    {
      Name        = local.name_prefix
      Environment = var.environment
      ManagedBy   = "terraform"
      DataClass   = "PHI"
      SQLServer   = "true"
    },
    var.tags
  )
}

# ─── IAM ─────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "this" {
  name = "${local.name_prefix}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Required by the SSM Automation document to call ec2:ModifyVolume on behalf of the instance.
resource "aws_iam_role_policy" "ebs_modify" {
  name = "ebs-volume-modify"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:ModifyVolume",
        "ec2:DescribeVolumesModifications",
        "ec2:DescribeVolumes",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${local.name_prefix}-instance-profile"
  role = aws_iam_role.this.name

  tags = local.common_tags
}

# ─── Security Group ───────────────────────────────────────────────────────────

resource "aws_security_group" "this" {
  name        = "${local.name_prefix}-sg"
  description = "SQL Server host: RDP from VPN only, SQL from app tier"
  vpc_id      = var.vpc_id

  ingress {
    description = "RDP restricted to on-premises VPN range"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.vpn_cidr]
  }

  dynamic "ingress" {
    for_each = length(var.app_tier_cidrs) > 0 ? [1] : []
    content {
      description = "SQL Server port 1433 from application tier"
      from_port   = 1433
      to_port     = 1433
      protocol    = "tcp"
      cidr_blocks = var.app_tier_cidrs
    }
  }

  egress {
    description = "All outbound required for SSM, CloudWatch, Windows Update"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# ─── EC2 Instance ─────────────────────────────────────────────────────────────
# Import existing instance: terraform import module.<name>.aws_instance.this <instance-id>
# Then run terraform plan to confirm only the volume size change is pending.

resource "aws_instance" "this" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  key_name               = var.key_name != "" ? var.key_name : null
  iam_instance_profile   = aws_iam_instance_profile.this.name
  vpc_security_group_ids = [aws_security_group.this.id]

  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size_gb
    iops                  = var.root_volume_iops
    throughput            = var.root_volume_throughput
    encrypted             = true # HIPAA: encryption at rest required on PHI-boundary hosts
    delete_on_termination = false

    tags = merge(local.common_tags, {
      Name = "${local.name_prefix}-root"
    })
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 — prevents SSRF-based metadata credential theft
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      ami, # AMI updates handled by SSM Patch Manager, not instance replacement
      user_data
    ]
  }

  tags = merge(local.common_tags, {
    Patching = "ssm-patch-manager"
    OS       = "Windows Server 2022"
  })
}

# ─── CloudWatch Agent: config via SSM Parameter Store ────────────────────────

resource "aws_ssm_parameter" "cloudwatch_agent_config" {
  name        = "/cloudwatch-agent/config/${local.name_prefix}"
  description = "CloudWatch Agent config for ${local.name_prefix}"
  type        = "String"

  value = jsonencode({
    metrics = {
      metrics_collected = {
        LogicalDisk = {
          measurement                 = ["% Free Space"]
          metrics_collection_interval = 60
          resources                   = [var.drive_letter]
        }
        Memory = {
          measurement                 = ["% Committed Bytes In Use"]
          metrics_collection_interval = 60
        }
        Processor = {
          measurement                 = ["% Idle Time"]
          metrics_collection_interval = 60
          resources                   = ["_Total"]
        }
      }
      append_dimensions = {
        InstanceId = "$${aws:InstanceId}"
      }
      aggregation_dimensions = [["InstanceId"]]
    }
  })

  tags = local.common_tags
}

resource "aws_ssm_association" "cloudwatch_agent_config" {
  name = "AmazonCloudWatch-ManageAgent"

  targets {
    key    = "InstanceIds"
    values = [aws_instance.this.id]
  }

  parameters = {
    action                        = "configure"
    mode                          = "ec2"
    optionalConfigurationSource   = "ssm"
    optionalConfigurationLocation = aws_ssm_parameter.cloudwatch_agent_config.name
    optionalRestart               = "yes"
  }
}

# ─── SNS: Alert notifications ─────────────────────────────────────────────────

resource "aws_sns_topic" "disk_alerts" {
  name              = "${local.name_prefix}-disk-alerts"
  kms_master_key_id = "alias/aws/sns"

  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "disk_alerts_email" {
  topic_arn = aws_sns_topic.disk_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ─── CloudWatch Alarms ────────────────────────────────────────────────────────
# WARNING uses 2 eval periods to suppress noise; CRITICAL uses 1 for immediate alert.
# treat_missing_data = "breaching" ensures we alert if the agent stops reporting.

resource "aws_cloudwatch_metric_alarm" "disk_warning" {
  alarm_name          = "${local.name_prefix}-disk-warning"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "LogicalDisk % Free Space"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = var.disk_warning_free_pct
  alarm_description   = "WARNING: ${var.drive_letter} on ${local.name_prefix} above ${100 - var.disk_warning_free_pct}% utilized"

  dimensions = {
    InstanceId = aws_instance.this.id
    objectname = "LogicalDisk"
    instance   = var.drive_letter
  }

  alarm_actions             = [aws_sns_topic.disk_alerts.arn]
  ok_actions                = [aws_sns_topic.disk_alerts.arn]
  insufficient_data_actions = [aws_sns_topic.disk_alerts.arn]
  treat_missing_data        = "breaching"

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "disk_critical" {
  alarm_name          = "${local.name_prefix}-disk-critical"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "LogicalDisk % Free Space"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = var.disk_critical_free_pct
  alarm_description   = "CRITICAL: ${var.drive_letter} on ${local.name_prefix} above ${100 - var.disk_critical_free_pct}% utilized — SQL Server at risk"

  dimensions = {
    InstanceId = aws_instance.this.id
    objectname = "LogicalDisk"
    instance   = var.drive_letter
  }

  alarm_actions             = [aws_sns_topic.disk_alerts.arn]
  ok_actions                = [aws_sns_topic.disk_alerts.arn]
  insufficient_data_actions = [aws_sns_topic.disk_alerts.arn]
  treat_missing_data        = "breaching"

  tags = local.common_tags
}

# ─── SSM Documents ────────────────────────────────────────────────────────────

resource "aws_ssm_document" "extend_partition" {
  name            = "${local.name_prefix}-extend-partition"
  document_type   = "Command"
  document_format = "YAML"

  content = <<-YAML
    schemaVersion: "2.2"
    description: "Extend a Windows partition to use all available space after EBS resize. Idempotent."
    parameters:
      DriveLetter:
        type: String
        description: "Drive letter to extend (letter only, no colon)"
        default: "${local.drive_letter_bare}"
        allowedValues: ["C", "D", "E", "F"]
    mainSteps:
      - action: aws:runPowerShellScript
        name: ExtendPartition
        inputs:
          runCommand:
            - |
              $ErrorActionPreference = "Stop"
              $drive = "{{DriveLetter}}"
              $partition     = Get-Partition -DriveLetter $drive
              $supportedSize = Get-PartitionSupportedSize -DriveLetter $drive
              $currentGB     = [math]::Round($partition.Size / 1GB, 2)
              $maxGB         = [math]::Round($supportedSize.SizeMax / 1GB, 2)

              Write-Output "Drive $${drive}: current=$currentGB GB, EBS max=$maxGB GB"

              if ($supportedSize.SizeMax -le $partition.Size) {
                Write-Output "Partition already at maximum size. No action required."
                exit 0
              }

              Resize-Partition -DriveLetter $drive -Size $supportedSize.SizeMax
              $newGB = [math]::Round((Get-Partition -DriveLetter $drive).Size / 1GB, 2)
              Write-Output "Partition extended to $newGB GB"

              $psDrive = Get-PSDrive -Name $drive
              $pctFree = [math]::Round(($psDrive.Free / ($psDrive.Used + $psDrive.Free)) * 100, 1)
              Write-Output "Free space: $([math]::Round($psDrive.Free/1GB,1)) GB ($pctFree%)"
  YAML

  tags = local.common_tags
}

resource "aws_ssm_document" "ebs_resize_and_extend" {
  name            = "${local.name_prefix}-ebs-resize-and-extend"
  document_type   = "Automation"
  document_format = "YAML"

  content = <<-YAML
    schemaVersion: "0.3"
    description: "Expand an EBS volume and extend the Windows partition in one auditable operation."
    assumeRole: "{{ AutomationAssumeRole }}"
    parameters:
      VolumeId:
        type: String
        description: "EBS Volume ID to expand"
      InstanceId:
        type: String
        description: "EC2 Instance ID"
      TargetSizeGiB:
        type: Integer
        default: 200
      DriveLetter:
        type: String
        default: "${local.drive_letter_bare}"
        allowedValues: ["C", "D", "E", "F"]
      AutomationAssumeRole:
        type: String
        default: "${aws_iam_role.this.arn}"
    mainSteps:
      - name: ModifyEBSVolume
        action: aws:executeAwsApi
        inputs:
          Service: ec2
          Api: ModifyVolume
          VolumeId: "{{ VolumeId }}"
          Size: "{{ TargetSizeGiB }}"
        nextStep: WaitForVolumeModification

      - name: WaitForVolumeModification
        action: aws:waitForAwsResourceProperty
        timeoutSeconds: 1800
        inputs:
          Service: ec2
          Api: DescribeVolumesModifications
          Filters:
            - Name: volume-id
              Values:
                - "{{ VolumeId }}"
          PropertySelector: "$.VolumesModifications[0].ModificationState"
          DesiredValues:
            - optimizing
            - completed
        nextStep: ExtendWindowsPartition

      - name: ExtendWindowsPartition
        action: aws:runCommand
        inputs:
          DocumentName: AWS-RunPowerShellScript
          InstanceIds:
            - "{{ InstanceId }}"
          Parameters:
            commands:
              - |
                $drive         = "{{ DriveLetter }}"
                $supportedSize = Get-PartitionSupportedSize -DriveLetter $drive
                $partition     = Get-Partition -DriveLetter $drive
                if ($supportedSize.SizeMax -le $partition.Size) {
                  Write-Output "Partition already at max size. Skipping."
                } else {
                  Resize-Partition -DriveLetter $drive -Size $supportedSize.SizeMax
                  Write-Output "Extended to $([math]::Round((Get-Partition -DriveLetter $drive).Size/1GB,2)) GB"
                }
        nextStep: ValidateDiskSpace

      - name: ValidateDiskSpace
        action: aws:runCommand
        isEnd: true
        inputs:
          DocumentName: AWS-RunPowerShellScript
          InstanceIds:
            - "{{ InstanceId }}"
          Parameters:
            commands:
              - |
                $drive   = "{{ DriveLetter }}"
                $psDrive = Get-PSDrive -Name $drive
                $total   = $psDrive.Used + $psDrive.Free
                $pctFree = [math]::Round(($psDrive.Free / $total) * 100, 1)
                Write-Output "Drive $${drive}: $([math]::Round($total/1GB,1)) GB total, $pctFree% free"
                if ($pctFree -lt 10) { throw "CRITICAL: $drive is $pctFree% free" }
                elseif ($pctFree -lt 20) { Write-Warning "WARNING: $drive is $pctFree% free" }
                else { Write-Output "STATUS: OK" }
  YAML

  tags = local.common_tags
}
