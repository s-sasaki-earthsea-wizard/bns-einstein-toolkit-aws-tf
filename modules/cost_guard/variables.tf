# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

variable "name_prefix" {
  description = "Prefix applied to every resource name."
  type        = string
}

variable "alert_email" {
  description = <<-EOT
    Address that receives budget and anomaly alerts. AWS sends a confirmation
    mail after the first apply; the subscription stays PendingConfirmation
    until the link in it is clicked.
  EOT
  type        = string
}

variable "budget_limit_usd" {
  description = "Total project spend cap in USD. Used as the budget amount and the forecast threshold."
  type        = number
  default     = 300
}

variable "budget_thresholds_usd" {
  description = <<-EOT
    Absolute USD thresholds that trigger an alert, in ascending order. AWS
    allows at most five notifications per budget, so the list is split across
    as many budgets as needed.
  EOT
  type        = list(number)
  default     = [50, 100, 150, 200, 250, 300]
}

variable "budget_period_start" {
  description = <<-EOT
    Start of the budget period, formatted YYYY-MM-DD_HH:MM.

    Note that AWS ignores this for an ANNUALLY budget and measures the
    calendar year instead. The value is stored and read back unchanged, so
    terraform plan reports no drift and nothing here reveals the override.
    Confirmed 2026-08-27: a budget carrying 2026-08-01_00:00 alerted on
    spend going back to 2026-01-01. See preexisting_spend_usd.
  EOT
  type        = string

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-\\d{2}_\\d{2}:\\d{2}$", var.budget_period_start))
    error_message = "budget_period_start must look like 2026-08-01_00:00."
  }
}

variable "preexisting_spend_usd" {
  description = <<-EOT
    Spend already on this account for the current calendar year before the
    project started, in USD. Added to the budget amount and to every
    threshold, so both keep reading as project spend.

    This exists because two AWS behaviours combine badly. An ANNUALLY budget
    is measured over the calendar year: time_period_start is accepted,
    stored, and then ignored, and Terraform sees no drift because the value
    it wrote is the value read back. And with cost_allocation_tag null there
    is no cost filter, so the budget measures the whole account. Together
    they mean a threshold of 150 fires on everything the account has spent
    since January 1st, including projects that ended before this one began.

    Measured 2026-08-27 with Cost Explorer: 137.32 USD between 2026-01-01 and
    2026-08-18, nearly all of it a previous project's NAT gateway and RDS
    instance, torn down in April. Rounded to 140 to absorb the ~0.08 USD/day
    of unrelated spend that continues on the account.

    Set to 0 on 2027-01-01, when the calendar year rolls over and that spend
    leaves the budget period. Set to 0 as well if a cost filter is ever
    enabled -- see cost_allocation_tag.
  EOT
  type        = number
  default     = 0
}

variable "cost_allocation_tag" {
  description = <<-EOT
    Optional cost allocation tag filter, as { key = "Project", value = "gw230529" }.

    Leave this null. A tag filter only matches once the tag has been activated
    in the Billing console AND enough time has passed for it to appear in the
    cost data -- until then the budget silently matches nothing and no alert
    ever fires. An account-wide budget is the safe default; narrow it later
    only if this account starts carrying unrelated spend.
  EOT
  type = object({
    key   = string
    value = string
  })
  default = null
}

variable "anomaly_impact_threshold_usd" {
  description = "Minimum absolute anomaly impact in USD before a notification is sent."
  type        = number
  default     = 10
}
