# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

output "bucket_id" {
  description = "Name of the data bucket."
  value       = aws_s3_bucket.data.id
}

output "bucket_arn" {
  description = "ARN of the data bucket."
  value       = aws_s3_bucket.data.arn
}

output "bucket_regional_domain_name" {
  description = "Regional domain name, useful for s3:// URI construction."
  value       = aws_s3_bucket.data.bucket_regional_domain_name
}
