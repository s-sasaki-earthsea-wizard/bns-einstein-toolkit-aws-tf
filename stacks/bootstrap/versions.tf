# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State for this stack stays local. It only describes the bucket that holds
  # everything else's state, so putting it in that bucket would be circular.
  # terraform.tfstate is gitignored; back it up with the rest of the machine.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.default_tags
  }
}
