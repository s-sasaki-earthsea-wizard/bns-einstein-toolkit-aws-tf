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
    Project   = "bns"
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

      "simulation"     pull the parfile and LORENE initial data from S3 and run
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

      ops rehearsal   c7a.2xlarge    dummy payload, a few USD
      probe / run     c7a.24xlarge   96 Genoa cores / 192 GiB, 24 ranks x 4 threads

    The gallery BNS is a small grid: about 8.3 M points on a quarter domain.
    Its published run reports 43.8 GByte from Carpet and about 89 GiB
    resident over 32 ranks (Teton, 2026-06-04); c7a.24xlarge holds that
    twice over. c7a.16xlarge (64 cores / 128 GiB) fits too, more tightly,
    and its spot pool is the calmest of the family in us-west-2.
    c7a.48xlarge is not needed for memory, and at 192 pure-MPI ranks this
    grid would be ghost-zone dominated -- the GW230529 run, at a similar
    points-per-rank count, paid +95% on total over active points.

    None of this is measured on this project yet. The throughput probe in
    terraform.tfvars.example is what turns this default into a decision;
    until then it is the GW230529 design with the size turned down.

    Do NOT substitute c7i on price. 96 physical Sapphire Rapids cores plus
    hyperthreading on 8 memory channels, against real Genoa cores on 12, is
    about 2x the cost per physical core-hour for a bandwidth-bound
    evolution.
  EOT
  type        = string
  default     = "c7a.24xlarge"
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

    Not measured for this project yet. Checkpoint size scales with the
    grid-function point count Carpet reports -- 5488M total for the gallery
    run at 32 ranks, against 13215M for the GW230529 run whose checkpoint
    measured 85.7 GB -- so a BNS generation should land around 35-50 GB
    depending on the rank count. At checkpoint_generations_kept = 2 that is
    under 100 GB resident, leaving about 200 GB for output at the 300 GB
    default. Measure it on the first probe and adjust.

    The headroom depends on the sidecar pruning, not on the parfile. The
    GW230529 project found IO::checkpoint_keep prunes within a run but not
    across restarts, so an unpruned volume fills after a few resumes and
    the run then dies for want of space.
  EOT
  type        = number
  default     = 300
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
      aws ecr describe-images --repository-name bns/einstein-toolkit \
        --image-ids imageTag=latest \
        --query 'imageDetails[0].imageDigest' --output text
  EOT
  type        = string
  default     = "latest"
}

variable "run_name" {
  description = <<-EOT
    Identifier for this run. It is both the second path element in the data
    bucket (checkpoints/<run_name>/, output/<run_name>/, ...) and the parent
    directory of the run inside the container.

    The parent directory matters: the cloud parfile sets
    `IO::checkpoint_dir = "../CHECKPOINTS"` (upload_inputs.sh rewrites the
    gallery's `$parfile` to that), which resolves relative to the run's
    working directory. Two runs sharing a parent would share a checkpoint
    directory, and `recover = "autoprobe"` would happily restart one run
    from another's checkpoint. Put the resolution and the end point in the
    name, e.g. prod-dx8-2500m.
  EOT
  type        = string
  default     = "run-dev"
}

variable "inputs_prefix" {
  description = <<-EOT
    Bucket prefix holding the parfile and the LORENE initial data.

    These are Einstein Toolkit gallery artefacts, not redistributable, so they
    are neither committed nor baked into the container image. `make
    fetch-inputs` downloads them into a gitignored `upstream/`, `make
    upload-inputs` derives the cloud parfile and puts both in the bucket,
    and the node fetches them from there at boot.

    Two files, about 12 MB: the derived parfile and the decompressed LORENE
    Bin_NS data set (G2_I12vs12_D4R33T21_45km.resu).
  EOT
  type        = string
  default     = "inputs"
}

variable "parfile" {
  description = <<-EOT
    Parameter file name inside inputs_prefix.

    The uploaded copy must already carry the spot-oriented settings; the node
    rewrites only the path to the initial data:

      IO::checkpoint_ID                   = "yes"
      IO::checkpoint_every_walltime_hours = 1.0
      IO::checkpoint_keep                 = 2
      IO::recover                         = "autoprobe"
      IO::checkpoint_dir / recover_dir    = "../CHECKPOINTS"
      TerminationTrigger::max_walltime    = <a number, not @WALLTIME_HOURS@>
      HTTPD                               not active

    `make upload-inputs` derives all of that from the gallery file and
    refuses to upload if any of it is missing. `checkpoint_ID = "yes"` is
    the important one: without an initial-data checkpoint every spot
    interruption re-imports the LORENE data and redoes the iteration 0
    setup before evolution resumes. How long that takes on this instance
    is not measured yet (the gallery log is unstamped); it is one of the
    numbers the first probe is for.
  EOT
  type        = string
  default     = "bns.par"
}

variable "mpi_procs" {
  description = <<-EOT
    MPI ranks. The gallery runs this parfile hybrid -- 32 ranks x 24 threads
    on Teton, 32 x 4 on Frontera. 24 ranks x 4 threads fills c7a.24xlarge's
    96 cores in the Frontera shape; use 16 on c7a.16xlarge, 48 on
    c7a.48xlarge. mpi_procs x omp_threads should equal the physical core
    count (SMT is off on c7a).
  EOT
  type        = number
  default     = 24
}

variable "omp_threads" {
  description = <<-EOT
    OpenMP threads per rank. 4 matches the gallery's Frontera configuration;
    GRHydro and ML_BSSN both parallelise over threads, so this is a real
    choice rather than a placeholder. 1 gives the pure-MPI shape the
    GW230529 run used, at the cost of more ghost zones on a grid this small.

    Thread placement is not configured in the launcher yet -- mpirun.mpich
    is invoked without binding flags and OMP_PROC_BIND is unset. Until that
    is measured (see the issue tracker), treat any hybrid throughput figure
    as a lower bound.
  EOT
  type        = number
  default     = 4
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
