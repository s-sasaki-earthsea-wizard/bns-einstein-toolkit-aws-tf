#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Syota Sasaki
#
# Guard for a public repository: fail if any git-tracked file contains an AWS
# account id, an ARN, an access key id or a real bucket name.
#
# Hiding the account id is defence in depth, not a security boundary -- an
# account id is not a credential and knowing it grants nothing. The boundary
# is IAM. This check exists so that a stray `terraform output` paste or an
# accidentally committed tfvars is caught before it is pushed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
cd "${REPO_ROOT}"

if git rev-parse --git-dir >/dev/null 2>&1 && [ -n "$(git ls-files)" ]; then
  mapfile -t FILES < <(git ls-files)
else
  mapfile -t FILES < <(find . \( -name .git -o -name .terraform \) -prune -o -type f -print)
fi

# .terraform.lock.hcl holds SHA-256 provider checksums. Hex digests contain
# runs of twelve digits by chance, which is indistinguishable from an account
# id to a regex -- and the file carries no account data, so skip it.
FILTERED=()
for f in "${FILES[@]}"; do
  case "${f}" in
    *.terraform.lock.hcl) continue ;;
  esac
  FILTERED+=("${f}")
done
FILES=("${FILTERED[@]}")

[ "${#FILES[@]}" -eq 0 ] && { echo "no files to scan"; exit 0; }

status=0

report() {
  local label="$1" pattern="$2"
  local hits
  hits="$(grep -nEI "${pattern}" "${FILES[@]}" 2>/dev/null || true)"
  if [ -n "${hits}" ]; then
    echo "FAIL: ${label}"
    echo "${hits}" | sed 's/^/  /'
    status=1
  fi
}

# A bare 12-digit run of digits is the account id shape. CHANGEME placeholders
# and the example files are expected to be clean, so no allowlist is needed.
report "possible AWS account id (12 consecutive digits)" '(^|[^0-9])[0-9]{12}([^0-9]|$)'
report "AWS access key id"                              'AKIA[0-9A-Z]{16}'
report "AWS secret access key assignment"               'aws_secret_access_key[[:space:]]*='
report "hardcoded ARN"                                  'arn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:[0-9]{12}:'

if [ "${status}" -eq 0 ]; then
  echo "OK: no account identifiers found in ${#FILES[@]} tracked files"
fi

exit "${status}"
