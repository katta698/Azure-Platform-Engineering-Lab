#!/usr/bin/env bash
# Week 04 — check that vending produced a landing zone rather than a subscription.
#
# The distinction is the week. A subscription that exists, is billed and is
# empty is not a landing zone; it becomes one when it is placed, budgeted and
# granted. Each check below is one of those, read from Azure rather than from
# state, because state is a record of what Terraform believes it did.
#
#   1. the budget exists on every vended target, with both notifications
#   2. the role assignment exists, at subscription scope, with the right role
#   3. a newly vended subscription is placed in the intended management group
#   4. the placement is real inheritance, not a coincidence of naming
#   5. no drift

set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../terraform"

: "${TF_DATA_DIR:=C:/tfd/w04}"
export TF_DATA_DIR

# ── Refresh the CLI's subscription cache FIRST ──────────────────────────────
#
# A subscription vended minutes ago is invisible to `az` until this runs. The
# CLI answers from a locally cached account list built at login, so every query
# against the new subscription fails with:
#
#   Subscription '<guid>' not found. Check the spelling and casing and try again.
#
# which reads as 'vending did not work'. It did - Terraform created the budget
# and the role assignment inside it and returned their resource IDs. Measured
# 2026-09-11: three checks reported failure against resources that existed.
az account list --refresh -o none 2>/dev/null || true

STAGE=$(terraform output -raw stage 2>/dev/null || echo unknown)
EXISTING_ID=$(terraform output -raw config_target_subscription_id 2>/dev/null)
VENDED_ID=$(terraform output -raw vended_subscription_id 2>/dev/null || echo "")
TARGET_MG=$(terraform output -raw target_management_group 2>/dev/null || echo "")
LZ_NAME=$(grep '^landing_zone_name' terraform.tfvars 2>/dev/null | cut -d'"' -f2)
LZ_NAME="${LZ_NAME:-lz-vend-demo}"

if [[ -z "$EXISTING_ID" ]]; then
  echo "Could not read the Terraform outputs. Run deploy.sh first." >&2
  exit 1
fi

pass=0; fail=0
note() { echo "   $*"; }
ok()   { echo "   RESULT: $*"; pass=$((pass + 1)); }
bad()  { echo "   RESULT: $*"; fail=$((fail + 1)); }

echo "Stage: $STAGE"
echo ""

# ── 1. the budget ───────────────────────────────────────────────────────────
#
# `az consumption budget list` is queried per subscription. A budget is a
# Microsoft.Consumption resource, not a resource-group one, so it survives a
# resource group being deleted and has to be cleaned up explicitly.
echo "1. A budget exists on every vended target"
for pair in "existing:$EXISTING_ID" "vended:$VENDED_ID"; do
  key="${pair%%:*}"; sub="${pair#*:}"
  [[ -z "$sub" ]] && continue
  name="budget-${LZ_NAME}-${key}"
  amount=$(az consumption budget list --subscription "$sub" \
            --query "[?name=='$name'].amount | [0]" -o tsv 2>/dev/null | tr -d '\r')
  if [[ -n "$amount" && "$amount" != "None" ]]; then
    note "$key: $name = $amount"
    ok "budget present on the $key subscription"
  else
    note "$key: $name not found"
    bad "no budget on the $key subscription"
  fi
done
echo ""

# ── 2. the role assignment ──────────────────────────────────────────────────
#
# Queried at subscription scope, not with --all, because the question is
# whether the grant landed HERE. A grant inherited from a management group
# would answer "yes" to a sloppier query and would not be something vending
# did.
echo "2. The landing zone grant exists at subscription scope"
ROLE=$(grep '^role_assignment_definition' terraform.tfvars 2>/dev/null | cut -d'"' -f2)
ROLE="${ROLE:-Reader}"
for pair in "existing:$EXISTING_ID" "vended:$VENDED_ID"; do
  key="${pair%%:*}"; sub="${pair#*:}"
  [[ -z "$sub" ]] && continue
  n=$(az role assignment list --subscription "$sub" \
        --scope "/subscriptions/$sub" \
        --query "length([?roleDefinitionName=='$ROLE' && scope=='/subscriptions/$sub'])" \
        -o tsv 2>/dev/null | tr -d '\r')
  note "$key: $ROLE assignments at subscription scope: ${n:-0}"
  if [[ "${n:-0}" -ge 1 ]]; then
    ok "the grant is on the $key subscription itself"
  else
    bad "no $ROLE grant at subscription scope on $key"
  fi
done
echo ""

# ── 3 and 4. placement ──────────────────────────────────────────────────────
#
# Creation and placement are different calls, and a vending pipeline that does
# the first without the second produces a subscription that looks entirely
# healthy and inherits nothing. So placement is checked from the MANAGEMENT
# GROUP side: does the tree actually contain this subscription.
echo "3. A newly vended subscription is placed in the intended management group"
if [[ -z "$VENDED_ID" ]]; then
  note "no subscription was vended in this stage — run ./scripts/deploy.sh vend"
  note "SKIPPED"
else
  children=$(az account management-group show --name "$TARGET_MG" --expand \
               --query "children[?type=='/subscriptions'].name" -o tsv 2>/dev/null | tr -d '\r')
  if grep -qx "$VENDED_ID" <<< "$children"; then
    note "$TARGET_MG contains the vended subscription"
    ok "placed — the tree agrees, not just the plan"
  else
    note "$TARGET_MG does not list it. Children: $(tr '\n' ' ' <<< "$children")"
    bad "created but not placed — it is under the Tenant Root Group"
  fi

  echo ""
  echo "4. Placement is inheritance, checked from the subscription's own side"
  parent=$(az account management-group subscription show \
             --name "$TARGET_MG" --subscription "$VENDED_ID" \
             --query "parent.id" -o tsv 2>/dev/null | tr -d '\r' || echo "")
  note "parent reported: ${parent:-<none>}"
  if [[ -n "$parent" ]]; then
    ok "the association resolves from both directions"
  else
    bad "the subscription does not report a parent management group"
  fi
fi
echo ""

# ── 5. drift ────────────────────────────────────────────────────────────────
echo "5. The deployed state matches the configuration"
VEND_FLAG=$([[ -n "$VENDED_ID" ]] && echo true || echo false)
terraform plan -input=false -detailed-exitcode -no-color \
  -var="vend_new_subscription=$VEND_FLAG" >/dev/null 2>&1
case $? in
  0) ok "no drift" ;;
  2) bad "the plan proposes changes — the deployment does not match the code" ;;
  *) bad "the plan errored" ;;
esac
echo ""

echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
