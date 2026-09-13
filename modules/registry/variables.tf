# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

variable "repository_name" {
  description = "ECR repository name holding the Einstein Toolkit image."
  type        = string
  default     = "gw230529/einstein-toolkit"
}

variable "keep_last_images" {
  description = <<-EOT
    Number of images retained by the lifecycle policy. The image measures
    4.06 GB in the registry (measured 2026-08-20; 17 GB unpacked), so a full
    extra generation costs about 0.41 USD/month. Generations that share layers
    cost only their delta, because ECR bills each unique layer once.
  EOT
  type        = number
  default     = 3
}

variable "force_delete" {
  description = "Allow `terraform destroy` to delete a repository that still holds images."
  type        = bool
  default     = false
}
