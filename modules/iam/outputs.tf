# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

output "instance_profile_name" {
  description = "Instance profile attached to the compute node."
  value       = aws_iam_instance_profile.node.name
}

output "instance_profile_arn" {
  description = "Instance profile ARN."
  value       = aws_iam_instance_profile.node.arn
}

output "role_arn" {
  description = "Role ARN assumed by the compute node."
  value       = aws_iam_role.node.arn
}
