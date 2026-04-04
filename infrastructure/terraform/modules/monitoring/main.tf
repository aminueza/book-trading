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

# --- Log Groups ---
resource "aws_cloudwatch_log_group" "application" {
  name              = "/trading/${var.environment}/application"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "${var.environment}-application-logs"
  })
}

resource "aws_cloudwatch_log_group" "eks_audit" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "${var.environment}-eks-audit-logs"
  })
}

# --- SNS Topics ---
# Critical: routes to PagerDuty for immediate response.
resource "aws_sns_topic" "critical_alerts" {
  name = "${var.environment}-critical-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "pagerduty" {
  count     = var.pagerduty_endpoint != "" ? 1 : 0
  topic_arn = aws_sns_topic.critical_alerts.arn
  protocol  = "https"
  endpoint  = var.pagerduty_endpoint
}

# Warning: routes to Slack for awareness, no pager.
resource "aws_sns_topic" "warning_alerts" {
  name = "${var.environment}-warning-alerts"
  tags = var.tags
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
