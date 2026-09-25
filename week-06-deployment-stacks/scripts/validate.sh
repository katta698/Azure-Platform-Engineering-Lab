#!/usr/bin/env bash
# Week 06 — try to delete both, and see which one Azure refuses.
#
#   1. the stack exists and reports its managed resources
#   2. the managed resources carry a denyStatus
#   3. deleting the CONTROL succeeds        - the baseline
#   4. deleting the PROTECTED one is REFUSED - the week's claim
#   5. the deny survives an Owner, not merely a Contributor
#
# Check 3 genuinely deletes something. That is the point: without it, "the
# protected one could not be deleted" has a second possible explanation - that
# the delete never worked for an unrelated reason. Terraform re-creates the
# control on the next apply.

set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

: "${TF_DATA_DIR:=C:/tfd/w06}"
export TF_DATA_DIR

STACK_NAME="stack-wk06-protected"
STACK_MG="mg-lz-dev"
SUB=$(grep '^subscription_id' terraform/terraform.tfvars | cut -d'"' -f2)
# Written by deploy.sh in THIS directory - both scripts cd to the week root.
# Reading scripts/... found nothing and reported "run deploy.sh first"
# against a deploy that had in fact succeeded.
PROTECTED_SA=$(cat .protected-storage-account 2>/dev/null | tr -d '\r\n')
PROTECTED_RG="rg-wk06-protected-dev-scus-001"
CONTROL_RG="rg-wk06-control-dev-scus-001"
CONTROL_SA=$(cd terraform && terraform output -raw control_storage_account 2>/dev/null | tr -d '\r')

pass=0; fail=0
note() { echo "   $*"; }
ok()   { echo "   RESULT: $*"; pass=$((pass + 1)); }
bad()  { echo "   RESULT: $*"; fail=$((fail + 1)); }

if [[ -z "$PROTECTED_SA" || -z "$CONTROL_SA" ]]; then
  echo "Could not resolve both storage accounts. Run deploy.sh first." >&2
  exit 1
fi

echo "control:   $CONTROL_SA   (Terraform, unprotected)"
echo "protected: $PROTECTED_SA   (deployment stack, denyWriteAndDelete)"
echo ""

# ── 1. the stack ────────────────────────────────────────────────────────────
echo "1. The stack exists at $STACK_MG and reports its managed resources"
n=$(az stack mg show --name "$STACK_NAME" --management-group-id "$STACK_MG" \
      --query "length(resources)" -o tsv 2>/dev/null | tr -d '\r')
mode=$(az stack mg show --name "$STACK_NAME" --management-group-id "$STACK_MG" \
      --query "denySettings.mode" -o tsv 2>/dev/null | tr -d '\r')
note "managed resources: ${n:-0}   denySettings.mode: ${mode:-<none>}"
if [[ "${n:-0}" -ge 1 && "$mode" == "denyWriteAndDelete" ]]; then
  ok "the stack is managing resources with deny settings on"
else
  bad "the stack is missing, empty, or has no deny settings"
fi
echo ""

# ── 2. denyStatus on the managed resources ──────────────────────────────────
#
# Read from the stack rather than from the resource. A resource does not know
# it is protected; the stack is what holds the deny assignment.
echo "2. The managed resources report a deny status"
az stack mg show --name "$STACK_NAME" --management-group-id "$STACK_MG" \
  --query "resources[].{status:status,deny:denyStatus}" -o tsv 2>/dev/null | tr -d '\r' \
  | while read -r st dn; do [[ -n "$st" ]] && note "status=$st  denyStatus=$dn"; done
denied=$(az stack mg show --name "$STACK_NAME" --management-group-id "$STACK_MG" \
  --query "length(resources[?denyStatus=='denyWriteAndDelete'])" -o tsv 2>/dev/null | tr -d '\r')
if [[ "${denied:-0}" -ge 1 ]]; then
  ok "$denied resource(s) carry denyWriteAndDelete"
else
  bad "no managed resource reports a deny status"
fi
echo ""

# ── 3. the control deletes ──────────────────────────────────────────────────
echo "3. Deleting the CONTROL storage account succeeds"
set +e
OUT=$(az storage account delete --name "$CONTROL_SA" --resource-group "$CONTROL_RG" \
        --subscription "$SUB" --yes 2>&1)
RC=$?
set -e
if [[ $RC -eq 0 ]]; then
  ok "deleted - an ordinary account, deletable by an Owner"
  note "terraform apply will re-create it"
else
  bad "the control could not be deleted, so check 4 proves nothing:"
  head -2 <<< "$OUT" | sed 's/^/     /'
fi
echo ""

# ── 4. the protected one does not ───────────────────────────────────────────
echo "4. Deleting the PROTECTED storage account is refused"
set +e
OUT=$(az storage account delete --name "$PROTECTED_SA" --resource-group "$PROTECTED_RG" \
        --subscription "$SUB" --yes 2>&1)
RC=$?
set -e
if [[ $RC -ne 0 ]] && grep -qiE 'RequestDisallowedByPolicy|denied|DenyAssignment|disallowed' <<< "$OUT"; then
  ok "REFUSED by the stack's deny assignment"
  grep -oiE '(RequestDisallowedByPolicy|DenyAssignment)[^"]{0,160}' <<< "$OUT" | head -1 | sed 's/^/     /'
elif [[ $RC -ne 0 ]]; then
  bad "refused, but not by a deny assignment - read before trusting it:"
  head -3 <<< "$OUT" | sed 's/^/     /'
else
  bad "NOT REFUSED. The protected account was deleted, which means the deny"
  bad "settings are not in force. Check the stack's scope before anything else."
fi
echo ""

# ── 5. who was doing the deleting ───────────────────────────────────────────
#
# Worth recording explicitly. "A delete was refused" is unremarkable if the
# caller lacked permission; it is the whole point if the caller is an Owner.
echo "5. The refusal applied to an Owner, not a limited principal"
ME=$(az ad signed-in-user show --query id -o tsv 2>/dev/null | tr -d '\r')
roles=$(az role assignment list --subscription "$SUB" --assignee "$ME" --include-inherited \
          --query "[].roleDefinitionName" -o tsv 2>/dev/null | tr -d '\r' | sort -u | tr '\n' ' ')
note "caller roles on the subscription: ${roles:-<none>}"
if grep -q "Owner" <<< "$roles"; then
  ok "the caller holds Owner and was still refused"
else
  bad "the caller is not an Owner, so the refusal is not evidence of much"
fi
echo ""

echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
