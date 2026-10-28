#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Week 11 — validate.
#
#   ./scripts/validate.sh
#
# A successful apply proves nine resources exist. It proves nothing about
# whether a metric written on a VM reaches an Azure Monitor workspace, which
# is the whole claim.
#
# Two traps this script exists to avoid, both learned elsewhere in this lab:
#
#   * An empty query result is indistinguishable from a broken pipeline.
#     The role assignment needs ~30 minutes, so check 4 POLLS. Asking once and
#     concluding "remote_write does not work" is the week-08 mistake at six
#     times the duration.
#
#   * There is no inbound port on the VM. Everything that needs to look inside
#     it goes through `az vm run-command`, not SSH.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export MSYS_NO_PATHCONV=1

WEEK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$WEEK_DIR/terraform"
: "${TF_DATA_DIR:=C:/tfd/w11}"
export TF_DATA_DIR

cd "$TF_DIR"
SUB=$(grep -E '^subscription_id' terraform.tfvars | cut -d'"' -f2)

tfout() { terraform output -raw "$1" 2>/dev/null | tr -d '\r'; }

RG=$(tfout resource_group)
AMW_ID=$(tfout monitor_workspace_id)
QUERY_EP=$(tfout query_endpoint)
VM=$(tfout vm_name)
DCR_ID=$(tfout dcr_id)
IDENT_CLIENT=$(tfout identity_client_id)
GRAFANA=$(tfout grafana_endpoint)
RULEGRP=$(tfout rule_group_name)

if [ -z "$RG" ] || [ -z "$AMW_ID" ]; then
  echo "Could not read Terraform outputs. Run deploy.sh first." >&2
  exit 1
fi

PASS=0; FAIL=0
ok()  { echo "   PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "   FAIL  $1"; FAIL=$((FAIL+1)); }
note(){ echo "   $*"; }

echo "══════════════════════════════════════════════════════════════════════"
echo " Week 11 — self-managed Prometheus into Azure Monitor"
echo "══════════════════════════════════════════════════════════════════════"
echo ""

echo "── 1. the workspace exists, and is not a Log Analytics workspace ──"
# ARM returns Microsoft.Monitor/accounts with capitals. Comparing against a
# lowercase literal fails on a resource that is exactly right - the same
# shape as week 03's True/False bug, written by the same hand on the same day.
AMW_TYPE=$(az resource show --ids "$AMW_ID" --query type -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
AMW_TYPE_LC=$(printf '%s' "$AMW_TYPE" | tr 'A-Z' 'a-z')
note "resource type: ${AMW_TYPE:-?}"
if [ "$AMW_TYPE_LC" = "microsoft.monitor/accounts" ]; then
  ok "Microsoft.Monitor/accounts - a metrics store, queried with PromQL"
else
  bad "expected microsoft.monitor/accounts, got ${AMW_TYPE:-nothing}"
fi

echo ""
echo "── 2. the grant is on the DCR, not the subscription ──"
N_SUB=$(az role assignment list --assignee "$IDENT_CLIENT" --subscription "$SUB" \
          --query "length([?scope=='/subscriptions/$SUB'])" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
N_DCR=$(az role assignment list --assignee "$IDENT_CLIENT" --scope "$DCR_ID" \
          --query "length([?roleDefinitionName=='Monitoring Metrics Publisher'])" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
note "Monitoring Metrics Publisher on the DCR : ${N_DCR:-0}"
note "any assignment at subscription scope    : ${N_SUB:-0}"
if [ "${N_DCR:-0}" -ge 1 ] && [ "${N_SUB:-0}" = "0" ]; then
  ok "scoped to the rule that accepts the write, and nothing wider"
else
  bad "expected >=1 on the DCR and 0 at subscription scope"
fi

echo ""
echo "── 3. there is no secret on the VM, and no way in ──"
# The config file is rendered by Terraform; this reads the real one off the
# host. `az vm run-command` needs no inbound port.
CFG=$(az vm run-command invoke --resource-group "$RG" --name "$VM" --subscription "$SUB" \
        --command-id RunShellScript --scripts "cat /etc/prometheus/prometheus.yml" \
        --query "value[0].message" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
if grep -qiE "client_secret|password|certificate|BEGIN .*PRIVATE KEY" <<<"$CFG"; then
  bad "prometheus.yml contains something that looks like a credential"
else
  ok "prometheus.yml holds no secret - managed_identity names a client id only"
fi
N_IN=$(az network nsg rule list --resource-group "$RG" --subscription "$SUB" \
         --nsg-name "nsg-wk11-prometheus-dev-scus-001" \
         --query "length([?direction=='Inbound' && access=='Allow'])" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
note "inbound Allow rules on the NSG: ${N_IN:-?}"
if [ "${N_IN:-1}" = "0" ]; then
  ok "no inbound port is open at all"
else
  bad "${N_IN} inbound allow rule(s) - expected none"
fi

echo ""
echo "── 4. metrics written on the VM arrive in the workspace ──"
note "this is the one that waits. The role assignment needs ~30 minutes,"
note "and until it does the VM gets HTTP 403 and nothing lands."
TOKEN=$(az account get-access-token --resource "https://prometheus.monitor.azure.com" \
          --subscription "$SUB" --query accessToken -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
SAMPLES=0
for attempt in $(seq 1 40); do
  RESP=$(curl -sS --max-time 45 -H "Authorization: Bearer $TOKEN" \
           --get "$QUERY_EP/api/v1/query" --data-urlencode 'query=up{job="prometheus"}' 2>/dev/null) || RESP=""
  SAMPLES=$(python -c "
import sys,json
try:
    d=json.loads(sys.argv[1]); print(len(d.get('data',{}).get('result',[])))
except Exception: print(0)
" "$RESP" 2>/dev/null || echo 0)
  [ "${SAMPLES:-0}" -gt 0 ] && break
  echo "   attempt $attempt/40: 0 series - waiting for RBAC to propagate"
  sleep 60
done
note "series returned for up{job=\"prometheus\"}: ${SAMPLES:-0}"
if [ "${SAMPLES:-0}" -gt 0 ]; then
  ok "remote_write reached the workspace, authenticated by managed identity"
else
  bad "no series after ~40 minutes - check the VM's prometheus log"
fi

echo ""
echo "── 5. the rule group exists, and names no cluster ──"
RG_JSON=$(az resource show --resource-group "$RG" --subscription "$SUB" \
            --name "$RULEGRP" --resource-type "Microsoft.AlertsManagement/prometheusRuleGroups" \
            --query "properties" -o json --only-show-errors 2>/dev/null)
N_RULES=$(python -c "
import sys,json
try: print(len(json.loads(sys.argv[1]).get('rules',[])))
except Exception: print(0)
" "$RG_JSON" 2>/dev/null || echo 0)
HAS_CLUSTER=$(python -c "
import sys,json
try: print('yes' if json.loads(sys.argv[1]).get('clusterName') else 'no')
except Exception: print('?')
" "$RG_JSON" 2>/dev/null || echo '?')
note "rules in the group: ${N_RULES:-0}   clusterName set: ${HAS_CLUSTER}"
if [ "${N_RULES:-0}" -ge 2 ] && [ "$HAS_CLUSTER" = "no" ]; then
  ok "one recording rule and one alert rule, scoped to the workspace, no cluster"
else
  bad "expected >=2 rules and no clusterName"
fi

echo ""
echo "── 6. Grafana is wired to the workspace ──"
INTEG=$(az grafana show --name "amg-wk11-dev-scus-001" --resource-group "$RG" --subscription "$SUB" \
          --query "properties.grafanaIntegrations.azureMonitorWorkspaceIntegrations[].azureMonitorWorkspaceResourceId" \
          -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
note "integrated workspace: ${INTEG:-none}"
note "endpoint: ${GRAFANA:-?}"
if [ "$INTEG" = "$AMW_ID" ]; then
  ok "the data source points at this week's workspace"
else
  bad "Grafana is not integrated with the workspace"
fi

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " $PASS passed, $FAIL failed"
echo "══════════════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ] || exit 1
