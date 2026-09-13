# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# The ephemeral half of the deployment: one spot instance and the launch
# template describing it.
#
# Lifecycle model. The spot request is one-time, so an interruption terminates
# the instance and leaves the Terraform state stale. The next `terraform plan`
# sees the instance is gone and the next apply recreates it -- which makes
# "resume after interruption" a single command rather than a bespoke script.
#
# The same mechanism handles normal completion: the bootstrap script syncs to
# S3 and powers the machine off, and instance_initiated_shutdown_behavior turns
# that power-off into a termination. Nothing keeps billing after the run ends.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_region" "current" {}

resource "aws_launch_template" "node" {
  name        = "${var.name_prefix}-node"
  description = "GW230529 Einstein Toolkit spot compute node"

  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type

  vpc_security_group_ids = [var.security_group_id]

  iam_instance_profile {
    name = var.instance_profile_name
  }

  instance_market_options {
    market_type = "spot"

    spot_options {
      # One-time requests always terminate on interruption; stating the
      # interruption behaviour explicitly is rejected by the API.
      spot_instance_type = "one-time"
      max_price          = var.spot_max_price
    }
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size_gb
      throughput            = var.root_volume_throughput
      iops                  = var.root_volume_iops
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"

    # The simulation runs inside a container, and a container reaching the
    # metadata service crosses one extra network hop. A limit of 1 would make
    # the spot interruption notice invisible to anything but the host.
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = false
  }

  instance_initiated_shutdown_behavior = "terminate"

  # gzip, not plain base64. EC2 caps user data at 16 KB and this script is
  # 17.5 KB rendered -- most of it the comments that record why the sidecar
  # behaves the way it does, which is exactly what should not be deleted to
  # save bytes. cloud-init decompresses gzipped user data before running it,
  # so the node sees the same script. 8.8 KB encoded leaves 47% headroom.
  user_data = base64gzip(templatefile(var.user_data_template, {
    aws_region            = data.aws_region.current.region
    run_mode              = var.run_config.run_mode
    ecr_repository_url    = var.run_config.ecr_repository_url
    image_tag             = var.run_config.image_tag
    data_bucket           = var.run_config.data_bucket
    inputs_prefix         = var.run_config.inputs_prefix
    run_name              = var.run_config.run_name
    parfile               = var.run_config.parfile
    mpi_procs             = var.run_config.mpi_procs
    omp_threads           = var.run_config.omp_threads
    rehearsal_payload_gb  = var.run_config.rehearsal_payload_gb
    rehearsal_generations = var.run_config.rehearsal_generations

    checkpoint_generations_kept = var.run_config.checkpoint_generations_kept

    sync_interval_minutes = var.run_config.sync_interval_minutes
    auto_shutdown         = var.run_config.auto_shutdown
  }))

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.name_prefix}-node"
    }
  }

  tag_specifications {
    resource_type = "volume"

    tags = {
      Name = "${var.name_prefix}-node-root"
    }
  }

  update_default_version = true
}

resource "aws_instance" "node" {
  count = var.enabled ? 1 : 0

  subnet_id = var.subnet_id

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  tags = {
    Name = "${var.name_prefix}-node"
  }
}

# Spot interruption warnings arrive about two minutes before the instance is
# reclaimed. The node reacts to them through the metadata service; this rule
# only exists so the operator finds out too.
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  count = var.ops_sns_topic_arn == null ? 0 : 1

  name        = "${var.name_prefix}-spot-interruption"
  description = "Notify on EC2 spot instance interruption warnings"

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "spot_interruption_sns" {
  count = var.ops_sns_topic_arn == null ? 0 : 1

  rule      = aws_cloudwatch_event_rule.spot_interruption[0].name
  target_id = "sns"
  arn       = var.ops_sns_topic_arn
}
