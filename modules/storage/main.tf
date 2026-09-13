# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Single data bucket, partitioned by prefix, with one lifecycle rule per
# prefix. One bucket rather than four because the prefixes differ only in
# retention -- separate buckets would multiply the policy surface without
# buying any isolation.
#
#   inputs/       parfile and FUKA initial data, ~1.6 MB, deliberately with no
#                 lifecycle rule. Upstream gallery artefacts that cannot be
#                 redistributed, so they are neither committed nor baked into
#                 the container image; the node fetches them from here at boot.
#   checkpoints/<run_name>/   restart files in two alternating slots plus a
#                             CURRENT marker
#   output/<run_name>/        diagnostic HDF5 / ASCII produced by the run
#   logs/<run_name>/          the node's bootstrap log
#   artifacts/                final tar.gz deliverables, destined for
#                             Deep Archive
#   heartbeat/<run_name>/     small status objects written by the node
#
# The category comes first and the run name second. That ordering is load
# bearing: an S3 lifecycle filter matches a prefix from the start of the key
# and can match nothing else -- no suffix, no tag on a prefix. When the run
# name came first, every rule below matched no key at all and 349 GB of dead
# checkpoints accumulated with no expiry (issue #17, found 2026-08-26).
# templates/user_data.sh.tftpl writes this layout; change the two together.
#
# Versioning is deliberately OFF. Phase 2 measured a 25 GB checkpoint at dx=28,
# extrapolating to ~78 GB at production resolution; keeping noncurrent versions
# of that would run to terabytes within a day.

resource "aws_s3_bucket" "data" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy

  tags = {
    Name = var.bucket_name
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket = aws_s3_bucket.data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_ownership_controls" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  # A 15 GB checkpoint uploads as a multipart transfer. If the instance is
  # interrupted mid-upload the parts are billed until they are aborted.
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }

  rule {
    id     = "expire-checkpoints"
    status = "Enabled"

    filter {
      prefix = "checkpoints/"
    }

    expiration {
      days = var.checkpoint_expiration_days
    }
  }

  rule {
    id     = "expire-output"
    status = "Enabled"

    filter {
      prefix = "output/"
    }

    expiration {
      days = var.output_expiration_days
    }
  }

  # Bootstrap logs are small (hundreds of KB) but they are the primary
  # evidence for anything measured off a run -- the 2026-08-21 throughput
  # figure was derived from one. They expire on the same clock as the output
  # they document.
  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {
      prefix = "logs/"
    }

    expiration {
      days = var.output_expiration_days
    }
  }

  rule {
    id     = "archive-artifacts"
    status = "Enabled"

    filter {
      prefix = "artifacts/"
    }

    transition {
      days          = var.artifacts_deep_archive_after_days
      storage_class = "DEEP_ARCHIVE"
    }
  }

  rule {
    id     = "expire-heartbeat"
    status = "Enabled"

    filter {
      prefix = "heartbeat/"
    }

    expiration {
      days = var.heartbeat_expiration_days
    }
  }
}
