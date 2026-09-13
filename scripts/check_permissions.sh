#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Verify that the Terraform operator can perform every action the three stacks
# need, without creating anything.
#
# Two modes:
#   scripts/check_permissions.sh [principal-arn]
#       Simulate against a live IAM principal's attached policies.
#   scripts/check_permissions.sh --policy policies/terraform-operator.json
#       Simulate against a policy document that has not been attached yet.
#
# Every action is evaluated against a concrete resource ARN. This matters:
# a resource-scoped policy such as s3:* on arn:aws:s3:::gw230529-* evaluates
# as implicitDeny when simulated against the default wildcard resource, which
# reads as "no permission" when the permission is in fact present and correctly
# scoped. Simulating against "*" answers a different question from the one
# Terraform will ask.
#
# The Project tag is supplied as a context entry because provider default_tags
# stamps Project=gw230529 on every resource this project creates, and the
# operator policy uses that tag to fence off destructive EC2 actions.

set -euo pipefail

POLICY_FILE=""
PRINCIPAL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --policy) POLICY_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '3,25p' "$0"; exit 0 ;;
    *) PRINCIPAL="$1"; shift ;;
  esac
done

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [ -z "${ACCOUNT}" ]; then
  echo "ERROR: cannot resolve the AWS account id. Configure credentials first."
  exit 2
fi
REGION="${AWS_REGION:-us-west-2}"

POLICY_ARGS=()

if [ -n "${POLICY_FILE}" ]; then
  [ -f "${POLICY_FILE}" ] || { echo "no such policy file: ${POLICY_FILE}"; exit 2; }

  # simulate-custom-policy caps each document at 2000 characters, well under
  # the 6144 that IAM accepts for a real managed policy. Splitting the
  # statements across several documents in policyInputList is equivalent:
  # the simulator evaluates the list as though every document were attached.
  SPLIT_DIR="$(mktemp -d)"
  trap 'rm -rf "${SPLIT_DIR}"' EXIT

  jq -c '.Statement[]' "${POLICY_FILE}" > "${SPLIT_DIR}/statements"

  chunk=0
  : > "${SPLIT_DIR}/chunk.0"
  while IFS= read -r stmt; do
    current="$(cat "${SPLIT_DIR}/chunk.${chunk}")"
    candidate="${current:+${current},}${stmt}"
    if [ "${#candidate}" -gt 1700 ] && [ -n "${current}" ]; then
      chunk=$((chunk + 1))
      candidate="${stmt}"
    fi
    printf '%s' "${candidate}" > "${SPLIT_DIR}/chunk.${chunk}"
  done < "${SPLIT_DIR}/statements"

  # Passed as literal strings rather than file:// URIs: the CLI treats a
  # file:// argument to a list parameter as JSON to be parsed into the
  # parameter structure, and a compact policy document then fails as
  # "invalid content".
  for f in "${SPLIT_DIR}"/chunk.*; do
    POLICY_ARGS+=("$(printf '{"Version":"2012-10-17","Statement":[%s]}' "$(cat "${f}")")")
  done

  echo "Simulating policy document: ${POLICY_FILE}"
  echo "(split into ${#POLICY_ARGS[@]} documents for the 2000 character simulator limit)"
else
  if [ -z "${PRINCIPAL}" ]; then
    PRINCIPAL="$(aws sts get-caller-identity --query Arn --output text)"
  fi
  case "${PRINCIPAL}" in
    *:root)
      echo "ERROR: ${PRINCIPAL} is the account root user."
      echo "Root has no attached policies to simulate, and Terraform should not"
      echo "run as root -- IAM cannot bound it. Use an IAM user or role."
      exit 2
      ;;
  esac
  echo "Simulating principal: ${PRINCIPAL}"
fi
echo "Account ${ACCOUNT}, region ${REGION}"
echo

FAILED=0
TOTAL=0

# $1 group label, $2 resource ARN, rest: action names
simulate() {
  local group="$1" resource="$2"
  shift 2

  local result
  if [ -n "${POLICY_FILE}" ]; then
    result="$(aws iam simulate-custom-policy \
      --policy-input-list "${POLICY_ARGS[@]}" \
      --resource-arns "${resource}" \
      --context-entries 'ContextKeyName=aws:ResourceTag/Project,ContextKeyValues=gw230529,ContextKeyType=string' \
                        'ContextKeyName=ssm:resourceTag/Project,ContextKeyValues=gw230529,ContextKeyType=string' \
      --action-names "$@" \
      --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text)"
  else
    result="$(aws iam simulate-principal-policy \
      --policy-source-arn "${PRINCIPAL}" \
      --resource-arns "${resource}" \
      --context-entries 'ContextKeyName=aws:ResourceTag/Project,ContextKeyValues=gw230529,ContextKeyType=string' \
                        'ContextKeyName=ssm:resourceTag/Project,ContextKeyValues=gw230529,ContextKeyType=string' \
      --action-names "$@" \
      --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text)"
  fi

  local count denied n
  count="$(echo "${result}" | grep -c . || true)"
  TOTAL=$((TOTAL + count))
  denied="$(echo "${result}" | awk '$2 != "allowed" {print $1" ("$2")"}')"

  if [ -n "${denied}" ]; then
    n="$(echo "${denied}" | grep -c .)"
    FAILED=$((FAILED + n))
    printf '  %-22s DENIED (%s/%s)\n' "${group}" "${n}" "${count}"
    echo "${denied}" | sed 's/^/      /'
  else
    printf '  %-22s ok (%s)\n' "${group}" "${count}"
  fi
}

E="arn:aws:ec2:${REGION}:${ACCOUNT}"

echo "stacks/bootstrap"
simulate "state bucket" "arn:aws:s3:::gw230529-tfstate-probe" \
  s3:CreateBucket s3:PutBucketVersioning s3:PutEncryptionConfiguration \
  s3:PutBucketPublicAccessBlock s3:PutLifecycleConfiguration \
  s3:PutBucketOwnershipControls s3:PutBucketTagging s3:GetBucketLocation \
  s3:GetBucketVersioning s3:ListBucket s3:ListBucketVersions
simulate "state objects" "arn:aws:s3:::gw230529-tfstate-probe/foundation/terraform.tfstate" \
  s3:PutObject s3:GetObject s3:GetObjectVersion s3:DeleteObject

echo
echo "stacks/foundation"
simulate "vpc" "${E}:vpc/vpc-0123456789abcdef0" ec2:CreateVpc ec2:DeleteVpc ec2:CreateTags
simulate "subnet" "${E}:subnet/subnet-0123456789abcdef0" ec2:CreateSubnet ec2:DeleteSubnet
simulate "internet gateway" "${E}:internet-gateway/igw-0123456789abcdef0" \
  ec2:CreateInternetGateway ec2:AttachInternetGateway ec2:DetachInternetGateway ec2:DeleteInternetGateway
simulate "route table" "${E}:route-table/rtb-0123456789abcdef0" \
  ec2:CreateRouteTable ec2:CreateRoute ec2:AssociateRouteTable ec2:DeleteRouteTable
simulate "vpc endpoint" "${E}:vpc-endpoint/vpce-0123456789abcdef0" \
  ec2:CreateVpcEndpoint ec2:DeleteVpcEndpoints
simulate "security group" "${E}:security-group/sg-0123456789abcdef0" \
  ec2:CreateSecurityGroup ec2:AuthorizeSecurityGroupEgress ec2:DeleteSecurityGroup
simulate "data bucket" "arn:aws:s3:::gw230529-data-probe" \
  s3:CreateBucket s3:PutLifecycleConfiguration s3:PutBucketTagging s3:ListBucket
simulate "ecr repository" "arn:aws:ecr:${REGION}:${ACCOUNT}:repository/gw230529/einstein-toolkit" \
  ecr:CreateRepository ecr:PutLifecyclePolicy ecr:DescribeRepositories ecr:TagResource \
  ecr:InitiateLayerUpload ecr:UploadLayerPart ecr:CompleteLayerUpload ecr:PutImage \
  ecr:BatchCheckLayerAvailability ecr:PutImageScanningConfiguration ecr:DeleteRepository
simulate "ecr auth" "*" ecr:GetAuthorizationToken
simulate "iam role" "arn:aws:iam::${ACCOUNT}:role/gw230529-node" \
  iam:CreateRole iam:PutRolePolicy iam:AttachRolePolicy iam:GetRole iam:PassRole \
  iam:TagRole iam:DeleteRolePolicy iam:DetachRolePolicy iam:DeleteRole
simulate "iam instance profile" "arn:aws:iam::${ACCOUNT}:instance-profile/gw230529-node" \
  iam:CreateInstanceProfile iam:AddRoleToInstanceProfile iam:GetInstanceProfile \
  iam:TagInstanceProfile iam:RemoveRoleFromInstanceProfile iam:DeleteInstanceProfile
simulate "sns topics" "arn:aws:sns:${REGION}:${ACCOUNT}:gw230529-ops-alerts" \
  sns:CreateTopic sns:Subscribe sns:SetTopicAttributes sns:GetTopicAttributes \
  sns:TagResource sns:DeleteTopic
# budgets:ModifyBudget cannot share a simulator call with the other budget
# actions -- the API rejects the pair as requiring "different authorization
# information".
simulate "budgets" "arn:aws:budgets::${ACCOUNT}:budget/gw230529-01" \
  budgets:CreateBudget budgets:DescribeBudget budgets:DeleteBudget
simulate "budgets (modify)" "arn:aws:budgets::${ACCOUNT}:budget/gw230529-01" \
  budgets:ModifyBudget
simulate "cost anomaly" "*" \
  ce:CreateAnomalyMonitor ce:CreateAnomalySubscription ce:GetAnomalyMonitors \
  ce:TagResource ce:DeleteAnomalyMonitor ce:DeleteAnomalySubscription

echo
echo "stacks/compute"
simulate "ami parameter" "arn:aws:ssm:${REGION}::parameter/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  ssm:GetParameter ssm:GetParameters
simulate "launch template" "${E}:launch-template/lt-0123456789abcdef0" \
  ec2:CreateLaunchTemplate ec2:CreateLaunchTemplateVersion ec2:ModifyLaunchTemplate ec2:DeleteLaunchTemplate
simulate "instance" "${E}:instance/i-0123456789abcdef0" ec2:RunInstances ec2:TerminateInstances
simulate "ami (aws owned)" "arn:aws:ec2:${REGION}::image/ami-0123456789abcdef0" ec2:RunInstances
simulate "volume" "${E}:volume/vol-0123456789abcdef0" ec2:RunInstances ec2:DeleteVolume
simulate "eventbridge rule" "arn:aws:events:${REGION}:${ACCOUNT}:rule/gw230529-spot-interruption" \
  events:PutRule events:PutTargets events:DescribeRule events:TagResource \
  events:RemoveTargets events:DeleteRule
simulate "session manager" "*" \
  ssm:DescribeInstanceInformation ssm:StartSession ssm:TerminateSession
# ssm:SendCommand evaluates once against the document and once against the
# instance; the instance side carries the Project tag condition, satisfied by
# the ssm:resourceTag context entry above (#6).
simulate "send command (doc)" "arn:aws:ssm:${REGION}::document/AWS-RunShellScript" \
  ssm:SendCommand
simulate "send command (node)" "${E}:instance/i-0123456789abcdef0" \
  ssm:SendCommand
simulate "command results" "*" \
  ssm:GetCommandInvocation ssm:ListCommands ssm:ListCommandInvocations
simulate "node metrics" "*" \
  cloudwatch:GetMetricStatistics

echo
echo "read-only helpers"
simulate "describe / scout" "*" \
  ec2:DescribeAvailabilityZones ec2:DescribeInstances ec2:DescribeImages \
  ec2:DescribeLaunchTemplates ec2:DescribeLaunchTemplateVersions \
  ec2:DescribeSpotPriceHistory ec2:GetSpotPlacementScores \
  servicequotas:GetServiceQuota s3:ListAllMyBuckets

echo
echo "==============================================================="
if [ "${FAILED}" -eq 0 ]; then
  echo "OK: all ${TOTAL} actions permitted"
  exit 0
fi

echo "${FAILED} of ${TOTAL} actions denied"
echo "See policies/README.md for the expected policy set."
exit 1
