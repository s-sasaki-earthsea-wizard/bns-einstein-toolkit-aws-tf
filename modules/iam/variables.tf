# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

variable "name_prefix" {
  description = "Prefix applied to every resource name."
  type        = string
}

variable "data_bucket_arn" {
  description = "ARN of the simulation data bucket the node may read and write."
  type        = string
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repository the node may pull from."
  type        = string
}
