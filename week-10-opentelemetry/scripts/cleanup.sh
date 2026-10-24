#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Week 10 — teardown
#
#   ./scripts/cleanup.sh
#
# Check the figures first — teardown is the only irreversible step in a week:
#   python scripts/check_figures_before_destroy.py week-10-opentelemetry
#
# What goes, and what must not:
#   GOES    the resource group, and with it the registry AND the images in it
#   STAYS   week 08's workspace, read through a data source, never owned here
#
# Deleting the registry deletes the images. That is intended - they are
# rebuildable from app/ with one command - but it is worth being explicit,
# because a registry is the one resource in this week that holds something a
# teardown cannot reconstruct if the source is ever lost.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

export MSYS_NO_PATHCONV=1
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors >/dev/null 2>&1 || true

WEEK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$WEEK_DIR/terraform"

cd "$TF_DIR"
SUB_LAB=$(grep -E '^subscription_id' terraform.tfvars | cut -d'"' -f2)
SUB_MGMT=$(grep -E '^management_subscription_id' terraform.tfvars | cut -d'"' -f2)
RG=$(terraform output -raw resource_group 2>/dev/null | tr -d '\r')
RG="${RG:-rg-tracing-lab-dev-scus-001}"

echo "══ about to destroy ══"
echo "   subscription : $SUB_LAB  (sub-lab-dev)"
echo "   resource grp : $RG"
echo "   NOT touched  : rg-observability-prod-scus-001 in sub-management (week 08)"
echo ""

echo "══ 1. what is there right now ══"
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
[ $rc -eq 0 ] || echo "   NOTE: destroy exited $rc — the group is already gone, so this is usually state catching up. Verified below regardless."

echo ""
echo "══ 4. verify against Azure, not against the exit codes above ══"
fail=0

n_rg=$(az group list --subscription "$SUB_LAB" --query "length([?name=='$RG'])" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
echo "   resource groups named $RG : ${n_rg:-?}"
[ "${n_rg:-1}" = "0" ] || fail=1

for t in "Microsoft.ContainerRegistry/registries" "Microsoft.App/managedEnvironments" "Microsoft.App/containerApps" "Microsoft.Insights/components"; do
  n=$(az resource list --subscription "$SUB_LAB" --query "length([?type=='$t'])" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
  printf "   %-44s %s\n" "$t" "${n:-?}"
  [ "${n:-1}" = "0" ] || fail=1
done

n_id=$(az identity list --subscription "$SUB_LAB" --query "length([?starts_with(name,'id-wk10')])" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
echo "   wk10 managed identities                      ${n_id:-?}"
[ "${n_id:-1}" = "0" ] || fail=1

# Week 08 is the lab's log sink and several weeks depend on it. A teardown
# that took it out would be the real failure here.
ws=$(az monitor log-analytics workspace show --subscription "$SUB_MGMT" \
       -g rg-observability-prod-scus-001 -n log-platform-prod-scus-001 \
       --query name -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
echo "   week 08's workspace still there              ${ws:-MISSING}"
[ -n "$ws" ] || fail=1

echo ""
if [ "$fail" -eq 0 ]; then
  echo "══ teardown verified clean ══"
else
  echo "══ TEARDOWN INCOMPLETE — something above is still running ══"
  exit 1
fi
