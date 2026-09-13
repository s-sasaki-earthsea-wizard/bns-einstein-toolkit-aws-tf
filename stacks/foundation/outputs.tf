# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Consumed by stacks/compute through terraform_remote_state.

output "aws_region" {
  description = "Region this stack is deployed in."
  value       = var.aws_region
}

output "name_prefix" {
  description = "Resource name prefix."
  value       = var.name_prefix
}

output "vpc_id" {
  description = "VPC id."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet ids, most preferred availability zone first."
  value       = module.network.public_subnet_ids
}

output "public_subnet_ids_by_az" {
  description = "Public subnet ids keyed by availability zone."
  value       = module.network.public_subnet_ids_by_az
}

output "security_group_id" {
  description = "Security group for the compute node."
  value       = module.network.security_group_id
}

output "instance_profile_name" {
  description = "Instance profile for the compute node."
  value       = module.iam.instance_profile_name
}

output "data_bucket" {
  description = "Simulation data bucket."
  value       = module.storage.bucket_id
}

output "ecr_repository_url" {
  description = "Docker push/pull target for the Einstein Toolkit image."
  value       = module.registry.repository_url
}

output "ops_sns_topic_arn" {
  description = "Regional SNS topic for operational alerts."
  value       = aws_sns_topic.ops_alerts.arn
}

output "cost_sns_topic_arn" {
  description = "us-east-1 SNS topic for budget and anomaly alerts."
  value       = module.cost_guard.sns_topic_arn
}

output "docker_push_commands" {
  description = "Commands that push the locally built image to ECR."
  value       = <<-EOT
    aws ecr get-login-password --region ${var.aws_region} \
      | docker login --username AWS --password-stdin ${module.registry.repository_url}
    docker tag <local-image>:latest ${module.registry.repository_url}:latest
    docker push ${module.registry.repository_url}:latest
  EOT
}

output "observer_role_arn" {
  description = "Read-only role for watching a run. Assumable without MFA."
  value       = aws_iam_role.observer.arn
}

output "observer_profile_snippet" {
  description = <<-EOT
    Ready-to-paste ~/.aws/config for the read-only profile. No mfa_serial, so
    the CLI assumes it and renews it without ever prompting -- which is the
    point. It sources the same static key as the operator profile.
  EOT
  value       = <<-EOT
    [profile ${var.observer_user_name}-observer]
    role_arn       = ${aws_iam_role.observer.arn}
    source_profile = ${var.observer_user_name}-bootstrap
    region         = ${var.aws_region}
  EOT
}
