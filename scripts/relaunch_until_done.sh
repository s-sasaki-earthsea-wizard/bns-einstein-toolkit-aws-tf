#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Keep the spot node alive until the run finishes -- the improvised half of
# issue #23, written during the us-west-2 c7a capacity crunch of 2026-08-27,
# when the node was reclaimed twice in one evening and every relaunch needed
# a human holding an MFA device.
#
# The loop relaunches the SAME configuration -- region, zone, instance type
# all come from stacks/compute/terraform.tfvars -- and lets terraform's own
# create-retry ride out InsufficientInstanceCapacity, which was measured to
# behave as a free capacity poll (nothing is created and nothing bills until
# the pool has an instance to give). Changing what to launch is tfvars
# business, not this script's.
#
# This doubles as the measurement Syota actually wants: with the human out of
# the relaunch path, `make ledger`'s duty cycle measures what spot supply is
# worth, not who was awake.
#
# WHAT BOUNDS IT
#
#   - The operator session. Terraform applies as the MFA-gated operator role
#     and a session lasts SESSION_SECONDS (default 8 h); this loop cannot and
#     must not refresh it. On credential failure it says so and exits --
#     restart it after the next `eval "$(make login)"`.
#   - MAX_LAUNCHES (default 12). A reclaim-after-restore cycle costs about
#     half a dollar; the cap is the thrashing budget, not a target.
#   - The ended marker's reason. "finished" ends the loop as success;
#     "failed" ends it WITHOUT relaunching -- recover=autoprobe would restore
#     the same state and die the same death at 3 USD/h, and a crash is a
#     human's problem. Only "spot-interruption" (or a vanished node, which
#     writes no marker) earns a relaunch.
#   - A stop file. `touch .relaunch-stop` and the loop exits before its next
#     launch; use it before `make stop` so the two do not fight.
#
# Usage, in tmux on a machine that can stay up:
#
#   eval "$(make login)"
#   scripts/relaunch_until_done.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
cd "${REPO_ROOT}"

TF="${TF:-terraform}"
MAX_LAUNCHES="${MAX_LAUNCHES:-12}"
POLL_SECONDS="${POLL_SECONDS:-60}"
STOP_FILE=".relaunch-stop"

REGION="$(${TF} -chdir=stacks/compute output -raw aws_region 2>/dev/null || echo us-west-2)"
LOG_PREFIX="$(${TF} -chdir=stacks/compute output -raw log_prefix)" || {
  echo "cannot read the compute stack -- no session? eval \"\$(make login)\" first" >&2
  exit 1
}

say() { echo "[$(date -u +%FT%TZ)] $*"; }

session_alive() { aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1; }

launches=0
while :; do
  if [ -e "${STOP_FILE}" ]; then
    say "${STOP_FILE} exists -- stopping. Remove it before the next start."
    exit 0
  fi
  if ! session_alive; then
    say "operator session is gone -- eval \"\$(make login)\" and restart this script"
    exit 3
  fi

  launches=$((launches + 1))
  if [ "${launches}" -gt "${MAX_LAUNCHES}" ]; then
    say "launch cap of ${MAX_LAUNCHES} reached -- stopping so a human can reassess"
    exit 4
  fi

  say "launch ${launches}/${MAX_LAUNCHES}: terraform apply (blocks while the pool is dry)"
  if ! ${TF} -chdir=stacks/compute apply -input=false -auto-approve -var run_enabled=true; then
    if ! session_alive; then
      say "apply failed and the session is gone -- restart after the next make login"
      exit 3
    fi
    say "apply failed with a live session -- pausing 5 minutes before retrying"
    sleep 300
    launches=$((launches - 1))   # a failed apply launched nothing
    continue
  fi

  INSTANCE="$(${TF} -chdir=stacks/compute output -raw instance_id 2>/dev/null)"
  if [ -z "${INSTANCE}" ] || [ "${INSTANCE}" = "null" ]; then
    say "apply succeeded but there is no instance -- is run_enabled being overridden? stopping"
    exit 5
  fi
  say "node ${INSTANCE} is up -- watching it"

  # Watch until the instance leaves pending/running. DescribeInstances on a
  # known id is free and the operator session is already in the environment.
  while :; do
    STATE="$(aws ec2 describe-instances --instance-ids "${INSTANCE}" --region "${REGION}" \
      --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo unknown)"
    case "${STATE}" in
      pending|running) ;;
      *) say "node ${INSTANCE} is ${STATE}"; break ;;
    esac
    if [ -e "${STOP_FILE}" ]; then
      say "${STOP_FILE} exists -- leaving the node alone and stopping the loop"
      exit 0
    fi
    if ! session_alive; then
      say "session expired while watching -- the RUN IS UNAFFECTED, restart this script after make login"
      exit 3
    fi
    sleep "${POLL_SECONDS}"
  done

  # The marker is written up to a couple of minutes before termination is
  # visible, but S3 and EC2 can disagree briefly; give it three minutes.
  MARKER=""
  for _ in 1 2 3 4 5 6; do
    MARKER="$(aws s3 cp "${LOG_PREFIX}ended-${INSTANCE}.json" - --only-show-errors 2>/dev/null)" && break
    sleep 30
  done

  REASON="$(echo "${MARKER}" | sed -nE 's/.*"reason":"([^"]*)".*/\1/p')"
  case "${REASON}" in
    finished)
      say "run FINISHED -- marker: ${MARKER}"
      say "the loop is done; make stop will tidy the launch template state"
      exit 0
      ;;
    failed)
      say "run FAILED -- not relaunching, autoprobe would only die again. Marker: ${MARKER}"
      exit 6
      ;;
    spot-interruption)
      say "spot reclaimed ${INSTANCE} -- relaunching. Marker: ${MARKER}"
      ;;
    *)
      say "node ${INSTANCE} vanished with no marker (third outcome) -- relaunching anyway"
      ;;
  esac
done
