#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Compare a live run against the published reference run, iteration by
# iteration, and report how far apart they are.
#
# WHY THIS IS POSSIBLE AT ALL
#
# The gallery ships the reference run bhns_20252103 -- the same dx = 19.2
# configuration, evolved to t = 3051 M on COSMA8 -- and its stdout carries the
# CarpetIOBasic info line every 4 iterations, in exactly the format our own
# cactus-stdout.log uses. So the comparison needs no extra output from the
# run, no extra compute, and no credentials beyond the read-only observer
# profile. Fetch it with:
#
#   make fetch-inputs ARGS=--reference
#
# WHY THERE ARE NO THRESHOLDS HERE
#
# "Is H max above 1e-3?" has no answer: the healthy value moves by four orders
# of magnitude over a run. "Is H max near what the reference had at this same
# t?" does, and the reference supplies the scale, so nothing has to be
# invented. Physics that legitimately changes -- the density spike at merger --
# changes in both and cancels in the comparison.
#
# This script therefore reports and never judges. Nothing here stops a run.
# The one automatic stop in the project is NaNChecker inside Cactus, which
# needs no threshold because a NaN is not a matter of degree.
#
# WHAT AGREEMENT LOOKS LIKE, MEASURED
#
# Over the 556 overlapping iterations of the 2026-08-21 throughput probe
# (t = 0-133 M, pure inspiral):
#
#   ILLINOISGRMHD::rho_b   max   relative difference 0 -- all printed digits
#   ML_ADMCONSTRAINTS::H   max   0
#   ML_ADMCONSTRAINTS::H   min   median 0, max 1.3e-3
#   HYDROBASE::w_lorentz   max   median 1.2e-3, max 1.5e-2
#
# Two runs on different hardware with different rank counts agreeing to the
# printed digits is not luck: these are min/max reductions, and a maximum does
# not depend on the order it was reduced in. The quantities that would drift
# with decomposition are sums, and none are on this line. w_lorentz is looser
# because its maximum sits in the artificial atmosphere, where tiny
# differences are amplified.
#
# THE LIMIT WORTH STATING
#
# That measurement covers pure inspiral. Past the merger at t ~ 713 M the two
# runs will genuinely diverge -- roundoff differences grow fastest exactly
# where the dynamics are most nonlinear, and the remnant disc is turbulent. A
# widening band there is expected and is not a fault. That is the second
# reason this script does not abort: any fixed rule would be wrong on one side
# of the merger.
#
# Read it as change detection. The band each quantity has been living in is
# printed alongside the most recent window, so a departure shows up as the
# recent window leaving the established band rather than as a number crossing
# a line somebody guessed.
#
# Usage:
#   scripts/validate_against_reference.sh [options] [log|s3://...]
#
#   With no log argument the current run log is fetched from the bucket.
#
# Options:
#   --reference FILE   reference run stdout (default upstream/bhns_20252103/…)
#   --recent N         samples in the recent window (default 64)
#
# Examples:
#   scripts/validate_against_reference.sh
#   AWS_PROFILE=gw230529-observer scripts/validate_against_reference.sh
#   scripts/validate_against_reference.sh run/cactus-stdout.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
TF="${TF:-terraform}"
SRC_DIR="${INPUTS_DIR:-upstream}"

REFERENCE="${SRC_DIR}/bhns_20252103/bhns_gw230529.out"
RECENT=64
SOURCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --reference) REFERENCE="$2"; shift 2 ;;
    --recent)    RECENT="$2";    shift 2 ;;
    -h|--help)   sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          echo "unknown option: $1" >&2; exit 2 ;;
    *)           SOURCE="$1"; shift ;;
  esac
done

cd "${REPO_ROOT}"

if [ ! -f "${REFERENCE}" ]; then
  echo "no reference run log at ${REFERENCE}" >&2
  echo "" >&2
  echo "Fetch it with:  make fetch-inputs ARGS=--reference" >&2
  echo "It is 573 MB for a 4.5 MB file, so it is not fetched by default." >&2
  echo "If the simulation repository is checked out beside this one, copying" >&2
  echo "its upstream/bhns_20252103.tar.gz into ${SRC_DIR}/ first skips the" >&2
  echo "download." >&2
  exit 1
fi

TMP=""
cleanup() { [ -n "${TMP}" ] && rm -f "${TMP}" || true; }
trap cleanup EXIT

if [ -z "${SOURCE}" ]; then
  SOURCE="$(${TF} -chdir=stacks/compute output -raw run_log_url 2>/dev/null || true)"
  if [ -z "${SOURCE}" ]; then
    echo "no log given and the compute stack's run_log_url could not be read." >&2
    echo "Is there a session? Try: eval \"\$(make login)\", or" >&2
    echo "AWS_PROFILE=gw230529-observer in a shell with no operator session." >&2
    echo "Or pass a path or an s3:// URL directly." >&2
    exit 1
  fi
fi

case "${SOURCE}" in
  s3://*)
    TMP="$(mktemp)"
    if ! aws s3 cp "${SOURCE}" "${TMP}" --only-show-errors; then
      echo "could not fetch ${SOURCE}" >&2
      echo "A run that has not reached its first sync has nothing there yet." >&2
      exit 1
    fi
    LOG="${TMP}"
    ;;
  *)
    LOG="${SOURCE}"
    [ -f "${LOG}" ] || { echo "no such log: ${LOG}" >&2; exit 1; }
    ;;
esac

echo "run            ${SOURCE}"
echo "reference      ${REFERENCE}"
echo ""

# The reference is read first, the run second, so FNR==NR separates them.
awk -v recent="${RECENT}" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# One CarpetIOBasic info line -> iteration, physical time, and the four
# extrema worth comparing. Returns 0 for anything else, including the two
# header rows, whose first field is not numeric.
#
# rho_b minimum and w_lorentz minimum are deliberately skipped: both sit
# pinned at their floor (1e-10 and 1.0) for the whole run and carry no signal.
function parse(line,   nf, f, head, h2) {
  if (index(line, "|") == 0) return 0
  nf = split(line, f, "|")
  if (nf < 5) return 0
  head = trim(f[1])
  if (split(head, h2, /[ \t]+/) != 2) return 0
  if (h2[1] !~ /^[0-9]+$/) return 0
  if (h2[2] !~ /^[0-9]+(\.[0-9]+)?$/) return 0
  P_it = h2[1] + 0
  P_t  = h2[2] + 0
  split(trim(f[3]), wl, /[ \t]+/); P_v[1] = wl[2] + 0
  split(trim(f[4]), rb, /[ \t]+/); P_v[2] = rb[2] + 0
  split(trim(f[5]), hc, /[ \t]+/); P_v[3] = hc[1] + 0; P_v[4] = hc[2] + 0
  return 1
}

# A stamped line is "[YYYY-MM-DDTHH:MM:SSZ] ..." -- 22 characters of prefix.
# The reference has none; our own log has carried them since 2026-08-21.
function strip(line) {
  if (substr(line, 1, 1) == "[" && substr(line, 22, 1) == "]") return substr(line, 24)
  return line
}

BEGIN {
  name[1] = "w_lorentz max"; name[2] = "rho_b     max"
  name[3] = "H         min"; name[4] = "H         max"
  nq = 4
}

# ---- the reference ----
FNR == NR {
  if (parse(strip($0))) { for (q = 1; q <= nq; q++) ref[P_it, q] = P_v[q]; refseen[P_it] = 1 }
  next
}

# ---- the run ----
{
  if (!parse(strip($0))) next
  # Later occurrences overwrite earlier ones on purpose: a recovered run
  # replays the checkpointed iteration, so the same it appears twice.
  for (q = 1; q <= nq; q++) run[P_it, q] = P_v[q]
  runt[P_it] = P_t
  if (!(P_it in runseen)) { runseen[P_it] = 1; order[++n] = P_it }
}

END {
  if (n == 0) {
    print "no CarpetIOBasic info lines in the run log yet."
    print "A run that has not started evolving looks like this."
    exit 3
  }

  # Sort the iterations we saw; awk gives no ordered iteration.
  for (i = 1; i < n; i++)
    for (j = i + 1; j <= n; j++)
      if (order[j] < order[i]) { t = order[i]; order[i] = order[j]; order[j] = t }

  # Overlap only. The run can be ahead of nothing -- the reference goes to
  # t = 3051 M, past any end point this project will pick -- but it can be
  # behind, and early iterations exist in both.
  m = 0
  for (i = 1; i <= n; i++) if (order[i] in refseen) { m++; ov[m] = order[i] }

  last_it = order[n]
  printf "run reached    iteration %d, t = %.2f M\n", last_it, runt[last_it]
  if (m == 0) {
    print "no overlap with the reference yet."
    exit 3
  }
  printf "overlap        iterations %d..%d, %d samples\n", ov[1], ov[m], m
  if (!(last_it in refseen))
    printf "               (the run is past the reference sample grid at this point)\n"
  print ""

  # The recent window is compared against everything before it, not against
  # the whole overlap. A subset can never exceed the maximum of the set that
  # contains it, so comparing recent against the total would be a check that
  # cannot fire.
  lo_recent = (m > recent) ? m - recent + 1 : 1
  nbase = lo_recent - 1

  printf "relative difference |run - ref| / |ref|\n\n"
  printf "  %-14s %10s %10s %10s   %10s %10s\n", \
    "", "median", "p90", "max", "recent med", "recent max"
  for (q = 1; q <= nq; q++) {
    k = 0; rk = 0; bk = 0
    for (i = 1; i <= m; i++) {
      it = ov[i]
      a = ref[it, q]; b = run[it, q]
      d = (a == 0) ? ((b == 0) ? 0 : 1) : (b - a) / a
      if (d < 0) d = -d
      # -0.0 compares equal to 0 and survives the negation above, and prints
      # as "-0.0e+00". Assigning the literal makes it positive zero.
      if (d == 0) d = 0
      k++; s[k] = d
      if (i >= lo_recent) { rk++; r[rk] = d } else { bk++; bs[bk] = d }
      if (d > worst[q]) { worst[q] = d; worst_it[q] = it }
    }
    for (i = 1; i < k; i++) for (j = i + 1; j <= k; j++) if (s[j] < s[i]) { t = s[i]; s[i] = s[j]; s[j] = t }
    for (i = 1; i < rk; i++) for (j = i + 1; j <= rk; j++) if (r[j] < r[i]) { t = r[i]; r[i] = r[j]; r[j] = t }
    for (i = 1; i < bk; i++) for (j = i + 1; j <= bk; j++) if (bs[j] < bs[i]) { t = bs[i]; bs[i] = bs[j]; bs[j] = t }
    med = (k % 2) ? s[(k + 1) / 2] : (s[k / 2] + s[k / 2 + 1]) / 2
    p90 = s[int(k * 0.9) + (int(k * 0.9) < k ? 1 : 0)]
    rmed = rk ? ((rk % 2) ? r[(rk + 1) / 2] : (r[rk / 2] + r[rk / 2 + 1]) / 2) : 0
    rmax = rk ? r[rk] : 0
    printf "  %-14s %10.1e %10.1e %10.1e   %10.1e %10.1e\n", \
      name[q], med, p90, s[k], rmed, rmax
    # The one criterion here, and it has no tunable in it: the TYPICAL recent
    # sample is worse than the WORST thing seen before the window. Anything
    # softer would need a factor somebody picked.
    hold[q] = (nbase > 0 && rmed > bs[bk]) ? 0 : 1
    basemax[q] = nbase > 0 ? bs[bk] : 0
    recmed[q] = rmed
  }

  printf "\n  whole overlap: %d samples   recent window: %d samples (iterations %d..%d)\n", \
    m, m - lo_recent + 1, ov[lo_recent], ov[m]
  if (nbase == 0)
    print "  (too short to compare a recent window against a baseline yet)"
  print ""

  departed = 0
  for (q = 1; q <= nq; q++) if (!hold[q]) departed++
  if (nbase == 0) {
    print "  Nothing to compare against yet -- the whole overlap IS the window."
  } else if (departed == 0) {
    print "  Every quantity is inside the band it held before this window."
  } else {
    print "  The median of the recent window exceeds the worst sample seen"
    print "  before it, for:"
    for (q = 1; q <= nq; q++)
      if (!hold[q])
        printf "    %s   recent median %.1e  vs  earlier max %.1e  (worst so far at iteration %d)\n", \
          name[q], recmed[q], basemax[q], worst_it[q]
    print ""
    print "  That is a statement about the samples, not a verdict. Past the"
    print "  merger at t ~ 713 M the two runs diverge for reasons that are not"
    print "  faults -- roundoff differences grow where the dynamics are"
    print "  nonlinear, and the remnant disc is turbulent. Before t ~ 713 M"
    print "  there is no such excuse and it is worth looking at."
  }
}
' "${REFERENCE}" "${LOG}"
