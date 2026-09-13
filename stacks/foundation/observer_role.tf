# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# A read-only role for watching a run, assumable without MFA.
#
# WHY IT EXISTS
#
# Everything that blocked an unattended watcher during the 2026-08-26 recovery
# test was read-only: reading the CURRENT marker, listing a checkpoint slot,
# fetching the bootstrap log while the run was in flight, `make throughput`,
# `make heartbeat`, and DescribeInstances to tell "finished" from "stuck".
# None of it needs gw230529-terraform-operator, and every one of those calls
# had to be relayed to a human holding an MFA device.
#
# WHY NOT credential_process WITH A STORED TOTP SEED
#
# That would remove the six digit prompt from the operator profile, and it
# would also put both factors on the same disk under the same uid: the access
# key in ~/.aws/credentials and the seed beside it. AWS would still evaluate
# aws:MultiFactorAuthPresent as true, so the trust condition in
# stacks/bootstrap/operator_role.tf would go on being satisfied while the
# property it is there to buy was gone for anything that can read the home
# directory.
#
# It is also the wrong shape for the problem. The friction is in *reading*,
# and reading is exactly the part that does not need a second factor.
#
# WHY HERE AND NOT IN stacks/bootstrap
#
# The operator role lives in bootstrap to avoid the circularity of a role
# defined in a stack that the role itself applies. Nothing is ever applied
# with this role, so no such circularity exists. Foundation already owns the
# data bucket the policy scopes to, and bootstrap is deliberately minimal
# because its state is local.
#
# The cost of that choice: `terraform destroy` here removes the role, and the
# observer profile then fails with AccessDenied rather than announcing itself.

data "aws_caller_identity" "current" {}

locals {
  observer_user_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${var.observer_user_name}"

  # The state bucket name lives in backend.hcl, which Terraform does not
  # expose to the configuration, so pinning it exactly means repeating it as
  # a variable. Null falls back to the pattern stacks/bootstrap creates it
  # under -- a wildcard that would matter only if a second bucket were ever
  # named gw230529-tfstate-something.
  state_bucket_arn = (
    var.state_bucket_name != null
    ? "arn:aws:s3:::${var.state_bucket_name}"
    : "arn:aws:s3:::${var.name_prefix}-tfstate-*"
  )
}

# Who may assume the role. Note what is NOT here: the
# aws:MultiFactorAuthPresent condition that stacks/bootstrap puts on the
# operator role.
#
# That absence is the whole point, and it is a conscious trade rather than an
# omission. Before it, an access key leaked on its own bought nothing at all.
# After it, the same key buys read access to the data bucket, to the
# foundation and compute state, and to some describes. What it does not buy is
# any ability to change, create or destroy anything, or to spend money.
#
# The bucket holds simulation output and checkpoints, not secrets -- though
# the bootstrap log does carry the account id, which is why this repository
# keeps that id out of tracked files in the first place.
#
# A dedicated observer IAM user with its own key would separate the material
# further. It would also add a second long-term key, which is the direction
# this project has spent the last week moving away from.
data "aws_iam_policy_document" "observer_assume_role" {
  statement {
    sid     = "ObserverNoMfa"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [local.observer_user_arn]
    }
  }
}

resource "aws_iam_role" "observer" {
  # Has to keep the gw230529- prefix: policies/terraform-bootstrap-user.json
  # names this ARN literally, and the operator policy scopes iam:CreateRole to
  # role/gw230529-*, so a name outside the prefix cannot be created at all.
  name               = "${var.name_prefix}-observer"
  description        = "Read-only role for watching a GW230529 run. No MFA, by design."
  assume_role_policy = data.aws_iam_policy_document.observer_assume_role.json

  # The AWS default of one hour, deliberately left alone. The operator role
  # takes eight because each renewal costs an MFA prompt; there is no prompt
  # here, so the CLI renews silently and a longer session would buy nothing.
  max_session_duration = 3600

  # No prevent_destroy, unlike the operator role. Losing that one locks the
  # account out and needs an administrator to undo; losing this one costs a
  # re-apply.
}

data "aws_iam_policy_document" "observer" {
  # ListBucket is a bucket level action and takes the bucket ARN without /*.
  # GetBucketLocation is what the CLI calls before an `s3 ls` against a bucket
  # in a region it has not been told about.
  statement {
    sid       = "ListDataBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [module.storage.bucket_arn]
  }

  statement {
    sid       = "ReadDataObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${module.storage.bucket_arn}/*"]
  }

  # `make throughput` and `make heartbeat` resolve the bucket name and the run
  # prefix through `terraform output`, which reads state. It takes no lock, so
  # nothing here needs write access.
  #
  # Listing is left unscoped on purpose: what it exposes is the set of stack
  # names, which is already in the repository. The object read is the part
  # worth scoping, and it is scoped to exactly the two stacks those targets
  # read.
  #
  # That enumeration is NOT keeping bootstrap/ out. stacks/bootstrap holds its
  # state locally -- it creates the bucket, so it cannot live in it -- and
  # there is no bootstrap/ key here to reach. Naming the two prefixes buys
  # something else: a stack added later is out of scope until someone adds it
  # here, rather than readable the moment it first writes state.
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.state_bucket_arn]
  }

  statement {
    sid     = "ReadFoundationAndComputeState"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:GetObjectVersion"]

    resources = [
      "${local.state_bucket_arn}/foundation/*",
      "${local.state_bucket_arn}/compute/*",
    ]
  }

  # EC2 ARNs carry no project name, so no prefix pattern can separate this
  # project's instances from any other -- see policies/README.md. For the
  # operator that is a real problem, answered with a tag conditioned Deny on
  # the destructive actions. Here every action is a Describe, which is what
  # makes "*" acceptable: the worst case is learning what else runs in an
  # account that runs nothing else.
  statement {
    sid    = "DescribeCompute"
    effect = "Allow"

    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeSpotInstanceRequests",
      "ec2:DescribeVolumes",

      # What a run was launched WITH, not just whether it is running (#16).
      # Establishing the 2026-08-26 recovery test's sync interval from
      # outside the run required decoding user_data out of the terraform
      # state -- which reports what the stack would launch now, not what the
      # instance booted with. The launch template versions survive the node;
      # DescribeInstanceAttribute reads the booted user_data while it lives.
      # None of the three supports resource-level permissions.
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeInstanceAttribute",
    ]

    resources = ["*"]
  }

  # CloudWatch has no resource level permissions for metric reads at all.
  statement {
    sid    = "ReadMetrics"
    effect = "Allow"

    actions = [
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
    ]

    resources = ["*"]
  }

  # The one grant here that is not obviously free, and the one to delete first
  # if this role is ever judged too generous.
  #
  # It is included because noticing runaway spend is most of what a watcher is
  # for, and a budget alert arrives by mail on a threshold rather than on
  # demand. The exposure is account wide billing data, in an account that
  # holds this project and nothing else. Cost Explorer has no resource level
  # permissions either.
  statement {
    sid    = "ReadSpend"
    effect = "Allow"

    actions = [
      "ce:GetCostAndUsage",
      "ce:GetCostForecast",
    ]

    resources = ["*"]
  }

  # No explicit Deny. The operator policy needs one because it carries ec2:*
  # on *; this role carries only what is listed above, and everything absent
  # is already an implicit deny.
}

resource "aws_iam_role_policy" "observer" {
  name   = "${var.name_prefix}-observer"
  role   = aws_iam_role.observer.id
  policy = data.aws_iam_policy_document.observer.json
}
