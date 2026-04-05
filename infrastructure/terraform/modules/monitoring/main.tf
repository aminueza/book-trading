# Monitoring module — CloudWatch log groups, SNS topics for alerts,
# and basic alerting infrastructure.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

# --- KMS key for monitoring resources ---
# Single key for log groups and SNS topics in this module.
resource "aws_kms_key" "monitoring" {
  description             = "Encryption key for ${var.environment} monitoring (logs + SNS)"
  deletion_window_in_days = 14
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountRoot"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowSNS"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.environment}-monitoring-kms"
  })
}

data "aws_caller_identity" "current" {}

resource "aws_kms_alias" "monitoring" {
  name          = "alias/${var.environment}-monitoring"
  target_key_id = aws_kms_key.monitoring.key_id
}

# --- Log Groups ---
resource "aws_cloudwatch_log_group" "application" {
  name              = "/trading/${var.environment}/application"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.monitoring.arn

  tags = merge(var.tags, {
    Name = "${var.environment}-application-logs"
  })
}

resource "aws_cloudwatch_log_group" "eks_audit" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.monitoring.arn

  tags = merge(var.tags, {
    Name = "${var.environment}-eks-audit-logs"
  })
}

# --- SNS Topics ---
# Critical: routes to PagerDuty for immediate response.
resource "aws_sns_topic" "critical_alerts" {
  name              = "${var.environment}-critical-alerts"
  kms_master_key_id = aws_kms_key.monitoring.id
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "pagerduty" {
  count     = var.pagerduty_endpoint != "" ? 1 : 0
  topic_arn = aws_sns_topic.critical_alerts.arn
  protocol  = "https"
  endpoint  = var.pagerduty_endpoint
}

# Warning: routes to Slack for awareness, no pager.
resource "aws_sns_topic" "warning_alerts" {
  name              = "${var.environment}-warning-alerts"
  kms_master_key_id = aws_kms_key.monitoring.id
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "slack" {
  count     = var.slack_webhook_url != "" ? 1 : 0
  topic_arn = aws_sns_topic.warning_alerts.arn
  protocol  = "https"
  endpoint  = var.slack_webhook_url
}

# --- CloudWatch Alarms ---
# These are infrastructure-level alarms. Application-level alerting
# is handled by Prometheus + Alertmanager inside the cluster.

resource "aws_cloudwatch_metric_alarm" "high_5xx_rate" {
  alarm_name          = "${var.environment}-high-5xx-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "5XXError"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "High 5XX error rate detected"
  alarm_actions       = [aws_sns_topic.critical_alerts.arn]
  ok_actions          = [aws_sns_topic.critical_alerts.arn]

  tags = var.tags
}
