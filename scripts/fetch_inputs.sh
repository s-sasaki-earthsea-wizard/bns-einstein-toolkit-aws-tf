#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Fetch the Einstein Toolkit gallery artefacts this project runs on.
#
# Four files, 1.6 MB: the BH-NS parameter file and the FUKA/Kadath initial
# data it imports. They are upstream gallery material, so this repository
# records where they come from and what they should hash to, and nothing else.
# Downloads land in a gitignored directory and are never committed, never
# baked into the container image, and never pushed to ECR -- a mis-set
# repository visibility would otherwise turn an inconvenience into a
# redistribution problem.
#
# Why fetch here rather than reach into the simulation repository. The old
# default pointed INPUTS_DIR at ../gw230529-einstein-toolkit/upstream, which
# meant a fresh clone of this repository could not do a production run at all
# unless the sibling happened to be checked out beside it, and nothing
# declared that dependency. Fetching from the gallery makes this repository
# stand on its own -- and gives a better starting point besides: the sibling's
# copy of the .info file has a host-specific absolute EOS path edited into it,
# while upstream still carries the /path/to/ placeholder the node's boot-time
# rewrite is written against.
#
# --reference additionally fetches the gallery's published reference run
# (bhns_20252103, the same dx=19.2 configuration run to t = 3051 M on
# COSMA8) and extracts its stdout log. That log carries the CarpetIOBasic
# info line -- rho_b and constraint extrema every 4 iterations -- in exactly
# the format our own cactus-stdout.log uses, which is what a live run is
# validated against. 573 MB for a 4.5 MB file, so it is opt-in; if the
# simulation repository is checked out beside this one, copy its tarball
# into upstream/ first and the download is skipped. Optional: nothing in
# the run path needs it.
#
# Checksums are pinned. Two repositories fetching the same artefacts
# independently can drift, and upstream can change under us without saying so.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
cd "${REPO_ROOT}"

BASE_URL="https://einsteintoolkit.org/gallery/bhns"
DEST="${INPUTS_DIR:-upstream}"

# Verified 2026-08-20 against the gallery, and byte-identical to the copies the
# simulation repository has been running on since Phase 1 (except the .info,
# which it edited locally -- see the header).
PAR_NAME="bhns_gw230529.par"
PAR_SHA="d216cc57f2ef6a0fbe75cb51fef4d5eda508c299a3958f5036ae6519c70a016a"
ID_NAME="bhns_gw230529_ID.tar.gz"
ID_SHA="d958896318f5bb55b669ea1186f1d86f4d6bc4260b0493179645f55912a2b38c"

# The reference run lives on the Einstein Toolkit download host, not under
# the gallery page. Verified 2026-08-27 against the copy the simulation
# repository has been analysing against since Phase 3.
REF_NAME="bhns_20252103.tar.gz"
REF_SHA="ccfbe412cac4f33db834d24d8b939e3b8d352da5c32e59ac590eceb12688c028"
REF_URL="https://bitbucket.org/einsteintoolkit/www/downloads/bhns_20252103.tar.gz"
REF_LOG="bhns_20252103/bhns_gw230529.out"

FORCE=""
WANT_REFERENCE=""
for arg in "$@"; do
  case "${arg}" in
    --force)     FORCE=1 ;;
    --reference) WANT_REFERENCE=1 ;;
    *) echo "unknown argument: ${arg}"; echo "usage: $0 [--force] [--reference]"; exit 2 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }
have curl || { echo "curl is required"; exit 1; }
have sha256sum || { echo "sha256sum is required"; exit 1; }

# Verify without downloading, so a second run is free and a corrupted file is
# still caught.
verify() {
  local file="$1" want="$2" got
  [ -f "${file}" ] || return 1
  got="$(sha256sum "${file}" | cut -d' ' -f1)"
  [ "${got}" = "${want}" ]
}

fetch() {
  local name="$1" want="$2" out="$3" url="${4:-${BASE_URL}/$1}" tmp
  tmp="${out}.part"

  if [ -z "${FORCE}" ] && verify "${out}" "${want}"; then
    echo "  ${name}: already present and matching"
    return 0
  fi

  echo "  ${name}: downloading from ${url}"
  curl -fsSL --max-time 1800 -o "${tmp}" "${url}" || {
    rm -f "${tmp}"
    echo "  ${name}: download failed"
    return 1
  }

  if ! verify "${tmp}" "${want}"; then
    echo ""
    echo "  ${name}: CHECKSUM MISMATCH"
    echo "    expected ${want}"
    echo "    got      $(sha256sum "${tmp}" | cut -d' ' -f1)"
    echo ""
    echo "  Either the download was corrupted, or the gallery has published a"
    echo "  new version. Do not paper over this by editing the pin: fetch the"
    echo "  file by hand, read what changed, and update the pin deliberately."
    rm -f "${tmp}"
    return 1
  fi

  mv "${tmp}" "${out}"
  echo "  ${name}: verified"
}

echo "Fetching Einstein Toolkit BH-NS gallery artefacts into ${DEST}/"
echo "Upstream: ${BASE_URL}/"
echo "These are not redistributable -- ${DEST}/ is gitignored, keep it that way."
echo ""

mkdir -p "${DEST}"

fetch "${PAR_NAME}" "${PAR_SHA}" "${DEST}/${PAR_NAME}"
fetch "${ID_NAME}"  "${ID_SHA}"  "${DEST}/${ID_NAME}"

# The tarball unpacks to bhns_gw230529_ID/, which is the layout the upload
# step and the INPUTS_DIR override both expect.
echo "  ${ID_NAME}: extracting"
tar xzf "${DEST}/${ID_NAME}" -C "${DEST}"

MISSING=0
for f in \
  "${PAR_NAME}" \
  "bhns_gw230529_ID/BHNS_ECC_RED.gam2.30.0.0.5.q0.388889.0.0.13.info" \
  "bhns_gw230529_ID/BHNS_ECC_RED.gam2.30.0.0.5.q0.388889.0.0.13.dat" \
  "bhns_gw230529_ID/gam2.polytrope"
do
  if [ -f "${DEST}/${f}" ]; then
    printf '  %-58s %8s bytes\n' "${f}" "$(stat -c%s "${DEST}/${f}")"
  else
    printf '  %-58s MISSING\n' "${f}"
    MISSING=1
  fi
done

if [ "${MISSING}" -ne 0 ]; then
  echo ""
  echo "The archive did not contain what was expected. Nothing was uploaded."
  exit 1
fi

if [ -n "${WANT_REFERENCE}" ]; then
  echo ""
  fetch "${REF_NAME}" "${REF_SHA}" "${DEST}/${REF_NAME}" "${REF_URL}"
  # Just the log. The rest of the archive -- 2D snapshots, horizon surfaces --
  # is what the simulation repository analyses; this repository only compares
  # info lines.
  echo "  ${REF_NAME}: extracting ${REF_LOG}"
  tar xzf "${DEST}/${REF_NAME}" -C "${DEST}" "${REF_LOG}"
  if [ ! -f "${DEST}/${REF_LOG}" ]; then
    echo "  ${REF_LOG}: MISSING from the archive"
    exit 1
  fi
  printf '  %-58s %8s bytes\n' "${REF_LOG}" "$(stat -c%s "${DEST}/${REF_LOG}")"
fi

echo ""
echo "Ready. Next:  make upload-inputs"
