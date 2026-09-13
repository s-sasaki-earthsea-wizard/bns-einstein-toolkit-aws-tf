#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Confirm that both alert topics still have a confirmed email subscriber.
#
# Why this needs checking at all. An SNS email subscription carries an
# unsubscribe link in every message it sends, and one click deletes it. The
# Terraform resource still exists afterwards, `terraform apply` reports no
# changes until the next refresh notices, and nothing anywhere says the alerts
# have stopped arriving. The failure surfaces the one time it matters: when a
# budget threshold is crossed and no mail comes.
#
# The alerts are an after-the-fact detector -- AWS billing data lags 8-24
# hours, so they cannot stop a runaway, and real-time containment comes from
# the spot price cap and the node terminating itself. That is the reason to
# keep them working rather than to shrug: they are the last net, not the first.
#
# Read-only. It lists subscriptions and creates nothing, so it is safe to run
# as often as is useful.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
cd "${REPO_ROOT}"

TF="${TF:-terraform}"

topic_arn() {
  ${TF} -chdir=stacks/foundation output -raw "$1" 2>/dev/null
}

OPS_ARN="$(topic_arn ops_sns_topic_arn)"
COST_ARN="$(topic_arn cost_sns_topic_arn)"

if [ -z "${OPS_ARN}" ] || [ -z "${COST_ARN}" ]; then
  echo "cannot read the topic ARNs from stacks/foundation."
  echo "Apply the foundation stack first, or check AWS_PROFILE is set:"
  echo "  make apply-foundation"
  exit 1
fi

# The cost topic is pinned to us-east-1 by the Budgets API while the ops topic
# lives with the compute, so the region comes out of each ARN rather than the
# environment.
region_of() { cut -d: -f4 <<<"$1"; }

status=0

check() {
  local label="$1" arn="$2"
  local region subs sub endpoint state

  region="$(region_of "${arn}")"
  subs="$(aws sns list-subscriptions-by-topic \
    --region "${region}" --topic-arn "${arn}" \
    --query 'Subscriptions[?Protocol==`email`].[SubscriptionArn,Endpoint]' \
    --output text 2>/dev/null)"

  if [ -z "${subs}" ]; then
    printf '  %-12s %-10s  %-9s  %s\n' "${label}" "${region}" "MISSING" "no email subscription at all"
    status=1
    return
  fi

  sub="$(awk 'NR==1 {print $1}' <<<"${subs}")"
  endpoint="$(awk 'NR==1 {print $2}' <<<"${subs}")"

  case "${sub}" in
    *PendingConfirmation*)
      state="PENDING"
      status=1
      ;;
    *Deleted*)
      state="DELETED"
      status=1
      ;;
    arn:aws:sns:*)
      state="OK"
      ;;
    *)
      state="UNKNOWN"
      status=1
      ;;
  esac

  printf '  %-12s %-10s  %-9s  %s\n' "${label}" "${region}" "${state}" "${endpoint}"
}

echo "Alert subscriptions:"
printf '  %-12s %-10s  %-9s  %s\n' "TOPIC" "REGION" "STATE" "ENDPOINT"
check "ops"  "${OPS_ARN}"
check "cost" "${COST_ARN}"
echo ""

if [ "${status}" -ne 0 ]; then
  cat <<'MSG'
At least one topic cannot deliver.

  PENDING  the confirmation mail was never clicked. Look for "AWS
           Notification - Subscription Confirmation" and follow the
           "Confirm subscription" link -- not the unsubscribe link beneath it.
  DELETED  someone unsubscribed. Either follow the "Resubscribe" link in the
           deactivation mail, or let Terraform recreate the subscription:
             make apply-foundation
           which sends a fresh confirmation mail to click.
  MISSING  the subscription is not in the topic. Recreate it with
             make apply-foundation

Budget thresholds, Cost Anomaly Detection and spot interruption warnings all
arrive through these two topics and nowhere else.
MSG
else
  echo "Both topics can deliver."
fi

exit "${status}"
