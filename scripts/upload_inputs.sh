#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Derive the cloud parameter file from the pristine gallery one, check that it
# can survive a spot interruption, and upload it with the initial data.
#
# The gallery parfile is written for a batch queue run under simfactory. It
# checkpoints only when the job's wall clock runs out, keeps its checkpoints
# next to its output, and carries a simfactory placeholder that Cactus itself
# cannot parse. Seven things change before it is fit for a spot instance:
#
#   IO::checkpoint_every_walltime_hours   absent -> 1.0
#       The gallery relies on checkpoint_on_terminate, driven by
#       TerminationTrigger 30 minutes before the queue limit. A spot
#       interruption gives two minutes, not thirty, so the run has to leave
#       checkpoints behind on a schedule. Expected loss per interruption is
#       half the interval. Revisit once the checkpoint size is measured: at
#       an estimated ~45 GB and 1000 MB/s a write costs under a minute, and
#       a shorter interval may be nearly free.
#
#   IO::checkpoint_keep                   absent -> 2
#       The default is 1. Two generations on the volume means a local
#       fallback if the newest one is unreadable.
#
#   IO::checkpoint_dir / IO::recover_dir  $parfile -> "../CHECKPOINTS"
#       The node bind-mounts a separate host directory at
#       /home/etuser/simulations/<run_name>/CHECKPOINTS, which is what lets
#       the sidecar rotate checkpoints through S3 slots while pushing output
#       additively. The gallery writes both into the output directory, where
#       the sidecar would treat them as output.
#
#   TerminationTrigger::max_walltime      @WALLTIME_HOURS@ -> 8760
#       A simfactory substitution that never happens here. Cactus refuses to
#       start on the literal. There is no queue limit on a spot node, so the
#       walltime trigger is set far enough out never to fire; the
#       termination *file* trigger stays on, which is how a graceful stop
#       can be requested from outside.
#
#   Cactus::cctk_final_time               2500.0 (kept)
#       The gallery end point: merger at t ~ 1750 and a hypermassive
#       remnant for ~750 more. Override with CCTK_FINAL_TIME.
#
#   HTTPD, Socket                         dropped
#       Cactus's built-in web server, useless behind a security group with
#       no ingress, and it segfaults in the container when it cannot bind
#       its socket. See the rewrite below.
#
# Two settings the gallery already gets right -- checkpoint_ID = "yes" and
# recover = "autoprobe" -- are asserted rather than set, so that an upstream
# change is caught here rather than on a billing instance. checkpoint_ID is
# the one that matters most: without an initial-data checkpoint every
# interruption re-imports the LORENE data before evolution can resume.
#
# The upstream file is left untouched; the cloud variant is derived into a
# separate file. Every rewrite is checked afterwards. A sed that silently
# matches nothing is the failure mode this whole script exists to prevent.
#
# The parfile's absolute path to the LORENE data set is left alone here --
# the node rewrites it onto whatever it mounted. What is checked is the
# basename, because that is what the node then has to find among the files
# this script uploads.
#
# --probe MINUTES additionally derives a throughput probe parfile: the cloud
# parfile with its termination condition changed from a physical time it will
# never reach to a wall clock cap it certainly will.
#
#   Cactus::terminate    "time" -> "runtime"
#   Cactus::max_runtime   absent -> MINUTES
#
# The cap is the cost guard. Nothing else in this repository bounds how long a
# run bills for -- auto_shutdown fires when the run exits, and the production
# parfile does not exit for a day or more -- so a probe launched against the
# production parfile is a machine billing while it waits to be noticed.
#
# Everything else is left at the production setting on purpose. A probe that
# switched off checkpointing to look faster would measure a run nobody is
# going to make.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
cd "${REPO_ROOT}"

TF="${TF:-terraform}"
SRC_DIR="${INPUTS_DIR:-upstream}"
PARFILE="bns.par"
ID_NAME="G2_I12vs12_D4R33T21_45km.resu"
BUILD_DIR="${SRC_DIR}/.cloud"

PROBE_PARFILE="bns_probe.par"

CADENCE_HOURS="${CHECKPOINT_WALLTIME_HOURS:-1.0}"
FINAL_TIME="${CCTK_FINAL_TIME:-2500.0}"
MAX_WALLTIME_HOURS="${TERMINATION_MAX_WALLTIME_HOURS:-8760}"
CKPT_DIR='"../CHECKPOINTS"'
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

if [ ! -f "${SRC_DIR}/${PARFILE}" ] || [ ! -f "${SRC_DIR}/${ID_NAME}" ]; then
  echo "gallery artefacts not found under ${SRC_DIR}/"
  echo "Fetch them first:"
  echo "  make fetch-inputs"
  echo "or point INPUTS_DIR at a directory that already has them."
  exit 1
fi

mkdir -p "${BUILD_DIR}"
OUT="${BUILD_DIR}/${PARFILE}"
cp "${SRC_DIR}/${PARFILE}" "${OUT}"

# Both IO:: and IOUtil:: name the same thorn, so every pattern here accepts
# either.
P='(IO|IOUtil)'

set_or_append() {
  local key="$1" value="$2" file="$3"
  if grep -qE "^[[:space:]]*${P}::${key}[[:space:]]*=" "${file}"; then
    sed -i -E "s#^([[:space:]]*${P}::${key}[[:space:]]*=[[:space:]]*).*\$#\\1${value}#" "${file}"
  else
    # Keep it with the other checkpoint settings when there is an anchor to
    # hang it on, rather than orphaning it at the end of the file.
    if grep -qE "^[[:space:]]*${P}::checkpoint_on_terminate[[:space:]]*=" "${file}"; then
      sed -i -E "/^[[:space:]]*${P}::checkpoint_on_terminate[[:space:]]*=/a IO::${key} = ${value}" "${file}"
    else
      printf '\nIO::%s = %s\n' "${key}" "${value}" >> "${file}"
    fi
  fi
}

echo "Deriving the cloud parfile from ${SRC_DIR}/${PARFILE}"

# HTTPD goes. The gallery keeps Cactus's built-in web server on for steering
# from a login node; here nothing can reach it -- the security group has no
# ingress -- and the thorn segfaults inside the container when it cannot bind
# its socket (observed with --exit-after-param-check on 2026-09-13, exit 139
# right after "HTTPD Failed to create server socket"). Socket goes with it;
# nothing else in this parfile uses it. The HTTPD:: parameters have to go
# too, since Cactus refuses parameters of a thorn that is not active.
sed -i -E \
  -e '/^[[:space:]]*ActiveThorns[[:space:]]*=[[:space:]]*"[[:space:]]*HTTPD[[:space:]]+Socket[[:space:]]*"[[:space:]]*$/d' \
  -e '/^[[:space:]]*HTTPD::/d' \
  "${OUT}"

set_or_append "checkpoint_every_walltime_hours" "${CADENCE_HOURS}" "${OUT}"
set_or_append "checkpoint_keep"                 "2"                "${OUT}"
set_or_append "checkpoint_ID"                   '"yes"'            "${OUT}"
set_or_append "checkpoint_dir"                  "${CKPT_DIR}"      "${OUT}"
set_or_append "recover_dir"                     "${CKPT_DIR}"      "${OUT}"

# cctk_final_time and max_walltime are not IO::, so they do not go through
# set_or_append. The gallery always sets both, so a plain rewrite suffices
# and the assertions below catch a sed that matched nothing.
sed -i -E \
  "s#^([[:space:]]*Cactus::cctk_final_time[[:space:]]*=[[:space:]]*).*\$#\\1${FINAL_TIME}#" \
  "${OUT}"
sed -i -E \
  "s#^([[:space:]]*TerminationTrigger::max_walltime[[:space:]]*=[[:space:]]*).*\$#\\1${MAX_WALLTIME_HOURS}#" \
  "${OUT}"

echo ""
echo "Difference from upstream:"
diff -u "${SRC_DIR}/${PARFILE}" "${OUT}" | sed -n '3,$p' | sed 's/^/  /' || true

# --------------------------------------------------------------------
# Assertions. The ones just set and the ones the gallery is trusted for are
# all checked the same way, because the point is whether the file that
# reaches S3 can survive an interruption, not whether a particular sed fired.
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
# alike.
check_parfile() {
  TARGET="$1"

  assert "checkpoint_every_walltime_hours" \
    "^[[:space:]]*${P}::checkpoint_every_walltime_hours[[:space:]]*=[[:space:]]*${CADENCE_HOURS}([[:space:]]|\$)" \
    "not set to ${CADENCE_HOURS} -- the rewrite did not take"
  assert "checkpoint_ID" \
    "^[[:space:]]*${P}::checkpoint_ID[[:space:]]*=[[:space:]]*\"?yes\"?[[:space:]]*\$" \
    "not \"yes\" -- every interruption would re-import the LORENE data"
  assert "checkpoint_keep" \
    "^[[:space:]]*${P}::checkpoint_keep[[:space:]]*=[[:space:]]*[2-9][0-9]*[[:space:]]*\$" \
    "below 2 -- no local fallback if the newest checkpoint is unreadable"
  assert "checkpoint_dir" \
    "^[[:space:]]*${P}::checkpoint_dir[[:space:]]*=[[:space:]]*\"\.\./CHECKPOINTS\"[[:space:]]*\$" \
    "not \"../CHECKPOINTS\" -- the sidecar would treat checkpoints as output"
  assert "recover_dir" \
    "^[[:space:]]*${P}::recover_dir[[:space:]]*=[[:space:]]*\"\.\./CHECKPOINTS\"[[:space:]]*\$" \
    "not \"../CHECKPOINTS\" -- a relaunched node would not find the restored set"
  assert "recover" \
    "^[[:space:]]*${P}::recover[[:space:]]*=[[:space:]]*\"?autoprobe\"?[[:space:]]*\$" \
    "not \"autoprobe\" -- a relaunched node would start from scratch"
  assert "Cactus::cctk_final_time" \
    "^[[:space:]]*Cactus::cctk_final_time[[:space:]]*=[[:space:]]*${FINAL_TIME}([[:space:]]|\$)" \
    "not ${FINAL_TIME} -- the end point rewrite did not take"
  assert "TerminationTrigger::max_walltime" \
    "^[[:space:]]*TerminationTrigger::max_walltime[[:space:]]*=[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*(#.*)?\$" \
    "not numeric -- Cactus refuses the simfactory placeholder"
  # Two of these would be a parameter set twice, which Cactus refuses at
  # start-up, and the run would die after the boot rather than during this
  # check.
  for key in checkpoint_every_walltime_hours checkpoint_keep checkpoint_ID checkpoint_dir recover_dir; do
    if [ "$(grep -cE "^[[:space:]]*${P}::${key}[[:space:]]*=" "${TARGET}")" -ne 1 ]; then
      printf '  %-34s FAIL %s\n' "${key}" "set more than once"
      status=1
    fi
  done

  # HTTPD must be gone entirely, thorn and parameters alike.
  if grep -qE '^[[:space:]]*[^#[:space:]].*HTTPD' "${TARGET}"; then
    printf '  %-34s FAIL %s\n' "HTTPD" \
      "still present -- the thorn segfaults in the container without a socket"
    status=1
  else
    printf '  %-34s OK   %s\n' "HTTPD" "dropped (no ingress to serve, and it crashes without a socket)"
  fi

  # The parfile names the LORENE data set by absolute path -- whatever
  # machine the gallery example was last run from. The node rewrites the
  # directory at boot, so the path here does not matter, but the basename
  # does, because that is the file the node then looks for among the ones
  # this script uploads.
  local in_par basename
  in_par="$(sed -nE \
    's|^[[:space:]]*meudon_bin_ns::filename[[:space:]]*=[[:space:]]*"([^"]*)".*|\1|Ip' \
    "${TARGET}" | head -1)"
  basename="${in_par##*/}"

  if [ -z "${basename}" ]; then
    printf '  %-34s FAIL %s\n' "Meudon_Bin_NS::filename" \
      "absent -- the run would have no initial data to import"
    status=1
  elif [ "${basename}" != "${ID_NAME}" ]; then
    printf '  %-34s FAIL %s\n' "Meudon_Bin_NS::filename" \
      "names ${basename}, but the fetched data set is ${ID_NAME}"
    status=1
  elif [ ! -f "${SRC_DIR}/${basename}" ]; then
    printf '  %-34s FAIL %s\n' "Meudon_Bin_NS::filename" \
      "names ${basename}, which is not in ${SRC_DIR}/"
    status=1
  else
    printf '  %-34s OK   %s\n' "Meudon_Bin_NS::filename" \
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
    "not \"runtime\" -- the probe would run to t = ${FINAL_TIME} on a billing node"
  assert "Cactus::max_runtime" \
    "^[[:space:]]*Cactus::max_runtime[[:space:]]*=[[:space:]]*${PROBE_MINUTES}[[:space:]]*\$" \
    "not ${PROBE_MINUTES} -- a zero or absent cap never fires"
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
# about all of them, and --exit-after-param-check makes it say so in well
# under a minute without touching the initial data -- a misspelled parameter,
# a value outside its range, or a parameter set twice all abort here rather
# than after a boot on a billing machine.
#
# Skipped rather than fatal when the image is not on this machine: the parfile
# is still checked by everything above, and refusing to upload because a
# container image is missing would be its own kind of failure.
#
# The image has to be the BNS build, which carries NSTracker. The GW230529
# image compiles every other thorn this parfile activates but not that one,
# and the check fails on thorn activation against it.
# --------------------------------------------------------------------
LOCAL_IMAGE="${LOCAL_IMAGE:-bns-et:local}"

param_check() {
  local file="$1" label="$2"
  if ! docker image inspect "${LOCAL_IMAGE}" >/dev/null 2>&1; then
    printf '  %-34s SKIP %s\n' "${label}" "${LOCAL_IMAGE} is not on this machine"
    return 0
  fi
  if docker run --rm -v "$(cd "$(dirname "${file}")" && pwd):/parcheck:ro" \
       "${LOCAL_IMAGE}" /home/etuser/Cactus/exe/cactus_sim \
       -P "/parcheck/$(basename "${file}")" >/tmp/bns-paramcheck.$$ 2>&1; then
    printf '  %-34s OK   %s\n' "${label}" "Cactus accepts every parameter"
    rm -f /tmp/bns-paramcheck.$$
  else
    printf '  %-34s FAIL %s\n' "${label}" "Cactus rejected it:"
    tail -20 /tmp/bns-paramcheck.$$ | sed 's/^/      /'
    rm -f /tmp/bns-paramcheck.$$
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
aws s3 cp "${SRC_DIR}/${ID_NAME}" "s3://${BUCKET}/inputs/${ID_NAME}"

echo ""
echo "Done. The absolute path to the LORENE data set inside the uploaded"
echo "parfile is still the gallery's, and is meant to be: the node rewrites it"
echo "onto its own mount point at boot and aborts if the rewrite does not take."

if [ -n "${PROBE_OUT}" ]; then
  echo ""
  echo "To run the probe, point the compute stack at it:"
  echo "  parfile = \"${PROBE_PARFILE}\""
fi
