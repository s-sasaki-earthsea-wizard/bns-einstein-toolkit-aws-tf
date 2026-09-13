#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Derive the cloud parameter file from the pristine gallery one, check that it
# can survive a spot interruption, and upload it with the initial data.
#
# The gallery parfile is written for COSMA8, where jobs are capped at 30 hours
# and a checkpoint every 29 hours costs nothing. Two settings have to change
# before it is fit for a spot instance:
#
#   IO::checkpoint_every_walltime_hours   29 -> 1.0
#       Expected loss on an interruption is about half the checkpoint interval.
#       A cloud run is 38-76 hours, so leaving it at 29 means an interruption
#       costs 14.5 hours on average -- a fifth to nearly half the whole run.
#       Writing 78 GB stops every rank for ~78 seconds, which at hourly is
#       2.2% of wall clock: cheap against what it protects.
#
#   IO::checkpoint_ID                     absent -> "yes"
#       Absent means "no" (CactusBase/IOUtil param.ccl). The FUKA import took
#       24.9 minutes locally at dx=28 and parallelises only over MPI ranks,
#       so without an initial-data checkpoint every interruption pays it again
#       before evolution can resume.
#
#   Cactus::cctk_final_time               2000.0 -> 1750.0
#       Decided 2026-08-27. The dx=28 dry run and the reference both show the
#       remnant disc mass settled by merger + ~180 M, and the gallery page
#       shows an essentially flat state well before 2000 M. 1750 M is merger
#       (t ~ 713 M) + ~1040 M: the full ringdown at the r=500 extraction
#       radius (the merger signal arrives there at t ~ 1213 M) plus the early
#       disc evolution, minus ~4.8 h / ~15 USD of flat tail. 1500 M was
#       rejected as ending right on the ringdown's heels.
#       Override with CCTK_FINAL_TIME for a different end point.
#
# The upstream file is left untouched; the cloud variant is derived into a
# separate file. Two settings the gallery already gets right for our purposes
# -- recover = "autoprobe" and checkpoint_keep = 2 -- are asserted rather than
# set, so that an upstream change is caught here rather than at 3 USD/hour.
#
# Every rewrite is checked afterwards. A sed that silently matches nothing is
# the failure mode this whole script exists to prevent.
#
# The parfile's own /path/to/ placeholder for the FUKA initial data is left
# alone here -- the node rewrites it onto whatever it mounted. What is checked
# is the basename, because that is what the node then has to find among the
# files this script uploads.
#
# --probe MINUTES additionally derives a throughput probe parfile: the cloud
# parfile with its termination condition changed from a physical time it will
# never reach to a wall clock cap it certainly will.
#
#   Cactus::terminate    "time" -> "runtime"
#   Cactus::max_runtime   absent -> MINUTES
#
# The cap is the cost guard. Nothing else in this repository bounds how long a
# run bills for -- auto_shutdown fires when the run exits, and a full
# resolution parfile does not exit for days -- so a probe launched against the
# production parfile is a machine at 3 USD/h waiting to be noticed. With the
# cap, the run ends itself and the node terminates.
#
# Everything else is left at the production setting on purpose. A probe that
# switched off checkpointing to look faster would measure a run nobody is
# going to make: the hourly checkpoint stops every rank while 85.7 GB is
# written, and that is a real term in the budget, not an artefact to be
# tuned away.
#
# This also closes the gap that #7 describes. Every probe parfile so far came
# from the simulation repository and was copied into the bucket by hand,
# bypassing the checks below -- so the machine that produced them was a
# dependency nobody had declared, and the memory probe parfile was never
# inspected for recover, checkpoint_keep or the initial data basename.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
cd "${REPO_ROOT}"

TF="${TF:-terraform}"
SRC_DIR="${INPUTS_DIR:-upstream}"
PARFILE="bhns_gw230529.par"
ID_DIR="bhns_gw230529_ID"
BUILD_DIR="${SRC_DIR}/.cloud"

PROBE_PARFILE="bhns_gw230529_probe.par"

CADENCE_HOURS="${CHECKPOINT_WALLTIME_HOURS:-1.0}"
FINAL_TIME="${CCTK_FINAL_TIME:-1750.0}"
PROBE_MINUTES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --probe)
      PROBE_MINUTES="${2:-}"
      case "${PROBE_MINUTES}" in
        ''|*[!0-9.]*)
          echo "--probe wants a number of minutes, got: ${PROBE_MINUTES}" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    -h|--help)
      echo "usage: $0 [--probe MINUTES]"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ ! -f "${SRC_DIR}/${PARFILE}" ] || [ ! -d "${SRC_DIR}/${ID_DIR}" ]; then
  echo "gallery artefacts not found under ${SRC_DIR}/"
  echo "Fetch them first:"
  echo "  make fetch-inputs"
  echo "or point INPUTS_DIR at a directory that already has them."
  exit 1
fi

mkdir -p "${BUILD_DIR}"
OUT="${BUILD_DIR}/${PARFILE}"
cp "${SRC_DIR}/${PARFILE}" "${OUT}"

# Both IO:: and IOUtil:: name the same thorn and the gallery file uses both,
# so every pattern here accepts either.
P='(IO|IOUtil)'

set_or_append() {
  local key="$1" value="$2" file="$3"
  if grep -qE "^[[:space:]]*${P}::${key}[[:space:]]*=" "${file}"; then
    sed -i -E "s#^([[:space:]]*${P}::${key}[[:space:]]*=[[:space:]]*).*\$#\\1${value}#" "${file}"
  else
    # Keep it with the other checkpoint settings when there is an anchor to
    # hang it on, rather than orphaning it at the end of the file.
    if grep -qE "^[[:space:]]*${P}::checkpoint_every_walltime_hours[[:space:]]*=" "${file}"; then
      sed -i -E "/^[[:space:]]*${P}::checkpoint_every_walltime_hours[[:space:]]*=/a IO::${key} = ${value}" "${file}"
    else
      printf '\nIO::%s = %s\n' "${key}" "${value}" >> "${file}"
    fi
  fi
}

echo "Deriving the cloud parfile from ${SRC_DIR}/${PARFILE}"
set_or_append "checkpoint_every_walltime_hours" "${CADENCE_HOURS}" "${OUT}"
set_or_append "checkpoint_ID"                   '"yes"'            "${OUT}"

# cctk_final_time is Cactus::, not IO::, so it does not go through
# set_or_append. The gallery always sets it, so a plain rewrite suffices and
# the assertion below catches a sed that matched nothing.
sed -i -E \
  "s#^([[:space:]]*Cactus::cctk_final_time[[:space:]]*=[[:space:]]*).*\$#\\1${FINAL_TIME}#" \
  "${OUT}"

echo ""
echo "Difference from upstream:"
diff -u "${SRC_DIR}/${PARFILE}" "${OUT}" | sed -n '3,$p' | sed 's/^/  /' || true

# --------------------------------------------------------------------
# Assertions. Two we just set, two the gallery is trusted for -- all four
# checked the same way, because the point is whether the file that reaches S3
# can survive an interruption, not whether a particular sed fired.
# --------------------------------------------------------------------
status=0
TARGET=""

assert() {
  local label="$1" pattern="$2" why="$3" line
  # `|| true`: a failing grep is the whole point of this function, and under
  # `set -e` with `pipefail` an unguarded one kills the script at the first
  # missing setting -- reporting nothing, which is the silent failure this
  # script exists to prevent.
  line="$(grep -hE "${pattern}" "${TARGET}" | head -1 | sed 's/^[[:space:]]*//' || true)"
  if [ -n "${line}" ]; then
    printf '  %-34s OK   %s\n' "${label}" "${line}"
  else
    printf '  %-34s FAIL %s\n' "${label}" "${why}"
    status=1
  fi
}

# Every parfile that leaves here goes through this, production and probe
# alike. The probe is the one that had been skipping it -- see #7 -- and it is
# the one that runs on the same 3 USD/h machine, so it has the most to lose
# from a setting nobody looked at.
check_parfile() {
  TARGET="$1"

  assert "checkpoint_every_walltime_hours" \
    "^[[:space:]]*${P}::checkpoint_every_walltime_hours[[:space:]]*=[[:space:]]*${CADENCE_HOURS}([[:space:]]|\$)" \
    "not set to ${CADENCE_HOURS} -- the rewrite did not take"
  assert "checkpoint_ID" \
    "^[[:space:]]*${P}::checkpoint_ID[[:space:]]*=[[:space:]]*\"?yes\"?[[:space:]]*\$" \
    "not \"yes\" -- every interruption would re-import the FUKA data"
  assert "Cactus::cctk_final_time" \
    "^[[:space:]]*Cactus::cctk_final_time[[:space:]]*=[[:space:]]*${FINAL_TIME}([[:space:]]|\$)" \
    "not ${FINAL_TIME} -- the end point rewrite did not take"
  assert "recover" \
    "^[[:space:]]*${P}::recover[[:space:]]*=[[:space:]]*\"?autoprobe\"?[[:space:]]*\$" \
    "not \"autoprobe\" -- a relaunched node would start from scratch"
  assert "checkpoint_keep" \
    "^[[:space:]]*${P}::checkpoint_keep[[:space:]]*=[[:space:]]*[2-9][0-9]*[[:space:]]*\$" \
    "below 2 -- no local fallback if the newest checkpoint is unreadable"

  # The parfile names the FUKA .info file by absolute path, and the gallery
  # ships the same /path/to/ placeholder there as inside the .info itself. The
  # node rewrites the directory at boot, so the path here does not matter --
  # but the basename does, because that is the file the node then looks for
  # among the ones this script uploads. A parfile naming an .info that is not
  # in the initial data set produces a Kadath import error a whole boot later.
  local in_par basename
  in_par="$(sed -nE \
    's|^[[:space:]]*kadathimporter::filename[[:space:]]*=[[:space:]]*"([^"]*)".*|\1|Ip' \
    "${TARGET}" | head -1)"
  basename="${in_par##*/}"

  if [ -z "${basename}" ]; then
    printf '  %-34s FAIL %s\n' "kadathimporter::filename" \
      "absent -- the run would have no initial data to import"
    status=1
  elif [ ! -f "${SRC_DIR}/${ID_DIR}/${basename}" ]; then
    printf '  %-34s FAIL %s\n' "kadathimporter::filename" \
      "names ${basename}, which is not in ${SRC_DIR}/${ID_DIR}/"
    status=1
  else
    printf '  %-34s OK   %s\n' "kadathimporter::filename" \
      "${basename} (the node rewrites the directory at boot)"
  fi
}

echo ""
echo "Spot survivability of the derived parfile:"
check_parfile "${OUT}"

# --------------------------------------------------------------------
# The throughput probe variant
#
# Derived from the cloud parfile rather than from upstream, so it inherits the
# checkpoint settings and their checks and differs from the production run in
# exactly one respect: when it stops.
# --------------------------------------------------------------------
PROBE_OUT=""
if [ -n "${PROBE_MINUTES}" ]; then
  PROBE_OUT="${BUILD_DIR}/${PROBE_PARFILE}"
  cp "${OUT}" "${PROBE_OUT}"

  echo ""
  echo "Deriving a ${PROBE_MINUTES} minute throughput probe parfile"

  # Cactus rejects a parameter set twice, so max_runtime is appended only if
  # the gallery has not started setting it. terminate is always present.
  sed -i -E \
    "s#^([[:space:]]*Cactus::terminate[[:space:]]*=[[:space:]]*).*\$#\\1\"runtime\"#" \
    "${PROBE_OUT}"
  if grep -qE "^[[:space:]]*Cactus::max_runtime[[:space:]]*=" "${PROBE_OUT}"; then
    sed -i -E \
      "s#^([[:space:]]*Cactus::max_runtime[[:space:]]*=[[:space:]]*).*\$#\\1${PROBE_MINUTES}#" \
      "${PROBE_OUT}"
  else
    sed -i -E \
      "/^[[:space:]]*Cactus::terminate[[:space:]]*=/a Cactus::max_runtime = ${PROBE_MINUTES}" \
      "${PROBE_OUT}"
  fi

  echo ""
  echo "Difference from the production parfile:"
  diff -u "${OUT}" "${PROBE_OUT}" | sed -n '3,$p' | sed 's/^/  /' || true

  echo ""
  echo "Spot survivability of the probe parfile:"
  check_parfile "${PROBE_OUT}"

  echo ""
  echo "Cost guard of the probe parfile:"
  TARGET="${PROBE_OUT}"
  assert "Cactus::terminate" \
    "^[[:space:]]*Cactus::terminate[[:space:]]*=[[:space:]]*\"runtime\"[[:space:]]*\$" \
    "not \"runtime\" -- the probe would run to t = 2000 M at 3 USD/h"
  assert "Cactus::max_runtime" \
    "^[[:space:]]*Cactus::max_runtime[[:space:]]*=[[:space:]]*${PROBE_MINUTES}[[:space:]]*\$" \
    "not ${PROBE_MINUTES} -- a zero or absent cap never fires"
  # Belt and braces: two of these would be a parameter set twice, which Cactus
  # refuses at start-up, and the run would die after the boot rather than
  # during this check.
  if [ "$(grep -cE '^[[:space:]]*Cactus::max_runtime[[:space:]]*=' "${PROBE_OUT}")" -ne 1 ]; then
    printf '  %-34s FAIL %s\n' "Cactus::max_runtime" "set more than once"
    status=1
  fi
fi

if [ "${status}" -ne 0 ]; then
  echo ""
  echo "Refusing to upload a parfile that cannot survive an interruption."
  echo "Nothing was sent to S3."
  exit 1
fi

# --------------------------------------------------------------------
# Ask Cactus itself
#
# The greps above check the settings this script knows about. Cactus knows
# about all of them, and --exit-after-param-check makes it say so in about
# forty seconds without touching the initial data -- a misspelled parameter,
# a value outside its range, or a parameter set twice all abort here rather
# than after a five minute boot on a machine billing at 3 USD/h.
#
# Skipped rather than fatal when the image is not on this machine: the parfile
# is still checked by everything above, and refusing to upload because a
# 4 GB container image is missing would be its own kind of failure.
# --------------------------------------------------------------------
LOCAL_IMAGE="${LOCAL_IMAGE:-gw230529-et:local}"

param_check() {
  local file="$1" label="$2"
  if ! docker image inspect "${LOCAL_IMAGE}" >/dev/null 2>&1; then
    printf '  %-34s SKIP %s\n' "${label}" "${LOCAL_IMAGE} is not on this machine"
    return 0
  fi
  if docker run --rm -v "$(cd "$(dirname "${file}")" && pwd):/parcheck:ro" \
       "${LOCAL_IMAGE}" /home/etuser/Cactus/exe/cactus_sim \
       -P "/parcheck/$(basename "${file}")" >/tmp/gw230529-paramcheck.$$ 2>&1; then
    printf '  %-34s OK   %s\n' "${label}" "Cactus accepts every parameter"
    rm -f /tmp/gw230529-paramcheck.$$
  else
    printf '  %-34s FAIL %s\n' "${label}" "Cactus rejected it:"
    tail -20 /tmp/gw230529-paramcheck.$$ | sed 's/^/      /'
    rm -f /tmp/gw230529-paramcheck.$$
    status=1
  fi
}

echo ""
echo "Parameter check against ${LOCAL_IMAGE}:"
param_check "${OUT}" "${PARFILE}"
if [ -n "${PROBE_OUT}" ]; then
  param_check "${PROBE_OUT}" "${PROBE_PARFILE}"
fi

if [ "${status}" -ne 0 ]; then
  echo ""
  echo "Refusing to upload a parfile Cactus will not start with."
  echo "Nothing was sent to S3."
  exit 1
fi

# --------------------------------------------------------------------
# Upload
# --------------------------------------------------------------------
BUCKET="$(${TF} -chdir=stacks/foundation output -raw data_bucket 2>/dev/null)"
if [ -z "${BUCKET}" ]; then
  echo ""
  echo "cannot read data_bucket from stacks/foundation -- apply it first"
  exit 1
fi

echo ""
echo "Uploading to s3://${BUCKET}/inputs/"
echo "Upstream gallery material: not committed here, not baked into the image."

aws s3 cp "${OUT}" "s3://${BUCKET}/inputs/${PARFILE}"
if [ -n "${PROBE_OUT}" ]; then
  aws s3 cp "${PROBE_OUT}" "s3://${BUCKET}/inputs/${PROBE_PARFILE}"
fi
aws s3 cp "${SRC_DIR}/${ID_DIR}/" "s3://${BUCKET}/inputs/" \
  --recursive --exclude '*' \
  --include '*.info' --include '*.dat' --include 'gam2.polytrope'

echo ""
echo "Done. Both /path/to/ placeholders -- the eosfile inside the .info and the"
echo "initial data path in the parfile -- are still in the uploaded copies, and"
echo "are meant to be: the node rewrites them onto its own mount point at boot"
echo "and aborts if either rewrite does not take."

if [ -n "${PROBE_OUT}" ]; then
  echo ""
  echo "To run the probe, point the compute stack at it:"
  echo "  parfile = \"${PROBE_PARFILE}\""
fi
