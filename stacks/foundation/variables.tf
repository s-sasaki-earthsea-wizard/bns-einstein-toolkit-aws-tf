# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

variable "aws_region" {
  description = <<-EOT
    Region for the VPC, the data bucket and the registry.

    Fixed for the life of the project: moving it means re-pushing a 5-8 GB
    image and re-uploading every object. Run `make region-scout` before the
    first apply and pick on the spot placement scores.
  EOT
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to every resource name."
  type        = string
  default     = "gw230529"
}

variable "default_tags" {
  description = "Tags applied to every resource. Project is also the cost allocation tag."
  type        = map(string)

  default = {
    Project   = "gw230529"
    ManagedBy = "terraform"
  }
}

# ------------------------------------------------------------------
# Network
# ------------------------------------------------------------------
variable "vpc_cidr" {
  description = "IPv4 CIDR block of the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = <<-EOT
    Availability zone names to place public subnets in, most preferred first.
    Null takes the first az_count zones by name, which is ordered
    alphabetically and therefore says nothing about spot capacity. Set this
    from `make region-scout`, and include every zone the compute stack might
    be pointed at -- it selects a subnet by zone name.
  EOT
  type        = list(string)
  default     = null
}

variable "az_count" {
  description = "Number of zones to use when availability_zones is null."
  type        = number
  default     = 3
}

# ------------------------------------------------------------------
# Storage
# ------------------------------------------------------------------
variable "data_bucket_name" {
  description = "Globally unique name of the simulation data bucket."
  type        = string
}

variable "checkpoint_expiration_days" {
  description = "Lifetime of objects under checkpoints/."
  type        = number
  default     = 7
}

variable "output_expiration_days" {
  description = "Lifetime of raw diagnostic output under output/."
  type        = number
  default     = 90
}

variable "artifacts_deep_archive_after_days" {
  description = "Age at which artifacts/ objects move to Deep Archive."
  type        = number
  default     = 30
}

# ------------------------------------------------------------------
# Registry
# ------------------------------------------------------------------
variable "ecr_repository_name" {
  description = "ECR repository holding the Einstein Toolkit image."
  type        = string
  default     = "gw230529/einstein-toolkit"
}

variable "ecr_keep_last_images" {
  description = "Number of images retained by the ECR lifecycle policy."
  type        = number
  default     = 3
}

# ------------------------------------------------------------------
# Cost guard
# ------------------------------------------------------------------
variable "alert_email" {
  description = "Address receiving budget, anomaly and spot interruption alerts."
  type        = string
}

variable "budget_limit_usd" {
  description = "Total project spend cap in USD."
  type        = number
  default     = 300
}

variable "budget_thresholds_usd" {
  description = "Absolute USD alert thresholds, ascending."
  type        = list(number)
  default     = [50, 100, 150, 200, 250, 300]
}

variable "budget_period_start" {
  description = "Start of the budget period, formatted YYYY-MM-DD_HH:MM. AWS ignores this for an ANNUALLY budget and measures the calendar year."
  type        = string
}

variable "preexisting_spend_usd" {
  description = "Account spend already booked this calendar year before the project began, in USD. Shifts the cap and every threshold so both read as project spend."
  type        = number
  default     = 0
}

variable "cost_allocation_tag" {
  description = "Optional cost allocation tag filter. Leave null until the tag is activated in the Billing console."
  type = object({
    key   = string
    value = string
  })
  default = null
}

# ------------------------------------------------------------------
# Observer role
# ------------------------------------------------------------------
variable "observer_user_name" {
  description = <<-EOT
    IAM user permitted to assume the read-only observer role.

    The same user that assumes the operator role. Naming it directly in a
    trust policy is what lets the assumption work in this account without an
    identity-based sts:AssumeRole grant -- a same-account trust policy that
    names the principal is sufficient on its own.
  EOT
  type        = string
  default     = "gw230529"
}

variable "state_bucket_name" {
  description = <<-EOT
    Terraform state bucket. Used for one thing only: scoping the observer
    role's read access to it.

    Null falls back to the "<name_prefix>-tfstate-*" pattern the bootstrap
    stack creates it under. The real name lives in backend.hcl, which
    Terraform does not expose to the configuration, so pinning it exactly
    means repeating it here.
  EOT
  type        = string
  default     = null
}
