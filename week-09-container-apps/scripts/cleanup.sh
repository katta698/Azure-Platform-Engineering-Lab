#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Week 09 — teardown
#
#   ./scripts/cleanup.sh
#
# Teardown is the only irreversible step in a week, so check the figures first:
#
#   python scripts/check_figures_before_destroy.py week-09-container-apps
#
# Two rules this follows, both learned the expensive way:
#
#   Delete the resource GROUP first, then run terraform destroy. A name list
#   cannot know about anything a validation script created, and deleting the
#   group also catches whatever Terraform never managed.
#
#   Check the result against Azure, never against the command's exit code.
#   Week 05's teardown reported success while a firewall kept billing.
#
# This week touches NOTHING in sub-management. Week 08's workspace is read
# through a data source, so it is not in this week's state and cannot be
# destroyed by it - which is the point of reading it rather than owning it.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

export MSYS_NO_PATHCONV=1
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors >/dev/null 2>&1 || true

WEEK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$WEEK_DIR/terraform"

cd "$TF_DIR"
SUB_LAB=$(grep -E '^subscription_id' terraform.tfvars | cut -d'"' -f2)
RG=$(terraform output -raw resource_group 2>/dev/null | tr -d '\r')
RG="${RG:-rg-containerapps-lab-dev-scus-001}"

echo "══ about to destroy ══"
echo "   subscription : $SUB_LAB  (sub-lab-dev)"
echo "   resource grp : $RG"
echo "   NOT touched  : rg-observability-prod-scus-001 in sub-management (week 08)"
echo ""

echo "══ 1. what is actually there right now ══"
az resource list --subscription "$SUB_LAB" -g "$RG" \
  --query "[].{name:name,type:type}" -o table --only-show-errors 2>/dev/null \
  || echo "   (resource group already gone)"

echo ""
echo "══ 2. delete the resource group ══"
if az group show --name "$RG" --subscription "$SUB_LAB" --only-show-errors >/dev/null 2>&1; then
  az group delete --name "$RG" --subscription "$SUB_LAB" --yes --only-show-errors
  echo "   deleted $RG"
else
  echo "   $RG does not exist, nothing to delete"
fi

echo ""
echo "══ 3. terraform destroy, to clear the state ══"
set +e
terraform destroy -input=false -auto-approve
rc=$?
set -e
[ $rc -eq 0 ] || echo "   NOTE: destroy exited $rc — the group is already deleted, so this is usually state catching up. Verified below regardless."

echo ""
echo "══ 4. verify against Azure, not against the exit codes above ══"
fail=0

n_rg=$(az group list --subscription "$SUB_LAB" --query "length([?name=='$RG'])" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
echo "   resource groups named $RG      : ${n_rg:-?}"
[ "${n_rg:-1}" = "0" ] || fail=1

n_env=$(az resource list --subscription "$SUB_LAB" \
          --query "length([?type=='Microsoft.App/managedEnvironments'])" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
echo "   Container Apps environments     : ${n_env:-?}"
[ "${n_env:-1}" = "0" ] || fail=1

n_app=$(az resource list --subscription "$SUB_LAB" \
          --query "length([?type=='Microsoft.App/containerApps'])" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
echo "   container apps                  : ${n_app:-?}"
[ "${n_app:-1}" = "0" ] || fail=1

n_id=$(az identity list --subscription "$SUB_LAB" \
         --query "length([?starts_with(name,'id-wk09')])" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
echo "   wk09 managed identities         : ${n_id:-?}"
[ "${n_id:-1}" = "0" ] || fail=1

# Week 08 must still be standing — it is the lab's log sink and other weeks
# depend on it. A teardown that took it out would be the real failure here.
SUB_MGMT=$(grep -E '^management_subscription_id' terraform.tfvars | cut -d'"' -f2)
ws=$(az monitor log-analytics workspace show --subscription "$SUB_MGMT" \
       -g rg-observability-prod-scus-001 -n log-platform-prod-scus-001 \
       --query name -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
echo "   week 08's workspace still there : ${ws:-MISSING}"
[ -n "$ws" ] || fail=1

echo ""
if [ "$fail" -eq 0 ]; then
  echo "══ teardown verified clean ══"
else
  echo "══ TEARDOWN INCOMPLETE — something above is still running ══"
  exit 1
fi
