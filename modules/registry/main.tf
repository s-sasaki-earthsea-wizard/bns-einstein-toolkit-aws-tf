# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Private registry for the locally built Einstein Toolkit image.
#
# Tags are mutable on purpose: the development loop is "rebuild, push :latest,
# relaunch the node". Production runs should still be pinned to an immutable
# digest -- record it in the run log rather than relying on the tag.

resource "aws_ecr_repository" "this" {
  name                 = var.repository_name
  image_tag_mutability = "MUTABLE"
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      # Safe against the OCI image index that `docker push` produces from the
      # containerd store. That index is what carries the tag; the amd64
      # manifest it points at and the buildkit attestation manifest are both
      # untagged and would otherwise match this rule within a day, leaving a
      # tag whose children have been deleted. ECR does not allow it: "If an
      # image is referenced by a manifest list, it cannot be expired or
      # archived without the manifest list being deleted or archived first."
      # So the children go only when a re-push takes the tag off the old
      # index, which is exactly when they should. Verified against the pushed
      # repository on 2026-08-20.
      {
        rulePriority = 1
        description  = "Expire untagged images after one day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the most recent tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_last_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
