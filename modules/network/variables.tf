# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

variable "name_prefix" {
  description = "Prefix applied to every resource name."
  type        = string
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block of the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = <<-EOT
    Availability zone names to place public subnets in, most preferred first,
    for example ["us-west-2d", "us-west-2a", "us-west-2c"]. The first entry is
    what the compute stack lands in when it does not name a zone itself.

    Zone names are shuffled per AWS account, so this is a measurement rather
    than a constant -- `make region-scout` prints this account's name-to-id
    mapping together with the current spot placement scores. Listing a zone
    the compute stack may want is not optional: it selects its subnet by zone
    name, and a zone with no subnet is a plan-time error.

    Null falls back to the first az_count zones by name. See the note in
    main.tf for why that fallback is a default rather than a choice.
  EOT
  type        = list(string)
  default     = null

  validation {
    condition     = try(length(var.availability_zones), 1) > 0
    error_message = "availability_zones must be null or a non-empty list."
  }
}

variable "az_count" {
  description = <<-EOT
    Number of availability zones to place a public subnet in, used only when
    availability_zones is null. Spot capacity for very large instance types is
    uneven across AZs, so more subnets means more pools to fall back on.
    Subnets themselves are free.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 6
    error_message = "az_count must be between 1 and 6."
  }
}
