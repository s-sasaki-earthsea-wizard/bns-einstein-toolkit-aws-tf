# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Cost guardrails. This module must be instantiated with a us-east-1 provider:
# AWS Budgets only accepts SNS topics that live in us-east-1, and Cost Explorer
# is a us-east-1 global service.
#
# What this does NOT do: stop a runaway spend in real time. Billing data lags
# by 8-24 hours, so every alert here is after the fact. Real-time containment
# comes from the spot maximum price and the run's self-terminate, both defined
# in modules/spot_node.

resource "aws_sns_topic" "cost_alerts" {
  name = "${var.name_prefix}-cost-alerts"
}

resource "aws_sns_topic_subscription" "cost_alerts_email" {
  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "cost_alerts" {
  statement {
    sid       = "AllowBudgetsAndCostAnomalyPublish"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.cost_alerts.arn]

    principals {
      type = "Service"
      identifiers = [
        "budgets.amazonaws.com",
        "costalerts.amazonaws.com",
      ]
    }
  }
}

resource "aws_sns_topic_policy" "cost_alerts" {
  arn    = aws_sns_topic.cost_alerts.arn
  policy = data.aws_iam_policy_document.cost_alerts.json
}

locals {
  # Thresholds and the cap are written as project spend, then shifted by what
  # the account had already spent this calendar year. Without the shift they
  # measure the account's whole year, because an ANNUALLY budget ignores
  # time_period_start and this one carries no cost filter. See
  # variable preexisting_spend_usd.
  budget_amount = var.budget_limit_usd + var.preexisting_spend_usd
  thresholds    = [for t in var.budget_thresholds_usd : t + var.preexisting_spend_usd]

  # Four thresholds per budget keeps room for the forecast notification that
  # is appended to the final budget, staying under the AWS limit of five.
  threshold_chunks = chunklist(local.thresholds, 4)

  budgets = {
    for idx, chunk in local.threshold_chunks :
    format("%02d", idx + 1) => concat(
      [for t in chunk : { notification_type = "ACTUAL", threshold = t }],
      idx == length(local.threshold_chunks) - 1
      ? [{ notification_type = "FORECASTED", threshold = local.budget_amount }]
      : []
    )
  }
}

resource "aws_budgets_budget" "project" {
  for_each = local.budgets

  name         = "${var.name_prefix}-${each.key}"
  budget_type  = "COST"
  limit_amount = tostring(local.budget_amount)
  limit_unit   = "USD"

  # The cap is a project total spanning several months, not a monthly
  # allowance, so the budget period is annual rather than monthly.
  #
  # It is NOT anchored to the project start date, though it reads as if it
  # were: AWS measures an ANNUALLY budget over the calendar year and ignores
  # time_period_start, while storing it verbatim so no drift appears.
  # preexisting_spend_usd is what compensates.
  time_unit         = "ANNUALLY"
  time_period_start = var.budget_period_start

  dynamic "cost_filter" {
    for_each = var.cost_allocation_tag == null ? [] : [var.cost_allocation_tag]

    content {
      name   = "TagKeyValue"
      values = ["user:${cost_filter.value.key}$${cost_filter.value.value}"]
    }
  }

  dynamic "notification" {
    for_each = each.value

    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value.threshold
      threshold_type            = "ABSOLUTE_VALUE"
      notification_type         = notification.value.notification_type
      subscriber_sns_topic_arns = [aws_sns_topic.cost_alerts.arn]
    }
  }

  depends_on = [aws_sns_topic_policy.cost_alerts]
}

resource "aws_ce_anomaly_monitor" "services" {
  name              = "${var.name_prefix}-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "immediate" {
  name      = "${var.name_prefix}-immediate"
  frequency = "IMMEDIATE"

  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.cost_alerts.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_impact_threshold_usd)]
    }
  }

  depends_on = [aws_sns_topic_policy.cost_alerts]
}
