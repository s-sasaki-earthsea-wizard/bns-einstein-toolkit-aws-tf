#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Fetch the Einstein Toolkit gallery artefacts this project runs on.
#
# Three files: the BNS parameter file, the LORENE initial data it imports
# (a 3.6 MB .xz that unpacks to 12 MB) and the thornlist that documents the
# one thorn the example needs beyond the release manifest, NSTracker. They
# are upstream gallery material, so this repository records where they come
# from and what they should hash to, and nothing else. Downloads land in a
# gitignored directory and are never committed, never baked into the
# container image, and never pushed to ECR -- a mis-set repository
# visibility would otherwise turn an inconvenience into a redistribution
# problem.
#
# The initial data is decompressed here rather than on the node. LORENE reads
# the .resu directly, and the decompressed file is what upload_inputs.sh
# sends to the bucket, so nothing in the boot path depends on xz being
# present on the instance.
#
# --reference additionally fetches the gallery's published results tarball
# (bns-20260604.tar.gz, 88 MB) and extracts its stdout log, the parfile the
# run actually used, and the run notes. That log carries the CarpetIOBasic
# info line -- rest mass, density and constraint extrema, every iteration --
# in exactly the format our own cactus-stdout.log uses, which is what a live
# run is validated against (scripts/validate_against_reference.sh). Optional:
# nothing in the run path needs it.
#
# Checksums are pinned. Upstream can change under us without saying so, and
# the gallery page itself says the example was last tested on 2026-06-04.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
cd "${REPO_ROOT}"

BASE_URL="https://einsteintoolkit.org/gallery/bns"
DEST="${INPUTS_DIR:-upstream}"

# Verified 2026-09-13 against the gallery.
PAR_NAME="bns.par"
PAR_SHA="d4ef36d0df3b31a1da1c88ce02acedaf8ffdf88d7aede34f2caa9dc121a72ae7"
TH_NAME="bns.th"
TH_SHA="43c8670ae0b5fa9656ae1bbc7694ce48baf67787e1be04396712d0ec44b33fcc"
ID_XZ_NAME="G2_I12vs12_D4R33T21_45km.resu.xz"
ID_XZ_SHA="e82ec6cbda01702372f06cf167b785612adc2971af2ed2aeed827e239bbc664b"
# The decompressed data set, which is what the parfile names and the node
# reads. Pinned separately so that a truncated decompression is caught too.
ID_NAME="G2_I12vs12_D4R33T21_45km.resu"
ID_SHA="6517e40a1847822fd031b36207de78820339a9a7b4cbba537f921d4488553e96"

# The reference run lives on the Einstein Toolkit download host, not under
# the gallery page. Run on Teton (INL) on 2026-06-04: 2 nodes, 32 MPI ranks
# of 24 threads, 10 h 33 min to t = 2500.
REF_NAME="bns-20260604.tar.gz"
REF_SHA="8e7f6c4016b6c1b5b3f79e799cba2814f79a30d31ba0993d18f42269b02533e6"
REF_URL="https://bitbucket.org/einsteintoolkit/www/downloads/bns-20260604.tar.gz"
REF_LOG="results/bns-1905387.out"
REF_PAR="results/bnsg.par"
REF_NOTES="results/run_notes.txt"

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
have xz || { echo "xz is required to unpack the LORENE data set"; exit 1; }

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

echo "Fetching Einstein Toolkit BNS gallery artefacts into ${DEST}/"
echo "Upstream: ${BASE_URL}/"
echo "These are not redistributable -- ${DEST}/ is gitignored, keep it that way."
echo ""

mkdir -p "${DEST}"

fetch "${PAR_NAME}"   "${PAR_SHA}"   "${DEST}/${PAR_NAME}"
fetch "${TH_NAME}"    "${TH_SHA}"    "${DEST}/${TH_NAME}"
fetch "${ID_XZ_NAME}" "${ID_XZ_SHA}" "${DEST}/${ID_XZ_NAME}"

if [ -z "${FORCE}" ] && verify "${DEST}/${ID_NAME}" "${ID_SHA}"; then
  echo "  ${ID_NAME}: already unpacked and matching"
else
  echo "  ${ID_NAME}: unpacking"
  xz -dk -f "${DEST}/${ID_XZ_NAME}"
  if ! verify "${DEST}/${ID_NAME}" "${ID_SHA}"; then
    echo "  ${ID_NAME}: CHECKSUM MISMATCH after decompression"
    rm -f "${DEST}/${ID_NAME}"
    exit 1
  fi
  echo "  ${ID_NAME}: verified"
fi

MISSING=0
for f in "${PAR_NAME}" "${TH_NAME}" "${ID_NAME}"; do
  if [ -f "${DEST}/${f}" ]; then
    printf '  %-40s %10s bytes\n' "${f}" "$(stat -c%s "${DEST}/${f}")"
  else
    printf '  %-40s MISSING\n' "${f}"
    MISSING=1
  fi
done

if [ "${MISSING}" -ne 0 ]; then
  echo ""
  echo "Something expected is missing. Nothing was uploaded."
  exit 1
fi

if [ -n "${WANT_REFERENCE}" ]; then
  echo ""
  fetch "${REF_NAME}" "${REF_SHA}" "${DEST}/${REF_NAME}" "${REF_URL}"
  # The log, the parfile as run, and the notes. The 192 MB rho.xy.h5 and the
  # Psi4 multipole file stay in the archive; post-processing can extract
  # them when it wants a side-by-side, monitoring only compares info lines.
  echo "  ${REF_NAME}: extracting ${REF_LOG}, ${REF_PAR}, ${REF_NOTES}"
  tar xzf "${DEST}/${REF_NAME}" -C "${DEST}" "${REF_LOG}" "${REF_PAR}" "${REF_NOTES}"
  for f in "${REF_LOG}" "${REF_PAR}" "${REF_NOTES}"; do
    if [ ! -f "${DEST}/${f}" ]; then
      echo "  ${f}: MISSING from the archive"
      exit 1
    fi
    printf '  %-40s %10s bytes\n' "${f}" "$(stat -c%s "${DEST}/${f}")"
  done
fi

echo ""
echo "Ready. Next:  make upload-inputs"
