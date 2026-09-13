# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

variable "bucket_name" {
  description = <<-EOT
    Globally unique name of the data bucket. Set it in terraform.tfvars, which
    is gitignored, so the name never lands in a public repository.
  EOT
  type        = string
}

variable "checkpoint_expiration_days" {
  description = <<-EOT
    Lifetime of objects under checkpoints/. Checkpoints are only useful until
    the run that wrote them finishes; keeping a week of them is a cheap safety
    net against a bad restart.
  EOT
  type        = number
  default     = 7
}

variable "output_expiration_days" {
  description = "Lifetime of raw diagnostic output under output/."
  type        = number
  default     = 90
}

variable "artifacts_deep_archive_after_days" {
  description = <<-EOT
    Age at which artifacts/ objects move to DEEP_ARCHIVE. Deep Archive
    bills a 180 day minimum storage duration, so this delay exists to give the
    analysis a chance to reject a bad run before archiving becomes expensive
    to undo.
  EOT
  type        = number
  default     = 30
}

variable "heartbeat_expiration_days" {
  description = "Lifetime of the run heartbeat objects under heartbeat/."
  type        = number
  default     = 30
}

variable "force_destroy" {
  description = <<-EOT
    Allow `terraform destroy` to delete a non-empty bucket. Keep this false;
    the bucket is the system of record for every simulation result.
  EOT
  type        = bool
  default     = false
}
