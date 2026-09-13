# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

output "launch_template_id" {
  description = "Launch template id. Usable directly with `aws ec2 run-instances --launch-template`."
  value       = aws_launch_template.node.id
}

output "instance_id" {
  description = "Instance id while a run is active, null otherwise."
  value       = one(aws_instance.node[*].id)
}

output "instance_private_ip" {
  description = "Private IPv4 address of the running instance, null otherwise."
  value       = one(aws_instance.node[*].private_ip)
}

output "ssm_session_command" {
  description = "Ready-to-paste command that opens a shell on the node."
  value = one(aws_instance.node[*].id) == null ? null : format(
    "aws ssm start-session --region %s --target %s",
    data.aws_region.current.region,
    one(aws_instance.node[*].id),
  )
}
