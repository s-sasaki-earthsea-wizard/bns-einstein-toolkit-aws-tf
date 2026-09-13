# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# The role a human assumes to run Terraform, and the MFA condition that makes
# a stolen access key useless on its own.
#
# WHY THE ROLE IS HERE AND NOT IN foundation
#
# Same reason this stack keeps its state local: dependency direction. The
# foundation and compute stacks are applied *by* this role, so a role defined
# in one of them would be a resource that grants permission to create itself.
# The bootstrap stack is the one thing applied before everything else, once,
# and left alone -- which is exactly the lifetime a credential boundary wants.
#
# WHY THE ACCESS KEY IS NOT HERE
#
# `aws_iam_access_key` writes the secret into Terraform state in plaintext,
# and the state bucket next door is versioned, so the secret would survive in
# every past version of the file after any attempt to remove it. Worse, the
# credential Terraform authenticates with would be managed by Terraform: an
# apply that fails half way leaves no working credential, and the state lock
# sits in the bucket that credential just lost access to.
#
# The policy, the role and the trust relationship are declarative facts and
# belong in code. The secret is not a declarative fact. Key rotation stays a
# documented manual step -- see the README -- and this role is what makes the
# frequency of that rotation stop mattering very much.

data "aws_caller_identity" "current" {}

locals {
  operator_user_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${var.operator_user_name}"
}

# Who may assume the role, and under what condition.
#
# `Bool` and not `BoolIfExists`. The principal is a named IAM user, so
# aws:MultiFactorAuthPresent is always in the request context -- false for a
# plain long-term access key, true once an MFA token has been presented.
# BoolIfExists would let a request through whenever the key happened to be
# absent, which is the failure mode this whole condition exists to prevent.
#
# This is the line that changes what a leaked access key is worth. On its own
# the key can now do nothing at all: it cannot reach this role, and after the
# user policy is narrowed (policies/terraform-bootstrap-user.json) it has no
# permissions of its own either.
data "aws_iam_policy_document" "operator_assume_role" {
  statement {
    sid     = "OperatorWithMfa"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [local.operator_user_arn]
    }

    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role" "operator" {
  name               = var.operator_role_name
  description        = "Role a human assumes to run Terraform for GW230529. MFA required."
  assume_role_policy = data.aws_iam_policy_document.operator_assume_role.json

  # Seconds. The AWS range is 3600 to 43200. Eight hours covers a working day
  # without a second MFA prompt, and is still bounded in a way a long-term
  # access key never is -- which is the whole point of the change.
  max_session_duration = var.operator_session_seconds

  # Destroying this role locks the operator out of the account, because after
  # the user policy is narrowed the user can do nothing except assume it.
  # Recovery needs an administrator. Make removal a deliberate act.
  lifecycle {
    prevent_destroy = true
  }
}

# The same policy document `make check-permissions-policy` simulates against,
# read from disk rather than duplicated. One source of truth: a permission
# proven in the checker is the permission the role actually carries.
#
# Note what is deliberately NOT in here: the statement letting the user manage
# its own access keys. `aws:username` is unset for a role session, and key
# management belongs to the user regardless -- see
# policies/terraform-bootstrap-user.json.
resource "aws_iam_role_policy" "operator" {
  name   = "${var.operator_role_name}-policy"
  role   = aws_iam_role.operator.id
  policy = file("${path.module}/../../policies/terraform-operator.json")
}
