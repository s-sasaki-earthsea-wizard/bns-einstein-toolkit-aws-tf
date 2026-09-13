# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki

variable "aws_region" {
  description = "Region of the foundation stack."
  type        = string
}

variable "default_tags" {
  description = "Tags applied to every resource."
  type        = map(string)

  default = {
    Project   = "gw230529"
    ManagedBy = "terraform"
  }
}

variable "foundation_state" {
  description = <<-EOT
    Location of the foundation stack's state, read through
    terraform_remote_state. Set it in terraform.tfvars alongside the values in
    backend.hcl.
  EOT
  type = object({
    bucket = string
    key    = string
    region = string
  })
}

variable "run_enabled" {
  description = <<-EOT
    Whether the spot instance exists. This is the on/off switch for a run:

      make run     -> apply with run_enabled = true
      make stop    -> apply with run_enabled = false

    The launch template is created either way, so `aws ec2 run-instances
    --launch-template` remains available as a manual escape hatch.
  EOT
  type        = bool
  default     = false
}

variable "run_mode" {
  description = <<-EOT
    What the node actually runs.

      "simulation"     pull the parfile and FUKA initial data from S3 and run
                       the Einstein Toolkit
      "ops-rehearsal"  run no physics at all: emit a synthetic checkpoint set
                       on a timer so the S3 slot rotation, the interruption
                       handler and the restore path can be exercised

    Phase 4 exists to prove the operations loop, not the physics, and the
    Phase 2 measurements say it cannot do both. The smallest instance that
    fits the dx=28 working set (37.1 GB measured) is c7a.8xlarge at 64 GiB,
    which spends most of the Phase 4 budget on a run whose output is thrown
    away. Coarser grids do not help: dx=33.6 still needs 21-26 GB, and dx=67.2
    fits in 16 GiB but dies with a NaN on the first evolution step, because
    CarpetRegrid2 radii are fixed in M so a coarser dx shrinks the refinement
    boxes to fewer cells than the ghost zones and prolongation buffers need.

    So Phase 4 rehearses with a dummy payload on c7a.2xlarge, and the physics
    waits for Phase 5 on the real machine.
  EOT
  type        = string
  default     = "simulation"

  validation {
    condition     = contains(["simulation", "ops-rehearsal"], var.run_mode)
    error_message = "run_mode must be \"simulation\" or \"ops-rehearsal\"."
  }
}

variable "rehearsal_payload_gb" {
  description = <<-EOT
    Size of the synthetic checkpoint set written in ops-rehearsal mode. The
    default matches the 25 GB that Phase 2 measured at dx=28, which is large
    enough for the sync timing to mean something without waiting on 78 GB.
  EOT
  type        = number
  default     = 25
}

variable "rehearsal_generations" {
  description = <<-EOT
    How many synthetic checkpoint generations ops-rehearsal mode writes, one
    after another, without deleting the previous one.

    Accumulation is the point. Cactus does not remove the previous generation
    either -- IO::checkpoint_keep prunes within a run but not across restarts,
    and Phase 2 was left with three generations and 77 GB after two runs. A
    rehearsal that tidied up after itself would exercise the slot rotation but
    never the pruning, which is the part that decides whether a 500 GB volume
    survives a run resumed a few times.

    Set this above checkpoint_generations_kept or the pruning never fires.
  EOT
  type        = number
  default     = 5

  validation {
    condition     = var.rehearsal_generations >= 1
    error_message = "rehearsal_generations must be at least 1."
  }
}

variable "checkpoint_generations_kept" {
  description = <<-EOT
    Generations of checkpoint the sidecar leaves on the local volume after a
    successful push to S3.

    Two, not one. The newest generation is the restart point; the one behind
    it is what Cactus falls back to through recover = "autoprobe" if the
    newest turns out unreadable, without going back to S3 for it. At the
    measured 85.7 GB per generation that is 171 GB of the 500 GB volume.

    This also bounds S3, which the slot rotation alone does not: the sidecar
    mirrors the whole checkpoint directory into a slot, so residency is two
    slots times whatever is on disk. Unpruned, a run resumed a few times
    reaches six generations, fills the volume at 468 GB, and puts 936 GB in
    the bucket.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.checkpoint_generations_kept >= 1
    error_message = "checkpoint_generations_kept must be at least 1."
  }
}

variable "instance_type" {
  description = <<-EOT
    EC2 instance type.

      Phase 4  c7a.2xlarge   ops rehearsal with a dummy payload, a few USD
      Phase 5  c7a.48xlarge  full resolution, throughput measurement
      Phase 6  c7a.48xlarge  production run

    c7a.2xlarge has 16 GiB, which is why Phase 4 runs with run_mode =
    "ops-rehearsal" rather than a real evolution -- see that variable.

    Memory was the open question and it is now measured, not projected. A
    full resolution 192 rank run at 8 refinement levels reported 125.273
    GByte from Carpet and 136 GiB across the whole node, on 2026-08-20. That
    is 35% of c7a.48xlarge's 384 GiB, which settles what the reference run's
    438.5 GB across 12 nodes and 480 ranks left ambiguous: that figure is a
    scheduler's high water mark over a decomposition duplicating far more
    ghost zones, not a floor on what 192 ranks need.

    So c7a.48xlarge, which is 20% cheaper per physical core -- 113-226 USD
    over the estimated run length against 142-285. m7a.48xlarge (768 GiB) is
    the fallback if a merger-time regrid turns out to grow the working set by
    more than the 2.8x headroom, and r7a.48xlarge (1536 GiB) behind it.

    Do NOT substitute c7i.48xlarge on price. Its 192 vCPUs are 96 physical
    Sapphire Rapids cores plus hyperthreading, against 192 real cores with
    SMT disabled on c7a, and it has 8 memory channels against 12 -- 0.0320
    USD per physical core-hour against c7a's 0.0155, for a bandwidth-bound
    evolution.

    Nor a smaller size: c7a.24xlarge holds 192 GiB, which no full resolution
    run fits into, and costs 31% more per physical core than the 48xlarge.
  EOT
  type        = string
  default     = "c7a.48xlarge"
}

variable "availability_zone" {
  description = <<-EOT
    Availability zone to launch into, for example "us-west-2b". Null picks the
    first subnet the foundation stack created. Spot capacity for very large
    instance types is uneven across zones, so this is the first thing to vary
    after an InsufficientInstanceCapacity error.
  EOT
  type        = string
  default     = null
}

variable "spot_max_price" {
  description = <<-EOT
    Maximum spot price in USD per hour. Null uses the on-demand price as the
    ceiling, which is the recommended setting -- a cap below the market price
    does not save money, it only makes the run un-restartable.
  EOT
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = <<-EOT
    Size of the gp3 root volume.

    A full resolution checkpoint measured 85.7 GB on 2026-08-20 -- 192 files,
    one per rank. At checkpoint_generations_kept = 2 that is 171 GB resident,
    leaving roughly 320 GB for diagnostic output at the 500 GB default.
    Revisit if the output volume turns out larger.

    The headroom depends on the sidecar pruning, not on the parfile. Phase 2
    found IO::checkpoint_keep prunes within a run but not across restarts, so
    an unpruned volume reaches six generations and 468 GB after a few resumes
    and the run then dies for want of space.
  EOT
  type        = number
  default     = 500
}

variable "root_volume_throughput" {
  description = <<-EOT
    gp3 throughput in MB/s, between 125 and 1000. Reading a 78 GB checkpoint
    back for an S3 sync takes 10.4 minutes at the 125 MB/s baseline and 1.3
    minutes at 1000 MB/s, for about 3.6 USD across a 76 hour run.
  EOT
  type        = number
  default     = 1000
}

variable "root_volume_iops" {
  description = "gp3 IOPS. 4000 is the minimum that permits 1000 MB/s throughput."
  type        = number
  default     = 4000
}

variable "image_tag" {
  description = <<-EOT
    ECR image reference to run: a tag, or a digest given as "sha256:...".
    Pin production runs to the digest -- a node relaunched after a spot
    interruption re-pulls this reference, and a mutable tag can have moved
    under it mid-run. Read the digest with:
      aws ecr describe-images --repository-name gw230529/einstein-toolkit \
        --image-ids imageTag=latest \
        --query 'imageDetails[0].imageDigest' --output text
  EOT
  type        = string
  default     = "latest"
}

variable "run_name" {
  description = <<-EOT
    Identifier for this run. It is both the top-level prefix in the data
    bucket and the parent directory of the run inside the container.

    The parent directory matters: the gallery parfile sets
    `IO::checkpoint_dir = "../CHECKPOINTS"`, which resolves relative to the
    run's working directory. Two runs sharing a parent would share a
    checkpoint directory, and `recover = "autoprobe"` would happily restart a
    dx=19.2 run from a dx=28 checkpoint. Include the resolution in the name.
  EOT
  type        = string
  default     = "run-dev"
}

variable "inputs_prefix" {
  description = <<-EOT
    Bucket prefix holding the parfile and the FUKA initial data.

    These are Einstein Toolkit gallery artefacts, not redistributable, so they
    are neither committed nor baked into the container image -- the simulation
    repository keeps them under a gitignored `upstream/` and excludes them from
    the Docker build context. The node fetches them from the private bucket at
    boot instead. Upload them with `make upload-inputs`.

    Four files, 1.6 MB total: the parfile, the FUKA .info and .dat, and the
    polytrope EOS table.
  EOT
  type        = string
  default     = "inputs"
}

variable "parfile" {
  description = <<-EOT
    Parameter file name inside inputs_prefix.

    The uploaded copy must already carry the spot-oriented settings; the node
    does not rewrite it:

      IO::checkpoint_ID                   = "yes"
      IO::checkpoint_every_walltime_hours = 1.0
      IO::checkpoint_keep                 = 2
      IO::recover                         = "autoprobe"

    `checkpoint_ID = "yes"` is the important one. Phase 2 measured the FUKA
    initial data import at 24.9 minutes locally, and it parallelises only over
    MPI ranks. Without an initial-data checkpoint every spot interruption pays
    that cost again.
  EOT
  type        = string
  default     = "bhns_gw230529.par"
}

variable "mpi_procs" {
  description = "MPI ranks. The reference run is pure MPI at np=256, OMP=1."
  type        = number
  default     = 192
}

variable "omp_threads" {
  description = "OpenMP threads per rank."
  type        = number
  default     = 1
}

variable "sync_interval_minutes" {
  description = <<-EOT
    How often the sidecar timer pushes checkpoints and output to S3.

    Short on purpose. A sync with nothing new to send is a LIST and nothing
    else, so frequency is close to free, and it is not the term that decides
    how much work an interruption costs:

      work lost ~ checkpoint interval / 2  +  sync interval / 2

    The checkpoint interval dominates, and it is set in the parfile
    (`IO::checkpoint_every_walltime_hours`), not here. Writing a 78 GB
    checkpoint stops every rank for about 78 seconds, so checkpointing hourly
    costs 2.2% of wall clock against 4.3% at half-hourly -- about 1.6 hours
    saved over a 76 hour run, against roughly 15 minutes of extra exposure per
    interruption. Hourly checkpoints with a 5 minute sync is the intended
    pairing while interruptions stay rare.
  EOT
  type        = number
  default     = 5
}

variable "auto_shutdown" {
  description = <<-EOT
    Terminate the instance when the run exits. Keep this true: billing data
    lags 8-24 hours, so the self-terminate is the only real-time cost guard.
    Set it false only when debugging a run interactively.
  EOT
  type        = bool
  default     = true
}
