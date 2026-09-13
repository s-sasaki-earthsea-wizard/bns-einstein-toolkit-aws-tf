# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

output "launch_template_id" {
  description = "Launch template id."
  value       = module.spot_node.launch_template_id
}

output "instance_id" {
  description = "Instance id while a run is active, null otherwise."
  value       = module.spot_node.instance_id
}

output "ssm_session_command" {
  description = "Ready-to-paste command that opens a shell on the node."
  value       = module.spot_node.ssm_session_command
}

# Purpose-built URLs rather than a single run prefix: the S3 layout puts the
# category before the run name (see modules/storage), so one prefix no longer
# covers everything a run writes.

output "run_log_url" {
  description = "S3 URL of the run's Cactus stdout log, the input to make throughput."
  value       = "s3://${local.foundation.data_bucket}/output/${var.run_name}/run/cactus-stdout.log"
}

output "heartbeat_url" {
  description = "S3 URL of the node's latest heartbeat object."
  value       = "s3://${local.foundation.data_bucket}/heartbeat/${var.run_name}/latest.json"
}

output "checkpoint_prefix" {
  description = "S3 prefix holding the run's checkpoint slots and CURRENT marker."
  value       = "s3://${local.foundation.data_bucket}/checkpoints/${var.run_name}/"
}

output "log_prefix" {
  description = "S3 prefix holding the node bootstrap logs for this run."
  value       = "s3://${local.foundation.data_bucket}/logs/${var.run_name}/"
}
