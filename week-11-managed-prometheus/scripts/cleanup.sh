#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Week 11 — teardown.
#
#   ./scripts/cleanup.sh
#
# Check the figures first — teardown is the only irreversible step in a week:
#   python scripts/check_figures_before_destroy.py week-11-managed-prometheus
#
# Three things here bill by the hour and none of them stops on its own:
#   * the Grafana instance   (~$0.082/hr if the 30-day trial does not apply)
#   * the VM                 (B2s, per hour)
#   * the public IP          (standard static, ~$0.005/hr)
#
# Week 05 is the reason this script does not trust an exit code. There, a
# destroy reported success while an Azure Firewall kept billing, and the check
# meant to catch it could not run. So this one counts what is left, by type,
# and says the number.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export MSYS_NO_PATHCONV=1

WEEK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$WEEK_DIR/terraform"
: "${TF_DATA_DIR:=C:/tfd/w11}"
export TF_DATA_DIR

cd "$TF_DIR"
SUB=$(grep -E '^subscription_id' terraform.tfvars | cut -d'"' -f2)
RG="rg-prometheus-lab-dev-scus-001"

echo "══ about to destroy ══"
echo "   subscription : $SUB  (sub-lab-dev)"
echo "   resource grp : $RG"
echo "   NOT touched  : week 08's Log Analytics workspace, which this week never used"
echo ""

echo "══ 1. what is there right now ══"
az resource list --resource-group "$RG" --subscription "$SUB" \
  --query "[].{name:name, type:type}" -o table --only-show-errors 2>/dev/null || echo "   (group not found)"
echo ""

echo "══ 2. terraform destroy ══"
terraform destroy -input=false -auto-approve
destroy_rc=$?
if [ "$destroy_rc" -ne 0 ]; then
  echo "" >&2
  echo "THE DESTROY FAILED. Grafana, the VM and the public IP may still be billing." >&2
  echo "Check, and delete directly if so:" >&2
  echo "  az resource list -g $RG --subscription $SUB -o table" >&2
  echo "  az group delete -n $RG --subscription $SUB --yes" >&2
fi
echo ""

echo "══ 3. verify against Azure, not against the exit code above ══"
fail=0

n_rg=$(az group list --subscription "$SUB" \
        --query "length([?name=='$RG'])" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
echo "   resource groups named $RG : ${n_rg:-?}"
[ "${n_rg:-1}" = "0" ] || fail=1

for pair in \
  "Microsoft.Dashboard/grafana:Grafana instances" \
  "Microsoft.Compute/virtualMachines:virtual machines" \
  "Microsoft.Network/publicIPAddresses:public IP addresses" \
  "Microsoft.Monitor/accounts:Azure Monitor workspaces" \
  "Microsoft.AlertsManagement/prometheusRuleGroups:Prometheus rule groups"
do
  t="${pair%%:*}"; label="${pair##*:}"
  n=$(az resource list --subscription "$SUB" \
        --query "length([?type=='$t'])" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
  printf "   %-34s : %s\n" "$label" "${n:-?}"
  [ "${n:-1}" = "0" ] || fail=1
done

# The identity is in the group and goes with it, but a role assignment naming
# a principal that no longer resolves is still a standing assignment. Week 02
# is where that lesson came from.
n_orphan=$(az role assignment list --all --subscription "$SUB" \
            --query "length([?principalName==null && roleDefinitionName=='Monitoring Metrics Publisher'])" \
            -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
echo "   orphaned Metrics Publisher grants  : ${n_orphan:-?}"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "   Clean - nothing billable from this week survives."
else
  echo "   SOMETHING SURVIVED. See the counts above." >&2
  exit 1
fi
