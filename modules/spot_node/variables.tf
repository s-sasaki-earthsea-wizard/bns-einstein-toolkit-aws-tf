# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

variable "name_prefix" {
  description = "Prefix applied to every resource name."
  type        = string
}

variable "enabled" {
  description = <<-EOT
    Whether the spot instance itself is created. The launch template is always
    created; flipping this to false is the normal way to end a run without
    tearing down anything else.
  EOT
  type        = bool
  default     = false
}

variable "instance_type" {
  description = <<-EOT
    EC2 instance type.

    Phase 4 (ops loop rehearsal): c7a.2xlarge or similar.
    Phase 5-6 (production):       c7a.48xlarge, 192 physical cores / 384 GiB.

    A 192 vCPU spot request is bounded by the "All Standard (A, C, D, H, I,
    M, R, T, Z) Spot Instance Requests" quota (L-34B43A08). A fresh account
    sits far below 192; `make region-scout` reports the current value per
    region and prints the request command.

    m7a rather than c7a because memory, not price, is the open question: the
    reference run reports 438.5 GB across its 12 nodes, and c7a.48xlarge's
    384 GiB is not a comfortable ceiling against that. c7a.48xlarge is 20%
    cheaper per core and becomes the production type only once Phase 5 has
    measured the np=192 working set well clear of 384 GiB. r7a.48xlarge
    (1536 GiB) is the escape hatch if 768 GiB is also short.

    If capacity is unavailable, apply fails with InsufficientInstanceCapacity.
    Vary availability_zone first, then the instance type.

    c7i.48xlarge is not an equivalent substitute despite the similar vCPU
    count and price: 192 vCPUs there are 96 physical cores plus
    hyperthreading, on 8 memory channels rather than 12, which works out at
    0.0320 USD per physical core-hour against c7a's 0.0155.
  EOT
  type        = string
  default     = "m7a.48xlarge"
}

variable "subnet_id" {
  description = "Public subnet the instance is launched into. Vary it to try another AZ's spot pool."
  type        = string
}

variable "security_group_id" {
  description = "Security group applied to the instance."
  type        = string
}

variable "instance_profile_name" {
  description = "IAM instance profile granting SSM, ECR pull and S3 access."
  type        = string
}

variable "spot_max_price" {
  description = <<-EOT
    Maximum spot price in USD per hour. Null means the on-demand price is used
    as the ceiling, which is what AWS does by default and is the recommended
    setting: a manual cap below the market price does not save money, it just
    makes the instance un-launchable and un-restartable.
  EOT
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Size of the gp3 root volume. Working area only; the bucket is the system of record."
  type        = number
  default     = 500
}

variable "root_volume_throughput" {
  description = <<-EOT
    gp3 throughput in MB/s, between 125 and 1000.

    Sized from the Phase 2 measurement rather than a guess: a dx=28 run wrote
    a 25 GB checkpoint, which extrapolates to 25 x (28/19.2)^3 ~ 78 GB at the
    dx=19.2 production resolution. Reading 78 GB back for an S3 sync takes
    10.4 minutes at the 125 MB/s baseline and 1.3 minutes at 1000 MB/s.

    The extra 875 MB/s bills at roughly 0.048 USD/h, about 3.6 USD across a
    76 hour run -- immaterial next to a ~3 USD/h instance, and it is the
    difference between a sync that fits inside the interval and one that does
    not.

    gp3 caps throughput at 0.25 MB/s per provisioned IOPS, so 1000 MB/s
    requires root_volume_iops of at least 4000.
  EOT
  type        = number
  default     = 1000

  validation {
    condition     = var.root_volume_throughput >= 125 && var.root_volume_throughput <= 1000
    error_message = "gp3 throughput must be between 125 and 1000 MB/s."
  }
}

variable "root_volume_iops" {
  description = <<-EOT
    gp3 IOPS. 3000 is the free baseline; 4000 is the minimum that permits
    1000 MB/s. The extra 1000 IOPS costs about 0.007 USD/h.
  EOT
  type        = number
  default     = 4000
}

variable "ops_sns_topic_arn" {
  description = <<-EOT
    Regional SNS topic notified on a spot interruption warning. Null disables
    the EventBridge rule. The topic must live in this stack's region -- the
    us-east-1 budget topic cannot be used here.
  EOT
  type        = string
  default     = null
}

variable "run_config" {
  description = <<-EOT
    Values interpolated into the node bootstrap script.

    run_mode              "simulation" or "ops-rehearsal" (see run_mode below)
    ecr_repository_url    where the Einstein Toolkit image is pulled from
    image_tag             tag to pull; pin to a digest for production runs
    data_bucket           S3 bucket used for checkpoints, output and artifacts
    inputs_prefix         bucket prefix holding the parfile and FUKA initial data
    run_name              prefix segment identifying this run in the bucket,
                          and the parent directory of the run inside the
                          container -- checkpoint_dir is cwd relative, so two
                          runs sharing a parent would let recover=autoprobe
                          pick up the wrong resolution's checkpoint
    parfile               parameter file name inside inputs_prefix
    mpi_procs             MPI ranks; the reference run is pure MPI, OMP=1
    omp_threads           OpenMP threads per rank
    rehearsal_payload_gb  synthetic checkpoint size for ops-rehearsal mode
    rehearsal_generations how many generations the rehearsal writes, keeping
                          each one, so that the pruning has work to do
    checkpoint_generations_kept
                          generations left on the volume after a successful
                          push; also bounds S3, since a push mirrors the whole
                          directory into a slot
    sync_interval_minutes how often the sidecar timer syncs to S3
    auto_shutdown         terminate the instance when the run exits
  EOT
  type = object({
    run_mode              = string
    ecr_repository_url    = string
    image_tag             = string
    data_bucket           = string
    inputs_prefix         = string
    run_name              = string
    parfile               = string
    mpi_procs             = number
    omp_threads           = number
    rehearsal_payload_gb  = number
    rehearsal_generations = number

    checkpoint_generations_kept = number

    sync_interval_minutes = number
    auto_shutdown         = bool
  })

  validation {
    condition     = contains(["simulation", "ops-rehearsal"], var.run_config.run_mode)
    error_message = "run_mode must be \"simulation\" or \"ops-rehearsal\"."
  }
}

variable "user_data_template" {
  description = "Path to the bootstrap script template rendered into user data."
  type        = string
}
