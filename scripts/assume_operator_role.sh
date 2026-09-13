#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Assume the operator role with MFA and print the session as shell exports.
#
#   eval "$(make login)"
#
# Why this exists at all. The AWS CLI can prompt for an MFA token; Terraform's
# AWS provider cannot. Point a profile at a role with `mfa_serial` and every
# terraform command fails with
#
#   assume role with MFA enabled, but AssumeRoleTokenProvider session option
#   not set
#
# and there is no flag that fixes it, because there is nowhere for the provider
# to read six digits from. The CLI's own credential cache under
# ~/.aws/cli/cache does not help either: the Go SDK the provider is built on
# does not read it.
#
# So the token is collected once, here, and the resulting temporary credentials
# go into the environment where both the CLI and Terraform find them.
#
# The token is read from the terminal rather than taken as an argument, so it
# never reaches the shell history. The exports go to stdout and everything a
# human should read goes to stderr, which is what makes the eval above work.
#
# Nothing is written to disk. The session dies with the shell, or when it
# expires -- whichever comes first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
cd "${REPO_ROOT}"

# The profile carrying role_arn and mfa_serial. The static access key lives in
# its source_profile and, once the user policy is narrowed, can do nothing
# except assume this role and rotate itself.
PROFILE="${OPERATOR_PROFILE:-${AWS_PROFILE:-gw230529}}"
DURATION="${SESSION_SECONDS:-28800}"

conf() { aws configure get "$1" --profile "${PROFILE}" 2>/dev/null || true; }

ROLE_ARN="$(conf role_arn)"
MFA_SERIAL="$(conf mfa_serial)"
SOURCE_PROFILE="$(conf source_profile)"
REGION="$(conf region)"

if [ -z "${ROLE_ARN}" ] || [ -z "${MFA_SERIAL}" ] || [ -z "${SOURCE_PROFILE}" ]; then
  {
    echo "profile '${PROFILE}' is not set up to assume a role with MFA."
    echo ""
    echo "It needs all three of role_arn, mfa_serial and source_profile."
    echo "Found:"
    printf '  %-15s %s\n' role_arn       "${ROLE_ARN:-<missing>}"
    printf '  %-15s %s\n' mfa_serial     "${MFA_SERIAL:-<missing>}"
    printf '  %-15s %s\n' source_profile "${SOURCE_PROFILE:-<missing>}"
    echo ""
    echo "make output-bootstrap prints a ready-to-paste ~/.aws/config."
  } >&2
  exit 1
fi

# /dev/tty, not stdin: stdin is where the caller's eval is reading from.
#
# Test by opening it rather than with -r. The path exists and looks readable
# even in a session with no controlling terminal -- a cron job, a CI runner,
# an agent -- and only the open fails, which without this guard surfaces as a
# bare redirection error from the middle of the script.
if ! { : >/dev/tty; } 2>/dev/null; then
  {
    echo "no controlling terminal, so there is nowhere to read the MFA token from."
    echo ""
    echo "Run this from an interactive shell:"
    echo "  eval \"\$(make login)\""
    echo ""
    echo "For an unattended context, assume the role elsewhere and pass"
    echo "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN in."
  } >&2
  exit 1
fi

printf 'MFA token for %s: ' "${MFA_SERIAL}" >/dev/tty
read -r TOKEN </dev/tty
printf '\n' >/dev/tty

case "${TOKEN}" in
  [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) echo "expected six digits, got: ${TOKEN}" >&2; exit 1 ;;
esac

CREDS="$(aws sts assume-role \
  --profile "${SOURCE_PROFILE}" \
  --role-arn "${ROLE_ARN}" \
  --role-session-name "terraform-operator" \
  --serial-number "${MFA_SERIAL}" \
  --token-code "${TOKEN}" \
  --duration-seconds "${DURATION}" \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken,Expiration]' \
  --output text)"

read -r KEY SECRET SESSION EXPIRES <<<"${CREDS}"

# AWS_PROFILE has to go, or it wins over the variables below and the CLI goes
# back to trying to assume the role by itself -- which is the failure this
# script exists to route around.
printf 'unset AWS_PROFILE\n'
printf 'export AWS_ACCESS_KEY_ID=%s\n'     "${KEY}"
printf 'export AWS_SECRET_ACCESS_KEY=%s\n' "${SECRET}"
printf 'export AWS_SESSION_TOKEN=%s\n'     "${SESSION}"
[ -n "${REGION}" ] && printf 'export AWS_DEFAULT_REGION=%s\nexport AWS_REGION=%s\n' "${REGION}" "${REGION}"

{
  echo "assumed ${ROLE_ARN}"
  echo "session expires ${EXPIRES}"
  echo ""
  echo "This shell only. Nothing was written to disk."
} >&2
