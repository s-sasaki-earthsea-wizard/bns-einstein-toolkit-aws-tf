#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Read evolution throughput out of a Cactus run log and turn it into hours and
# dollars.
#
# sec/iter is the number the whole cost model rests on, and until this script
# existed it was being eyeballed. The log offers two ways to get it:
#
#   Carpet's own reading.  Carpet::physical_time_per_hour is the second column
#     of the CarpetIOBasic info line, in M of simulation time per hour of wall
#     clock. It is the CUMULATIVE average since the process started -- not the
#     trailing window this script once took it for (#13). The windowed figure
#     is a different column (current_physical_time_per_hour) that reaches only
#     carpet-timing..asc, never the info line. A cumulative average does not
#     settle; it converges on the mean of everything so far, and after a rate
#     change it carries the old rate for the rest of the run. What it still
#     buys: it needs no clock in the log at all, which is why this script
#     works on runs that predate the line stamping.
#
#   The wall clock.  Runs from 2026-08-21 onwards carry an ISO timestamp on
#     every line, so the elapsed time between two info lines divides straight
#     into the iterations between them. This is the number the projection
#     uses: it covers whatever window is asked for, including the seconds a
#     checkpoint write stops every rank.
#
# The cross-check compares the two over the same span -- the whole segment,
# not the trimmed window -- because that is the only span over which they
# measure the same thing. They then disagree only if the rate changed during
# the run, which is worth knowing but is not an error in either reading. The
# previous version compared Carpet's since-start average against a windowed
# wall clock and told the reader to distrust the wall clock; on the first run
# whose rate actually changed (2026-08-26, the page cache drop) that advice
# pointed exactly the wrong way.
#
# A log is not necessarily one run. `run_name` decides where the sidecar
# syncs, so a recovered run restarted under the same name appends to the same
# cactus-stdout.log -- which is the point, because that is how a run reclaimed
# by spot continues. What it means here is that two consecutive info lines can
# be days apart with no node in between, and nothing in the arithmetic knows
# that. So the log is split on wall clock gaps and only the last segment is
# measured; --segment picks another.
#
# The window matters more than the arithmetic. Phase 2 of the simulation
# repository once read 30 sec/iter off iterations 32-36 of a run whose settled
# rate was 43, because the start of a run is dominated by things that happen
# once: the first AHFinderDirect search, the initial 2D output, the caches
# filling. --skip-minutes drops that head before anything is fitted.
#
# Usage:
#   scripts/read_throughput.sh [options] [log|s3://...]
#
#   With no log argument the current run's log is fetched from the bucket.
#
# Options:
#   --skip-minutes N   discard the first N minutes of evolution (default 15)
#   --target-time M    physical time to project to, in M (default 1750)
#   --usd-per-hour X   spot price used for the projection (default 2.978)
#   --window-from IT   start the window at iteration IT instead of by time
#   --gap-minutes N    wall clock gap that separates two runs (default 10)
#   --segment WHICH    which run in the log to measure: a number, "last"
#                      (default) or "all" to ignore the split entirely
#
# Examples:
#   scripts/read_throughput.sh
#   scripts/read_throughput.sh --target-time 2000 run/cactus-stdout.log
#   scripts/read_throughput.sh --usd-per-hour 3.05 s3://bucket/run/.../log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
TF="${TF:-terraform}"

SKIP_MINUTES=15
# The production end point, decided 2026-08-27 (see upload_inputs.sh for the
# physics). Override with --target-time for another one.
TARGET_TIME=1750
# us-west-2d, c7a.48xlarge, measured 2026-08-21. Override for another zone or
# a different instance type -- the projection is linear in it.
USD_PER_HOUR=2.978
WINDOW_FROM=""
# A gap longer than this, and far longer than the loop's own scale, means the
# node was not running. Ten minutes clears every legitimate pause by an order
# of magnitude: the 85.7 GB checkpoint write stops every rank for about 76
# seconds, and the worst non-checkpoint stall measured is 91.
GAP_MINUTES=10
SEGMENT=last
SOURCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-minutes) SKIP_MINUTES="$2"; shift 2 ;;
    --target-time)  TARGET_TIME="$2";  shift 2 ;;
    --usd-per-hour) USD_PER_HOUR="$2"; shift 2 ;;
    --window-from)  WINDOW_FROM="$2";  shift 2 ;;
    --gap-minutes)  GAP_MINUTES="$2";  shift 2 ;;
    --segment)      SEGMENT="$2";      shift 2 ;;
    -h|--help)      sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)             echo "unknown option: $1" >&2; exit 2 ;;
    *)              SOURCE="$1"; shift ;;
  esac
done

TMP=""
cleanup() { [ -n "${TMP}" ] && rm -f "${TMP}" || true; }
trap cleanup EXIT

# ------------------------------------------------------------------
# Locate the log
# ------------------------------------------------------------------
if [ -z "${SOURCE}" ]; then
  cd "${REPO_ROOT}"
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

echo "log            ${SOURCE}"
echo ""

# ------------------------------------------------------------------
# Parse
#
# Everything below is one pass. Timestamps are converted without mktime, which
# is a gawk extension -- the operator's machine may well have mawk, and the
# whole point of this script is that it runs anywhere the log can be read.
# ------------------------------------------------------------------
awk \
  -v skip_minutes="${SKIP_MINUTES}" \
  -v target_time="${TARGET_TIME}" \
  -v usd_per_hour="${USD_PER_HOUR}" \
  -v window_from="${WINDOW_FROM}" \
  -v gap_minutes="${GAP_MINUTES}" \
  -v segment="${SEGMENT}" \
  '
function isleap(y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

function iso2epoch(s,   y, mo, d, h, mi, se, days, i, md) {
  y  = substr(s,  1, 4) + 0; mo = substr(s,  6, 2) + 0; d  = substr(s,  9, 2) + 0
  h  = substr(s, 12, 2) + 0; mi = substr(s, 15, 2) + 0; se = substr(s, 18, 2) + 0
  days = 0
  for (i = 1970; i < y; i++) days += isleap(i) ? 366 : 365
  split("31 28 31 30 31 30 31 31 30 31 30 31", md, " ")
  for (i = 1; i < mo; i++) { days += md[i]; if (i == 2 && isleap(y)) days += 1 }
  days += d - 1
  return ((days * 24 + h) * 60 + mi) * 60 + se
}

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

function hms(sec,   h, m) {
  h = int(sec / 3600); m = int((sec - h * 3600) / 60)
  return sprintf("%dh %02dm", h, m)
}

BEGIN {
  n = 0; stamped = 0; unstamped = 0; import_total = 0; import_levels = 0
  nckpt = 0
}

{
  line = $0
  ts = -1
  # A stamped line is "[YYYY-MM-DDTHH:MM:SSZ] ..." -- 22 characters of prefix.
  if (substr(line, 1, 1) == "[" && substr(line, 22, 1) == "]") {
    ts = iso2epoch(substr(line, 2, 20))
    line = substr(line, 24)
    stamped++
  } else {
    unstamped++
  }

  # Initial data. One "Filling took" per refinement level; the sum is what an
  # interruption costs when IO::checkpoint_ID is not set.
  if (line ~ /KadathImporter.*Filling took/) {
    split(line, ft, "Filling took")
    import_total += ft[2] + 0
    import_levels++
  }

  if (line ~ /Dumping .* checkpoint at iteration/) {
    nckpt++
    ckpt_line[nckpt] = trim(line)
    ckpt_ts[nckpt] = ts
  }

  # CarpetIOBasic info line: "<it> <time> | <physical_time_per_hour> | ..."
  # The header carries the same shape with a non-numeric first field, and the
  # rule lines have no pipe at all.
  if (index(line, "|") == 0) next
  nf = split(line, f, "|")
  if (nf < 2) next
  head = trim(f[1])
  if (split(head, h2, /[ \t]+/) != 2) next
  if (h2[1] !~ /^[0-9]+$/) next
  if (h2[2] !~ /^[0-9]+(\.[0-9]+)?$/) next

  n++
  it[n] = h2[1] + 0
  pt[n] = h2[2] + 0
  ptph[n] = trim(f[2]) + 0
  wall[n] = ts
}

END {
  if (n < 2) {
    print "no evolution in this log: fewer than two CarpetIOBasic info lines."
    print "A memory probe or a run that died during the initial data import"
    print "will look like this."
    if (import_levels > 0)
      printf "initial data   %d levels, %.1f s total\n", import_levels, import_total
    exit 3
  }

  have_clock = (stamped > unstamped / 4)

  # ---------------- split the log into runs ----------------
  #
  # It cost a 12,746 USD projection to notice this, on 2026-08-26: the 4.8 day
  # gap between the 8/21 throughput probe and the 8/26 recovery test, both
  # written to the same log under the same run_name, showed up as a single
  # 413,603 second "stall" and pulled the mean to 462 sec/iter against a true
  # 3.75. The cross-check said the two readings disagreed and to trust the
  # wall clock, which was exactly backwards -- the wall clock was the one
  # counting time the node did not exist.
  #
  # A gap is a boundary only if it clears both an absolute floor and a large
  # multiple of the scale of the loop itself. The floor stops a slow regrid
  # from splitting a run; the multiple stops a legitimately slow run from
  # being split by its own checkpoint writes.
  nseg = 1; seg_lo[1] = 1
  if (have_clock) {
    k = 0
    for (i = 1; i < n; i++) {
      if (wall[i] <= 0 || wall[i + 1] <= 0) continue
      k++; g[k] = (wall[i + 1] - wall[i]) / (it[i + 1] - it[i])
    }
    if (k > 0) {
      for (i = 1; i < k; i++) for (j = i + 1; j <= k; j++) if (g[j] < g[i]) { t = g[i]; g[i] = g[j]; g[j] = t }
      scale = (k % 2) ? g[(k + 1) / 2] : (g[k / 2] + g[k / 2 + 1]) / 2
      cut = gap_minutes * 60
      if (scale * 20 > cut) cut = scale * 20
      for (i = 1; i < n; i++) {
        if (wall[i] <= 0 || wall[i + 1] <= 0) continue
        if (wall[i + 1] - wall[i] > cut) {
          seg_hi[nseg] = i
          nseg++; seg_lo[nseg] = i + 1; seg_gap[nseg] = wall[i + 1] - wall[i]
        }
      }
    }
  }
  seg_hi[nseg] = n

  if (segment == "all") {
    lo = 1; hi = n; seg_label = "all"
  } else if (segment == "" || segment == "last") {
    lo = seg_lo[nseg]; hi = seg_hi[nseg]; seg_label = sprintf("%d (the last)", nseg)
  } else {
    sn = segment + 0
    if (sn < 1 || sn > nseg) {
      printf "no segment %s in this log -- it holds %d.\n", segment, nseg
      exit 2
    }
    lo = seg_lo[sn]; hi = seg_hi[sn]; seg_label = sprintf("%d", sn)
  }

  # ---------------- initial data ----------------
  if (import_levels > 0)
    printf "initial data   %d levels imported, %.0f s (%.1f min) total\n", \
      import_levels, import_total, import_total / 60
  else
    print  "initial data   no Kadath import in this log (recovered from a checkpoint)"

  # ---------------- evolution extent ----------------
  dt = (pt[n] - pt[1]) / (it[n] - it[1])
  printf "evolution      iterations %d..%d, t = %.2f..%.2f M, dt = %.4f M\n", \
    it[1], it[n], pt[1], pt[n], dt
  printf "info lines     %d, %s\n", n, \
    have_clock ? "wall clock stamps present" : "NO wall clock stamps -- Carpet reading only"
  print ""

  # ---------------- more than one run in the log? ----------------
  if (nseg > 1) {
    printf "*** %d SEPARATE RUNS IN THIS LOG ***\n", nseg
    for (i = 1; i <= nseg; i++) {
      printf "    %d: iterations %d..%d, %d info lines", \
        i, it[seg_lo[i]], it[seg_hi[i]], seg_hi[i] - seg_lo[i] + 1
      if (i > 1) printf "   after a %s gap", hms(seg_gap[i])
      print ""
    }
    print "    The node did not exist across the gaps, so measuring the whole"
    print "    log measures the gaps. --segment N picks one, --segment all"
    print "    overrides this and measures the lot."
    printf "measuring      segment %s\n", seg_label
    print ""
  }

  # ---------------- pick the window ----------------
  start = lo
  if (window_from != "") {
    for (i = lo; i <= hi; i++) if (it[i] >= window_from + 0) { start = i; break }
    reason = sprintf("from iteration %d as asked", it[start])
  } else if (have_clock) {
    for (i = lo; i <= hi; i++)
      if (wall[i] > 0 && wall[i] - wall[lo] >= skip_minutes * 60) { start = i; break }
    if (start > lo)
      reason = sprintf("first %g minutes of evolution discarded", skip_minutes)
    else
      reason = sprintf("all of it -- shorter than the %g minute skip", skip_minutes)
  } else {
    # No clock: fall back to a fixed number of iterations. 64 is what the
    # dx=28 run needed before its reading stopped climbing.
    for (i = lo; i <= hi; i++) if (it[i] >= it[lo] + 64) { start = i; break }
    if (start > lo)
      reason = "first 64 iterations discarded (no clock to measure minutes with)"
    else
      reason = "all of it -- fewer than the 64 iterations usually discarded"
  }
  if (start >= hi) { start = lo; reason = reason " -- log too short, using all of it" }

  printf "window         iterations %d..%d (%s)\n", it[start], it[hi], reason
  window_span = (have_clock && wall[start] > 0 && wall[hi] > 0) ? wall[hi] - wall[start] : -1
  if (window_span >= 0)
    printf "               %s of wall clock\n", hms(window_span)

  # Is the window long enough to mean anything?
  #
  # The first minutes of evolution are dominated by things that happen once
  # -- the first AHFinderDirect search, the initial 2D output, caches
  # filling -- so anything under 20 minutes is still reporting the start-up
  # transient. Unclocked, iterations are the only proxy: the dx=28 run needed
  # about 64 before its rate stopped climbing, so 256 is a fair margin.
  #
  # This guard is here because the mistake has already been made twice. The
  # simulation repository read 30 sec/iter off iterations 32-36 of a run whose
  # settled rate was 43, and the 2026-08-20 memory probe stopped at iteration
  # 4 -- from which this script will still happily compute a number to the
  # nearest dollar if nothing stops it.
  settled = 1
  if (window_span >= 0) {
    if (window_span < 20 * 60) { settled = 0; why = sprintf("%s of wall clock, against the 20 min the start-up transient needs to wash out", hms(window_span)) }
  } else if (it[hi] - it[start] < 256) {
    settled = 0; why = sprintf("%d iterations, against the 256 a rate needs to stop climbing", it[hi] - it[start])
  }
  if (!settled) {
    print ""
    print "*** NOT SETTLED ***"
    printf "    %s.\n", why
    print "    Everything below is arithmetic on a start-up transient. Treat it"
    print "    as an order of magnitude and run the probe for longer."
  }
  print ""

  # ---------------- the Carpet reading ----------------
  # The last value, not a median over the window: this column is the
  # cumulative average since the process started (#13), so a median of it is
  # just the value from the middle of the run, and applying --skip-minutes to
  # it removes nothing the average does not still carry. The last value is
  # the one honest reading it offers: the run-to-date mean.
  carpet_mph = ptph[hi]
  if (carpet_mph > 0) {
    printf "Carpet         %.2f M/h run-to-date at the last info line (cumulative\n", carpet_mph
    printf "               average since the process started, so it lags any rate change)\n"
    printf "               = %.2f sec/iter at dt = %.4f M\n", dt * 3600 / carpet_mph, dt
  }

  # ---------------- the wall clock ----------------
  if (have_clock && wall[start] > 0 && wall[hi] > 0 && wall[hi] > wall[start]) {
    elapsed = wall[hi] - wall[start]
    iters = it[hi] - it[start]
    spi_all = elapsed / iters

    # Per-sample rates, so that the stop-the-world events can be separated
    # from the evolution loop. The median sample is the loop; the mean over
    # the whole window is what the run actually costs.
    k = 0
    for (i = start; i < hi; i++) {
      if (wall[i] <= 0 || wall[i + 1] <= 0) continue
      d = (wall[i + 1] - wall[i]) / (it[i + 1] - it[i])
      k++; r[k] = d
    }
    if (k > 0) {
      for (i = 1; i < k; i++) for (j = i + 1; j <= k; j++) if (r[j] < r[i]) { t = r[i]; r[i] = r[j]; r[j] = t }
      spi_med = (k % 2) ? r[(k + 1) / 2] : (r[k / 2] + r[k / 2 + 1]) / 2
    } else spi_med = spi_all

    printf "wall clock     %.2f sec/iter mean over the window (%d iterations in %s)\n", \
      spi_all, iters, hms(elapsed)
    printf "               %.2f sec/iter median sample -- the evolution loop alone\n", spi_med
    if (spi_med > 0)
      printf "               overhead outside the loop: %+.1f%%\n", (spi_all / spi_med - 1) * 100
    printf "               = %.2f M/h\n", dt * 3600 / spi_all

    # Same span on both sides: the Carpet average runs from its process start,
    # which is (approximately) the segment start, so the wall clock side must
    # cover the whole segment too -- not the trimmed window. Comparing a
    # since-start average against a windowed one is only valid while the rate
    # is constant, and a run whose rate changed is precisely the case worth
    # catching (#13).
    if (carpet_mph > 0 && wall[lo] > 0 && wall[hi] > wall[lo] && it[hi] > it[lo]) {
      spi_seg = (wall[hi] - wall[lo]) / (it[hi] - it[lo])
      disagree = (dt * 3600 / carpet_mph) / spi_seg
      printf "cross-check    Carpet run-to-date / wall clock over the whole segment = %.3f", disagree
      if (disagree < 0.9 || disagree > 1.1) {
        print ""
        print "               <- they disagree over the same span. Either the rate"
        print "                  changed during the run (a cumulative average carries"
        print "                  the old rate forever) or this segment does not start"
        print "                  where its process did. The windowed wall clock figure"
        print "                  above is the one to project from."
      } else
        print "  (consistent)"
    }
    spi = spi_all
  } else if (carpet_mph > 0) {
    # No clock in the log, so the run-to-date average is all there is. Fine
    # on a steady run; on one whose rate changed it smears the change over
    # everything before it.
    spi = dt * 3600 / carpet_mph
  } else {
    print "nothing usable in this log."
    exit 3
  }

  # ---------------- stalls ----------------
  if (have_clock) {
    print ""
    printf "stalls over %.0f sec/iter (three times the median sample):\n", spi_med * 3
    found = 0
    for (i = start; i < hi; i++) {
      if (wall[i] <= 0 || wall[i + 1] <= 0) continue
      d = (wall[i + 1] - wall[i]) / (it[i + 1] - it[i])
      if (d > spi_med * 3) {
        found++
        printf "  iterations %d..%d  %.0f s  (%.1f sec/iter)\n", \
          it[i], it[i + 1], wall[i + 1] - wall[i], d
      }
    }
    if (!found) print "  none"
  }

  if (nckpt > 0) {
    print ""
    print "checkpoints written:"
    for (i = 1; i <= nckpt; i++) print "  " ckpt_line[i]
  }

  # ---------------- projection ----------------
  print ""
  print "----------------------------------------------------------------"
  remaining_iters = (target_time - pt[hi]) / dt
  if (remaining_iters < 0) remaining_iters = 0
  total_iters = target_time / dt
  total_h = total_iters * spi / 3600
  printf "projection to t = %g M at %.2f sec/iter%s\n", target_time, spi, \
    settled ? "" : "  [NOT SETTLED -- see above]"
  printf "  %.0f iterations from t = 0, %.1f h of evolution, %.0f USD at %.3f USD/h\n", \
    total_iters, total_h, total_h * usd_per_hour, usd_per_hour
  printf "  still to run from t = %.1f M: %.1f h, %.0f USD\n", \
    pt[hi], remaining_iters * spi / 3600, remaining_iters * spi / 3600 * usd_per_hour
  print ""
  print "Add the initial data import once, and whatever the merger costs above"
  print "the inspiral -- this projection is linear in a rate measured before it."
}
' "${LOG}"
