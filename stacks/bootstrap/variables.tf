# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

variable "aws_region" {
  description = "Region holding the state bucket. Use the same region as the foundation stack."
  type        = string
}

variable "state_bucket_name" {
  description = <<-EOT
    Globally unique name for the Terraform state bucket. Set it in
    terraform.tfvars, which is gitignored, so it stays out of the public
    repository.
  EOT
  type        = string
}

variable "default_tags" {
  description = "Tags applied to every resource."
  type        = map(string)

  default = {
    Project   = "gw230529"
    ManagedBy = "terraform"
  }
}

variable "operator_user_name" {
  description = <<-EOT
    IAM user a human authenticates as before assuming the operator role.

    After policies/terraform-bootstrap-user.json is applied to it, this user
    can do exactly two things: assume the operator role while presenting MFA,
    and rotate its own access key. Nothing else. That is what makes a leaked
    key a nuisance rather than an incident.
  EOT
  type        = string
  default     = "gw230529"
}

variable "operator_role_name" {
  description = <<-EOT
    Name of the role that carries policies/terraform-operator.json.

    It has to match the `gw230529-*` prefix that policy scopes IAM to, or the
    role will not be able to manage the project's own roles and instance
    profiles.
  EOT
  type        = string
  default     = "gw230529-terraform-operator"
}

variable "operator_session_seconds" {
  description = <<-EOT
    How long an assumed operator session lasts, in seconds. AWS permits 3600
    to 43200.

    Eight hours is a working day: one MFA prompt in the morning, and the CLI
    caches the session under ~/.aws/cli/cache until it expires. Shorten it if
    the machine is shared; there is no reason to lengthen it, because a long
    run does not depend on the operator session at all -- the node carries its
    own instance profile.
  EOT
  type        = number
  default     = 28800

  validation {
    condition     = var.operator_session_seconds >= 3600 && var.operator_session_seconds <= 43200
    error_message = "operator_session_seconds must be between 3600 and 43200."
  }
}
