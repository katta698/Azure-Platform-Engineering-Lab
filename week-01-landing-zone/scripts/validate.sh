#!/usr/bin/env bash
# Week 01 — prove the guardrail does what it claims.
#
# Three attempts:
#   1. a NIC carrying a public IP
#   2. a resource in a region the policy does not allow
#   3. the compliant equivalent
#
# What counts as a pass depends on which stage is deployed, and hardcoding
# "these must be denied" makes this script lie in the most convincing way —
# reporting FAIL against a report-only assignment that is working perfectly.
#
#   report-only : nothing is blocked. All three SUCCEED, and the first two then
#                 appear as non-compliant. That is the point of the stage — you
#                 learn what would break before anything does.
#   enforcing   : the first two are rejected, the third still deploys.
#
# The third attempt is not padding. A rule that only ever blocks has been shown
# to be ON, not to be CORRECT. Proving the compliant path still works is the
# difference between a guardrail and an outage.

set -uo pipefail

# Git Bash (MSYS) rewrites any argument that looks like a Unix path into a
# Windows path before the program sees it. Every Azure resource ID starts with a
# slash, so a subnet ID arrives at az as
# `C:/Program Files/Git/subscriptions/...` and fails confusingly. Without this,
# nothing here that passes a resource ID works.
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../terraform"

RG="rg-wk01-landing-zone-dev-scus-001"
LOCATION="southcentralus"
SUBNET_ID=$(terraform output -raw test_subnet_id 2>/dev/null)
SUBSCRIPTION_ID=$(grep '^subscription_id' terraform.tfvars | cut -d'"' -f2)
STAGE=$(terraform output -raw enforcement 2>/dev/null || echo "unknown")

if [[ -z "$SUBNET_ID" ]]; then
  echo "Could not read the test subnet from Terraform outputs. Run deploy.sh first." >&2
  exit 1
fi

if [[ "$STAGE" == ENFORCING* ]]; then
  EXPECT_VIOLATION=deny
else
  EXPECT_VIOLATION=allow
fi

echo "Enforcement: $STAGE"
echo "Violations are expected to: $EXPECT_VIOLATION"
echo ""

pass=0
fail=0

# $1 label, $2 expectation (deny|allow), $3... command
attempt() {
  local label="$1" expect="$2"
  shift 2

  echo "── $label"
  echo "   expecting: $expect"

  local output rc
  output=$("$@" 2>&1)
  rc=$?

  local denied=1
  if grep -qiE 'RequestDisallowedByPolicy|disallowed by policy' <<<"$output"; then
    denied=0
  fi

  if [[ "$expect" == "deny" ]]; then
    if [[ $denied -eq 0 ]]; then
      echo "   RESULT: denied by policy — correct"
      # The message in the error is what a developer actually sees. It is the
      # thing worth screenshotting, because it is what makes a block actionable
      # rather than mysterious.
      grep -oE 'Denied by the lab baseline[^"]*' <<<"$output" | head -1 | sed 's/^/     /'
      pass=$((pass + 1))
    else
      echo "   RESULT: allowed — WRONG, the guardrail is not blocking"
      fail=$((fail + 1))
    fi
  else
    if [[ $rc -eq 0 ]]; then
      echo "   RESULT: created — correct"
      pass=$((pass + 1))
    else
      echo "   RESULT: FAILED — worse than a missing deny, the legitimate path is broken"
      tail -5 <<<"$output" | sed 's/^/     /'
      fail=$((fail + 1))
    fi
  fi
  echo ""
}

# The public IP resource itself is permitted. It is ATTACHING it to a NIC that
# the policy denies, so it has to exist before the real test.
az network public-ip create --resource-group "$RG" --name "pip-wk01-test" --subscription "$SUBSCRIPTION_ID" --sku Standard --allocation-method Static --location "$LOCATION" --tags managed-by=terraform week=01 env=dev -o none 2>/dev/null || true

# --location is required on a NIC. It is not inherited from the resource group,
# and omitting it fails with LocationRequired, which reads like a policy
# rejection and is not one.
attempt "NIC carrying a public IP" "$EXPECT_VIOLATION" \
  az network nic create --resource-group "$RG" --name "nic-wk01-noncompliant" --subscription "$SUBSCRIPTION_ID" --location "$LOCATION" --subnet "$SUBNET_ID" --public-ip-address "pip-wk01-test" --tags managed-by=terraform week=01 env=dev -o json

attempt "storage account in westeurope (not an allowed location)" "$EXPECT_VIOLATION" \
  az storage account create --resource-group "$RG" --name "stwk01ban${RANDOM}" --subscription "$SUBSCRIPTION_ID" --location westeurope --sku Standard_LRS --tags managed-by=terraform week=01 env=dev -o json

attempt "NIC with no public IP, in an allowed region" allow \
  az network nic create --resource-group "$RG" --name "nic-wk01-compliant" --subscription "$SUBSCRIPTION_ID" --location "$LOCATION" --subnet "$SUBNET_ID" --tags managed-by=terraform week=01 env=dev -o json

echo "── Compliance as Azure currently reports it"
az policy state summarize --resource-group "$RG" --subscription "$SUBSCRIPTION_ID" --query "value[0].results.{evaluated:resourceDetails[0].count, nonCompliant:nonCompliantResources}" -o yaml 2>/dev/null || echo "   no compliance data yet"
echo ""
echo "   Compliance is not immediate. Policy evaluates on resource write straight"
echo "   away — that is why a deny is instant — but the scan of EXISTING resources"
echo "   runs on its own schedule, up to 30 minutes. An empty report here means"
echo "   'not scanned yet', not 'compliant'. Force one with:"
echo "     az policy state trigger-scan --resource-group $RG --subscription <sub>"
echo ""

echo "$pass passed, $fail failed."
[[ $fail -eq 0 ]] || exit 1
