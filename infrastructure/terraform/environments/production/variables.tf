variable "aws_region" {
  description = "AWS region for production deployment"
  type        = string
  default     = "us-east-1"
}

variable "pagerduty_endpoint" {
  description = "PagerDuty integration endpoint for critical alerts"
  type        = string
  sensitive   = true
}

variable "slack_webhook_url" {
  description = "Slack webhook for non-critical notifications"
  type        = string
  sensitive   = true
}
