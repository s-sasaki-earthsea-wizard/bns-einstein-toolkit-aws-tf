#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Sync a run's output/ prefix from S3 into results/<run_name>/.
#
# This is both the input step for the post-processing figures and the
# project's data preservation: objects under output/ expire 90 days after
# they were written (modules/storage), which for the production run lands
# right before the talk that needs them. The full prefix is ~10 GB; egress
# at $0.09/GB prices the whole download under one dollar.
#
# Read-only, so the observer profile works and no MFA session is needed:
#
#   make fetch-results AWS_PROFILE=gw230529-observer
#
# With no argument the prefix is derived from the compute stack's
# run_log_url output. Deriving it beats adding an output_prefix output to
# the stack: a new output is invisible to `terraform output` until the next
# apply, and the observer cannot apply.
#
# Usage:
#   scripts/fetch_results.sh [s3://bucket/output/<run_name>/]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
TF="${TF:-terraform}"
RESULTS_ROOT="${RESULTS_ROOT:-${REPO_ROOT}/results}"

PREFIX="${1:-}"
if [ -z "${PREFIX}" ]; then
  cd "${REPO_ROOT}"
  LOG_URL="$(${TF} -chdir=stacks/compute output -raw run_log_url 2>/dev/null || true)"
  if [ -z "${LOG_URL}" ]; then
    echo "the compute stack's run_log_url could not be read." >&2
    echo "Is there a session? Try AWS_PROFILE=gw230529-observer in a shell" >&2
    echo "with no operator session, or pass the prefix directly:" >&2
    echo "  scripts/fetch_results.sh s3://<bucket>/output/<run_name>/" >&2
    exit 1
  fi
  PREFIX="${LOG_URL%run/cactus-stdout.log}"
fi

case "${PREFIX}" in
  s3://*/output/*/) ;;
  *)
    echo "expected s3://<bucket>/output/<run_name>/ -- got: ${PREFIX}" >&2
    exit 2
    ;;
esac

RUN_NAME="$(basename "${PREFIX}")"
DEST="${RESULTS_ROOT}/${RUN_NAME}"

mkdir -p "${DEST}"
echo "syncing ${PREFIX} -> ${DEST}"
aws s3 sync "${PREFIX}" "${DEST}" --only-show-errors

echo ""
echo "fetched: $(du -sh "${DEST}" | cut -f1), $(find "${DEST}" -type f | wc -l) files"
