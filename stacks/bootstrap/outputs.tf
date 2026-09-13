# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

output "state_bucket" {
  description = "State bucket name. Copy it into each stack's backend.hcl."
  value       = aws_s3_bucket.state.id
}

output "backend_hcl" {
  description = "Ready-to-paste partial backend configuration for the other stacks."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.id}"
    key          = "<stack>/terraform.tfstate"
    region       = "${var.aws_region}"
    encrypt      = true
    use_lockfile = true
  EOT
}

output "operator_role_arn" {
  description = "Role a human assumes to run Terraform. Put it in ~/.aws/config."
  value       = aws_iam_role.operator.arn
}

output "aws_config_snippet" {
  description = <<-EOT
    Ready-to-paste ~/.aws/config. The static access key moves to the
    -bootstrap profile and stops being useful on its own; every Makefile
    target keeps working against AWS_PROFILE=<operator user>, now through the
    role.
  EOT
  value       = <<-EOT
    [profile ${var.operator_user_name}-bootstrap]
    region = ${var.aws_region}

    [profile ${var.operator_user_name}]
    role_arn       = ${aws_iam_role.operator.arn}
    source_profile = ${var.operator_user_name}-bootstrap
    mfa_serial     = <your MFA device ARN: aws iam list-mfa-devices>
    region         = ${var.aws_region}
  EOT
}
