# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

output "sns_topic_arn" {
  description = "us-east-1 SNS topic receiving budget and anomaly alerts."
  value       = aws_sns_topic.cost_alerts.arn
}

output "budget_names" {
  description = "Names of the created budgets."
  value       = [for b in aws_budgets_budget.project : b.name]
}
