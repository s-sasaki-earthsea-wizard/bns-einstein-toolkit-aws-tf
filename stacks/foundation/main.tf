# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Foundation stack: everything that outlives an individual simulation run.
#
# Idle cost is close to zero -- a VPC, subnets, an internet gateway, a gateway
# endpoint, security groups and IAM roles are all free, so this stack can sit
# between runs without burning budget. Only S3 storage and the ECR image are
# billed, at roughly 1 USD/month for a 5-8 GB image.
#
# Nothing here is created or destroyed per run. That separation is the point:
# `terraform destroy` in stacks/compute can never reach the simulation data.

module "network" {
  source = "../../modules/network"

  name_prefix        = var.name_prefix
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  az_count           = var.az_count
}

module "storage" {
  source = "../../modules/storage"

  bucket_name                       = var.data_bucket_name
  checkpoint_expiration_days        = var.checkpoint_expiration_days
  output_expiration_days            = var.output_expiration_days
  artifacts_deep_archive_after_days = var.artifacts_deep_archive_after_days
}

module "registry" {
  source = "../../modules/registry"

  repository_name  = var.ecr_repository_name
  keep_last_images = var.ecr_keep_last_images
}

module "iam" {
  source = "../../modules/iam"

  name_prefix        = var.name_prefix
  data_bucket_arn    = module.storage.bucket_arn
  ecr_repository_arn = module.registry.repository_arn
}

module "cost_guard" {
  source = "../../modules/cost_guard"

  providers = {
    aws = aws.us_east_1
  }

  name_prefix           = var.name_prefix
  alert_email           = var.alert_email
  budget_limit_usd      = var.budget_limit_usd
  budget_thresholds_usd = var.budget_thresholds_usd
  budget_period_start   = var.budget_period_start
  preexisting_spend_usd = var.preexisting_spend_usd
  cost_allocation_tag   = var.cost_allocation_tag
}

# Operational alerts. Separate from the cost topic because EventBridge can
# only target an SNS topic in its own region, and the cost topic is pinned to
# us-east-1 by the Budgets API.
resource "aws_sns_topic" "ops_alerts" {
  name = "${var.name_prefix}-ops-alerts"
}

resource "aws_sns_topic_subscription" "ops_alerts_email" {
  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "ops_alerts" {
  statement {
    sid       = "AllowEventBridgePublish"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.ops_alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "ops_alerts" {
  arn    = aws_sns_topic.ops_alerts.arn
  policy = data.aws_iam_policy_document.ops_alerts.json
}
