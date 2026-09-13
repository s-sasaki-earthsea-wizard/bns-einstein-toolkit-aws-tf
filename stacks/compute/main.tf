# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Compute stack: the spot instance and its launch template, created for a run
# and destroyed afterwards.
#
# Kept apart from stacks/foundation so this state can be applied and destroyed
# freely without the simulation bucket or the container image ever being in
# scope. The only coupling is one read of the foundation stack's outputs.

data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket = var.foundation_state.bucket
    key    = var.foundation_state.key
    region = var.foundation_state.region
  }
}

locals {
  foundation = data.terraform_remote_state.foundation.outputs

  subnet_id = (
    var.availability_zone == null
    ? local.foundation.public_subnet_ids[0]
    : local.foundation.public_subnet_ids_by_az[var.availability_zone]
  )
}

module "spot_node" {
  source = "../../modules/spot_node"

  name_prefix = local.foundation.name_prefix
  enabled     = var.run_enabled

  instance_type         = var.instance_type
  subnet_id             = local.subnet_id
  security_group_id     = local.foundation.security_group_id
  instance_profile_name = local.foundation.instance_profile_name
  spot_max_price        = var.spot_max_price

  root_volume_size_gb    = var.root_volume_size_gb
  root_volume_throughput = var.root_volume_throughput
  root_volume_iops       = var.root_volume_iops

  ops_sns_topic_arn = local.foundation.ops_sns_topic_arn

  user_data_template = "${path.module}/../../templates/user_data.sh.tftpl"

  run_config = {
    run_mode              = var.run_mode
    ecr_repository_url    = local.foundation.ecr_repository_url
    image_tag             = var.image_tag
    data_bucket           = local.foundation.data_bucket
    inputs_prefix         = var.inputs_prefix
    run_name              = var.run_name
    parfile               = var.parfile
    mpi_procs             = var.mpi_procs
    omp_threads           = var.omp_threads
    rehearsal_payload_gb  = var.rehearsal_payload_gb
    rehearsal_generations = var.rehearsal_generations

    checkpoint_generations_kept = var.checkpoint_generations_kept

    sync_interval_minutes = var.sync_interval_minutes
    auto_shutdown         = var.auto_shutdown
  }
}
