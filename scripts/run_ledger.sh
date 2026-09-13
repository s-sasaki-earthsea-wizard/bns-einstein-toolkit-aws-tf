#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Reconstruct what actually happened to a run: every node that served it, when
# each started and stopped, why it stopped, and how much of the elapsed wall
# clock was spent evolving rather than waiting.
#
# WHAT THIS IS FOR
#
# Spot capacity is bought at roughly a third of on-demand, and paid for in
# interruptions. Deciding whether that trade is worth taking again needs the
# price measured, not assumed, and the price is delay: the difference between
# how long the run took and how long it computed.
#
# Two ratios, and conflating them hides where the time went:
#
#   duty cycle       node uptime / wall clock span
#                    How much of the elapsed time a machine existed at all.
#                    What interruptions cost, plus however long it took
#                    somebody to notice and relaunch.
#
#   compute fraction evolution time / node uptime
#                    How much of a live node was evolving rather than
#                    booting, pulling the image, restoring 174 GB from S3 and
#                    reading a checkpoint. Roughly 13 minutes per start,
#                    measured 2026-08-27, so this is the term that punishes
#                    frequent short-lived nodes even when capacity is easy.
#
#   effective        evolution time / wall clock span -- the product of the
#                    two, and the number to compare against a run that was
#                    never interrupted.
#
# WHERE THE EVIDENCE COMES FROM
#
# logs/<run_name>/ holds one bootstrap log per instance (they carry the
# instance id since 2026-08-27; before that each node overwrote the last) and
# one ended-<instance>.json per instance that stopped in a way it could report.
#
#   started    first stamped line of the bootstrap log
#   evolution  first to last CarpetIOBasic info line in that log
#   ended      the marker object, written by the spot watcher on an
#              interruption notice and by section 8 on a clean exit
#
# A node with a bootstrap log and no marker is one of two things, and the
# bucket cannot tell them apart -- a node still running and a node that died a
# minute ago both leave a fresh last line. EC2 is asked instead: "running" if
# it says so, "vanished" otherwise, which covers both a node that went without
# the two minute notice and one the API has already forgotten. For a node with
# no marker the end is taken as the last line that reached S3, which
# understates uptime by up to one sync interval.
#
# Usage:
#   scripts/run_ledger.sh [options] [s3://bucket/logs/<run_name>/]
#
#   With no argument the current run is read from the compute stack.
#
# Options:
#   --keep DIR   keep the downloaded logs in DIR instead of a temp directory
#
# Examples:
#   scripts/run_ledger.sh
#   AWS_PROFILE=gw230529-observer scripts/run_ledger.sh
#   scripts/run_ledger.sh s3://gw230529-data-earthsea/logs/prod-dx19p2-1750m/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
TF="${TF:-terraform}"

KEEP=""
PREFIX=""

while [ $# -gt 0 ]; do
  case "$1" in
    --keep)    KEEP="$2"; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        echo "unknown option: $1" >&2; exit 2 ;;
    *)         PREFIX="$1"; shift ;;
  esac
done

cd "${REPO_ROOT}"

if [ -z "${PREFIX}" ]; then
  PREFIX="$(${TF} -chdir=stacks/compute output -raw log_prefix 2>/dev/null || true)"
  if [ -z "${PREFIX}" ]; then
    echo "no prefix given and the compute stack's log_prefix could not be read." >&2
    echo "Is there a session? Try: eval \"\$(make login)\", or" >&2
    echo "AWS_PROFILE=gw230529-observer in a shell with no operator session." >&2
    echo "Or pass an s3:// prefix directly." >&2
    exit 1
  fi
fi
case "${PREFIX}" in */) ;; *) PREFIX="${PREFIX}/" ;; esac

# Needed for the EC2 fallback below. The CLI would pick this up from the
# environment when .env is loaded, but this script is meant to run standalone
# under the observer profile too, and a missing region there would fail the
# describe and be read as "the node is gone".
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"

if [ -n "${KEEP}" ]; then
  DIR="${KEEP}"; mkdir -p "${DIR}"
else
  DIR="$(mktemp -d)"
  trap 'rm -rf "${DIR}"' EXIT
fi

echo "run logs       ${PREFIX}"
if ! aws s3 cp "${PREFIX}" "${DIR}/" --recursive --only-show-errors; then
  echo "could not read ${PREFIX}" >&2
  exit 1
fi

n_logs="$(find "${DIR}" -name 'bootstrap-*.log' | wc -l)"
if [ "${n_logs}" -eq 0 ]; then
  echo ""
  echo "no per-instance bootstrap logs there."
  echo "Runs before 2026-08-27 wrote a single bootstrap.log that each node"
  echo "overwrote, so their history cannot be reconstructed (issue #9)."
  exit 3
fi
echo ""

# Each bootstrap log yields three timestamps and an iteration range; each
# marker yields an end and a reason. awk joins them on the instance id.
for f in "${DIR}"/bootstrap-*.log; do
  iid="$(basename "${f}" .log)"; iid="${iid#bootstrap-}"
  marker="${DIR}/ended-${iid}.json"
  reason=""; ended=""
  if [ -f "${marker}" ]; then
    reason="$(sed -nE 's/.*"reason":"([^"]*)".*/\1/p' "${marker}")"
    ended="$(sed -nE 's/.*"ended":"([^"]*)".*/\1/p' "${marker}")"
  else
    # No marker. A fresh last log line cannot tell "still running" from "died
    # a minute ago" -- both look identical in the bucket, and guessing from
    # freshness called a terminated node "running" on 2026-08-27. Ask EC2,
    # which is authoritative while it still remembers the instance; a
    # terminated instance ages out of the API in about an hour, and by then
    # "not running" is the right answer anyway.
    err=""
    st="$(aws ec2 describe-instances --region "${REGION}" --instance-ids "${iid}" \
           --query 'Reservations[].Instances[].State.Name' --output text 2>"${DIR}/.err" || true)"
    err="$(cat "${DIR}/.err" 2>/dev/null || true)"
    case "${st}" in
      running|pending) reason="running" ;;
      "")
        # Not found means EC2 has forgotten it, which it does about an hour
        # after termination -- that is a real answer. Any other failure
        # (no region, no permission, throttling) is not, and must not be
        # reported as though the node had been checked.
        case "${err}" in
          *InvalidInstanceID.NotFound*) reason="vanished" ;;
          "")                           reason="vanished" ;;
          *)                            reason="unchecked" ;;
        esac
        ;;
      *) reason="vanished" ;;
    esac
  fi
  printf '%s\t%s\t%s\t%s\n' "${iid}" "${reason}" "${ended}" "${f}"
done | sort -t"$(printf '\t')" -k3 | awk -F'\t' '
function isleap(y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }
# ISO 8601 to epoch, without mktime -- a gawk extension the operator machine
# may not have. Any trailing zone offset is dropped: the node runs UTC and the
# stamps in the log are UTC by construction.
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
function hms(sec,   h, m) {
  if (sec < 0) return "  --   "
  h = int(sec / 3600); m = int((sec - h * 3600) / 60)
  return sprintf("%dh %02dm", h, m)
}
function stamp_of(line) {
  if (substr(line, 1, 1) == "[" && substr(line, 22, 1) == "]") return substr(line, 2, 20)
  return ""
}

{
  iid = $1; reason[iid] = $2; endstr = $3; f = $4
  order[++n] = iid
  marked[iid] = (endstr != "")

  first = ""; last = ""; ev_first = ""; ev_last = ""; it_first = ""; it_last = ""
  while ((getline line < f) > 0) {
    s = stamp_of(line)
    if (s == "") continue
    if (first == "") first = s
    last = s
    body = substr(line, 24)
    # A CarpetIOBasic info line: "<it> <time> | ..." with a numeric head.
    if (index(body, "|") == 0) continue
    split(body, fld, "|")
    head = fld[1]; sub(/^[ \t]+/, "", head); sub(/[ \t]+$/, "", head)
    if (split(head, h2, /[ \t]+/) != 2) continue
    if (h2[1] !~ /^[0-9]+$/ || h2[2] !~ /^[0-9]+(\.[0-9]+)?$/) continue
    if (ev_first == "") { ev_first = s; it_first = h2[1] }
    ev_last = s; it_last = h2[1]
  }
  close(f)

  start[iid] = iso2epoch(first)
  # A marker is authoritative; without one the last line that reached S3 is
  # the best available, and it understates uptime by up to a sync interval.
  fin[iid] = (endstr != "") ? iso2epoch(endstr) : iso2epoch(last)

  evs[iid] = (ev_first != "") ? iso2epoch(ev_first) : 0
  eve[iid] = (ev_last  != "") ? iso2epoch(ev_last)  : 0
  itf[iid] = it_first; itl[iid] = it_last
  fdisp[iid] = first
}

END {
  printf "%-21s %-20s %-20s %-17s %-14s %s\n", \
    "instance", "started (UTC)", "ended (UTC)", "reason", "iterations", "evolution"
  span_lo = 0; span_hi = 0; up = 0; ev = 0
  for (i = 1; i <= n; i++) {
    iid = order[i]
    if (reason[iid] == "running") live = 1
    e = (eve[iid] > evs[iid]) ? eve[iid] - evs[iid] : 0
    u = (fin[iid] > start[iid]) ? fin[iid] - start[iid] : 0
    up += u; ev += e
    if (span_lo == 0 || start[iid] < span_lo) span_lo = start[iid]
    if (fin[iid] > span_hi) span_hi = fin[iid]
    printf "%-21s %-20s %-20s %-17s %-14s %s\n", \
      iid, fdisp[iid], strftime_iso(fin[iid]), reason[iid], \
      (itf[iid] == "" ? "none" : itf[iid] ".." itl[iid]), hms(e)
  }

  span = span_hi - span_lo
  down = span - up
  print ""
  printf "  wall clock span    %-10s  first node started to last node ended\n", hms(span)
  printf "  node uptime        %-10s  %5.1f%% of span    (downtime %s)\n", \
    hms(up), span ? 100 * up / span : 0, hms(down)
  printf "  evolution          %-10s  %5.1f%% of uptime\n", \
    hms(ev), up ? 100 * ev / up : 0
  print ""
  printf "  effective compute  %5.1f%% of wall clock\n", span ? 100 * ev / span : 0
  if (live) {
    print "  A node is still running, so every total above is a snapshot."
    print ""
  }
  print "  Downtime is interruptions plus however long a relaunch waited."
  print "  The gap between uptime and evolution is what every start costs:"
  print "  boot, image pull, restore from S3, and reading the checkpoint."
}

# strftime is a gawk extension; format the epoch back by hand so this runs
# under mawk too.
function strftime_iso(e,   y, doy, md, mo, d, rem, h, mi, se) {
  if (e <= 0) return "-"
  y = 1970; doy = int(e / 86400); rem = e % 86400
  while (doy >= (isleap(y) ? 366 : 365)) { doy -= isleap(y) ? 366 : 365; y++ }
  split("31 28 31 30 31 30 31 31 30 31 30 31", md, " ")
  mo = 1
  while (1) {
    dim = md[mo] + ((mo == 2 && isleap(y)) ? 1 : 0)
    if (doy < dim) break
    doy -= dim; mo++
  }
  d = doy + 1; h = int(rem / 3600); mi = int((rem % 3600) / 60); se = rem % 60
  return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, mo, d, h, mi, se)
}
'
