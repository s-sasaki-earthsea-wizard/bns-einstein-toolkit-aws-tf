# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

output "vpc_id" {
  description = "VPC id."
  value       = aws_vpc.this.id
}

# Iterating the resource map directly would sort by zone name, so the
# preference order expressed in availability_zones would be lost and element
# zero -- what the compute stack falls back to when it names no zone -- would
# be alphabetical rather than preferred. Index by local.azs instead.
output "public_subnet_ids" {
  description = "Public subnet ids, most preferred availability zone first."
  value       = [for az in local.azs : aws_subnet.public[az].id]
}

output "public_subnet_ids_by_az" {
  description = "Public subnet ids keyed by availability zone name."
  value       = { for az, s in aws_subnet.public : az => s.id }
}

output "security_group_id" {
  description = "Security group for the compute node."
  value       = aws_security_group.node.id
}
