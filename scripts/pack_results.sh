#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Compress a fetched results tree into one tar.gz and delete the tree.
#
# The raw tree is ~1,900 files; the NAS this repository lives on is itself
# backed up object-by-object to Deep Archive, so once the figures are done
# the tree's only remaining job is to exist, and one archive does that at a
# fraction of the object count. Deleting the raw tree is the point, not a
# side effect -- which is why this script verifies the archive lists the
# same number of files before it removes anything, and asks first.
#
# Re-inflating later is `tar xzf results/<run_name>.tar.gz -C results/`, and
# while the S3 prefix is still alive `make fetch-results` re-downloads it.
#
# Usage:
#   scripts/pack_results.sh [--yes] [<run_name>]
#
# With no run name, the sole directory under results/ is packed; more than
# one is an error rather than a guess.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
RESULTS_ROOT="${RESULTS_ROOT:-${REPO_ROOT}/results}"

ASSUME_YES=""
RUN_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    -*)    echo "unknown option: $1" >&2; exit 2 ;;
    *)     RUN_NAME="$1"; shift ;;
  esac
done

if [ -z "${RUN_NAME}" ]; then
  mapfile -t dirs < <(find "${RESULTS_ROOT}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  if [ "${#dirs[@]}" -ne 1 ]; then
    echo "expected exactly one directory under ${RESULTS_ROOT}, found ${#dirs[@]}." >&2
    echo "Name the run: scripts/pack_results.sh <run_name>" >&2
    exit 2
  fi
  RUN_NAME="$(basename "${dirs[0]}")"
fi

TREE="${RESULTS_ROOT}/${RUN_NAME}"
ARCHIVE="${RESULTS_ROOT}/${RUN_NAME}.tar.gz"
test -d "${TREE}" || { echo "no such directory: ${TREE}" >&2; exit 2; }

if [ -e "${ARCHIVE}" ]; then
  echo "refusing to overwrite existing ${ARCHIVE}" >&2
  exit 2
fi

n_tree="$(find "${TREE}" -type f | wc -l)"
echo "packing ${TREE} (${n_tree} files, $(du -sh "${TREE}" | cut -f1)) -> ${ARCHIVE}"
tar czf "${ARCHIVE}" -C "${RESULTS_ROOT}" "${RUN_NAME}"

n_archive="$(tar tzf "${ARCHIVE}" | grep -cv '/$')"
if [ "${n_tree}" != "${n_archive}" ]; then
  echo "archive lists ${n_archive} files but the tree has ${n_tree} -- keeping both." >&2
  exit 1
fi
echo "archive verified: ${n_archive} files, $(du -sh "${ARCHIVE}" | cut -f1)"

if [ -z "${ASSUME_YES}" ]; then
  printf "delete the raw tree %s? [y/N] " "${TREE}"
  read -r reply
  case "${reply}" in
    y|Y|yes) ;;
    *) echo "keeping the tree. Delete later with: rm -rf ${TREE}"; exit 0 ;;
  esac
fi

rm -rf "${TREE}"
echo "deleted ${TREE}"
