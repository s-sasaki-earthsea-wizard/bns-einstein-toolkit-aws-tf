#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Compare candidate AWS regions before pinning one in terraform.tfvars.
#
# The region choice is effectively permanent: ECR images and S3 objects are
# region-bound, so changing it later means re-pushing 5-8 GB and re-uploading
# every result. Three things decide it, and price is the least important:
#
#   1. Spot placement score -- can this region actually supply 192 vCPUs?
#      Scored 1-10; anything below 7 means expect repeated capacity failures.
#   2. Spot price history -- what the instance-hour actually costs.
#   3. Spot vCPU service quota -- a fresh account cannot launch 192 vCPUs
#      until this is raised, and the request takes hours to days to approve.
#
# Usage: scripts/region_scout.sh   (reads .env, or takes the defaults below)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

# Guarded with `if` rather than `&&`: under `set -e` a trailing `&&` whose
# left side is false makes the whole script exit.
if [ -f "${REPO_ROOT}/.env" ]; then
  # shellcheck source=/dev/null
  . "${REPO_ROOT}/.env"
fi

SCOUT_REGIONS="${SCOUT_REGIONS:-us-east-1 us-east-2 us-west-2}"
SCOUT_INSTANCE_TYPES="${SCOUT_INSTANCE_TYPES:-m7a.48xlarge c7a.48xlarge r7a.48xlarge}"
SCOUT_TARGET_VCPUS="${SCOUT_TARGET_VCPUS:-192}"

# The API region only routes the call; the scores cover every listed region.
API_REGION="${AWS_REGION:-us-east-1}"

read -r -a REGIONS <<< "${SCOUT_REGIONS}"
read -r -a TYPES <<< "${SCOUT_INSTANCE_TYPES}"

echo "==============================================================="
echo " Spot placement scores"
echo " target: ${SCOUT_TARGET_VCPUS} vCPU   types: ${SCOUT_INSTANCE_TYPES}"
echo " 10 = capacity almost certainly available, 1 = almost certainly not"
echo "==============================================================="
aws ec2 get-spot-placement-scores \
  --region "${API_REGION}" \
  --instance-types "${TYPES[@]}" \
  --target-capacity "${SCOUT_TARGET_VCPUS}" \
  --target-capacity-unit-type vcpu \
  --single-availability-zone \
  --region-names "${REGIONS[@]}" \
  --query 'SpotPlacementScores[].{Region:Region,AZ:AvailabilityZoneId,Score:Score}' \
  --output table

# Placement scores come back keyed by availability zone ID, spot prices by
# availability zone name, and the two cannot be joined without this mapping --
# zone names are shuffled per account, so us-west-2a is a different physical
# zone for a different account while usw2-az2 never moves.
echo
echo "==============================================================="
echo " Availability zone ID to name mapping (account specific)"
echo "==============================================================="
for region in "${REGIONS[@]}"; do
  echo "--- ${region} ---"
  aws ec2 describe-availability-zones \
    --region "${region}" \
    --query 'sort_by(AvailabilityZones, &ZoneId)[].{Id:ZoneId,Name:ZoneName}' \
    --output table
done

echo
echo "==============================================================="
echo " Most recent spot price per availability zone (USD/hour)"
echo "==============================================================="
START="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"

for region in "${REGIONS[@]}"; do
  for itype in "${TYPES[@]}"; do
    echo "--- ${region} / ${itype} ---"
    aws ec2 describe-spot-price-history \
      --region "${region}" \
      --instance-types "${itype}" \
      --product-descriptions "Linux/UNIX" \
      --start-time "${START}" \
      --query 'sort_by(SpotPriceHistory, &AvailabilityZone)[].{AZ:AvailabilityZone,Price:SpotPrice}' \
      --output table 2>/dev/null || echo "  not offered in this region"
  done
done

echo
echo "==============================================================="
echo " Spot vCPU service quota"
echo " L-34B43A08 = All Standard (A, C, D, H, I, M, R, T, Z)"
echo "              Spot Instance Requests"
echo "==============================================================="
for region in "${REGIONS[@]}"; do
  value="$(aws service-quotas get-service-quota \
    --region "${region}" \
    --service-code ec2 \
    --quota-code L-34B43A08 \
    --query 'Quota.Value' \
    --output text 2>/dev/null || echo 'unknown')"
  printf '  %-12s %s vCPU\n' "${region}" "${value}"
done

echo
echo "If the quota in the chosen region is below ${SCOUT_TARGET_VCPUS}, request an increase now:"
echo "  aws service-quotas request-service-quota-increase \\"
echo "    --region <region> --service-code ec2 --quota-code L-34B43A08 \\"
echo "    --desired-value ${SCOUT_TARGET_VCPUS}"
echo "Approval takes hours to days. Do it long before the Phase 5 run."
