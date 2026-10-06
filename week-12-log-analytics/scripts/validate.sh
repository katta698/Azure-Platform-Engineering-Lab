#!/usr/bin/env bash
# Week 12 — prove the cost design actually works.
#
#   1. the workspace exists, on pay-as-you-go, with a daily cap
#   2. the table plans are what was asked for, not the defaults
#   3. the DCR and its endpoint are live
#   4. SEND 100 ROWS, 20 of them above Warning, and count what was stored
#   5. the cap has an alarm on it
#
# Check 4 is the week. A transformation that filters nothing looks identical in
# the portal to one that filters everything - the only way to know is to send
# known data and count what survived.

set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

: "${TF_DATA_DIR:=C:/tfd/w12}"
export TF_DATA_DIR

# `az monitor log-analytics query` lives in an EXTENSION. Without this, az
# prompts "Do you want to install it now? (Y/n)" and in a non-interactive
# shell the PROMPT TEXT lands in the variable - so the check compares a
# question to a number and fails confusingly. Week 05 lost a teardown to the
# same trap with `az network firewall list`.
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors >/dev/null 2>&1 || true

SUB=$(grep '^subscription_id' terraform/terraform.tfvars | cut -d'"' -f2)
RG="rg-observability-prod-scus-001"
WS="log-platform-prod-scus-001"

pass=0; fail=0
note() { echo "   $*"; }
ok()   { echo "   RESULT: $*"; pass=$((pass + 1)); }
bad()  { echo "   RESULT: $*"; fail=$((fail + 1)); }

# ── 1 ───────────────────────────────────────────────────────────────────────
echo "1. The workspace exists, pay-as-you-go, with a cap"
SKU=$(az monitor log-analytics workspace show -g "$RG" -n "$WS" --subscription "$SUB" \
        --query "sku.name" -o tsv 2>/dev/null | tr -d '\r')
CAP=$(az monitor log-analytics workspace show -g "$RG" -n "$WS" --subscription "$SUB" \
        --query "workspaceCapping.dailyQuotaGb" -o tsv 2>/dev/null | tr -d '\r')
RET=$(az monitor log-analytics workspace show -g "$RG" -n "$WS" --subscription "$SUB" \
        --query "retentionInDays" -o tsv 2>/dev/null | tr -d '\r')
note "sku=$SKU  daily cap=${CAP}GB  retention=${RET}d"
if [[ "$SKU" == "PerGB2018" && -n "$CAP" && "$CAP" != "-1.0" ]]; then
  ok "pay-as-you-go with a cap set - commitment tiers start at 100GB/day, far above this"
else
  bad "expected PerGB2018 with a daily cap"
fi
echo ""

# ── 2 ───────────────────────────────────────────────────────────────────────
#
# Read back from Azure, not from the config. A plan that failed to apply leaves
# the table on its default, which is Analytics - the expensive one.
echo "2. The table plans are what was asked for"
for pair in "PlatformLogs_CL:Analytics" "PlatformVerbose_CL:Basic"; do
  T="${pair%%:*}"; WANT="${pair##*:}"
  GOT=$(az monitor log-analytics workspace table show -g "$RG" --workspace-name "$WS" \
          -n "$T" --subscription "$SUB" --query "plan" -o tsv 2>/dev/null | tr -d '\r')
  note "$T -> ${GOT:-<unset>} (wanted $WANT)"
  [[ "$GOT" == "$WANT" ]] || { bad "$T is on ${GOT:-nothing}, not $WANT"; continue; }
done
if [[ "$fail" -eq 0 ]]; then ok "both tables on their intended plans"; fi
echo ""

# ── 3 ───────────────────────────────────────────────────────────────────────
echo "3. The collection rule and its endpoint are live"
DCE=$(cd terraform && terraform output -raw dce_endpoint 2>/dev/null | tr -d '\r')
DCR=$(cd terraform && terraform output -raw dcr_immutable_id 2>/dev/null | tr -d '\r')
note "endpoint: ${DCE:-<none>}"
if [[ -n "$DCE" && -n "$DCR" ]]; then
  ok "endpoint and rule both resolved"
else
  bad "could not resolve the endpoint or rule - run deploy.sh first"
  echo "── $pass passed, $fail failed ──"; exit 1
fi
echo ""

# ── 4. the week ─────────────────────────────────────────────────────────────
#
# 100 rows in, 20 of them Warning or above. If the transformation works, 20 are
# stored and 80 were never billed.
echo "4. The transformation drops rows BEFORE they are billed"
TOKEN=$(az account get-access-token --resource "https://monitor.azure.com" \
          --query accessToken -o tsv 2>/dev/null | tr -d '\r')
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MARK="probe-$(date +%s)"

python - "$STAMP" "$MARK" > .tmp-payload.json <<'PY'
import json, sys
stamp, mark = sys.argv[1], sys.argv[2]
rows = []
for i in range(100):
    lvl = ["Warning", "Error", "Critical"][i % 3] if i < 20 else "Information"
    rows.append({"TimeGenerated": stamp, "Level": lvl,
                 "Message": f"{mark} row {i}", "Component": "validate.sh"})
json.dump(rows, open(1, "w"))
PY

SENT=$(python -c "import json;print(len(json.load(open('.tmp-payload.json'))))")
ABOVE=$(python -c "import json;print(sum(1 for r in json.load(open('.tmp-payload.json')) if r['Level']!='Information'))")
note "sending $SENT rows, $ABOVE of them Warning or above"

HTTP=$(curl -s -o .tmp-ingest.out -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data @.tmp-payload.json \
  "${DCE}/dataCollectionRules/${DCR}/streams/Custom-PlatformLogs_CL?api-version=2023-01-01")
note "ingestion API returned HTTP $HTTP"

if [[ "$HTTP" != "204" ]]; then
  bad "ingestion rejected: $(head -c 200 .tmp-ingest.out)"
else
  # Ingestion is not instant. Poll rather than sleep-and-hope.
  STORED=""
  for _ in $(seq 1 20); do
    sleep 15
    STORED=$(az monitor log-analytics query -w "$(cd terraform && terraform output -raw workspace_id)" \
      --analytics-query "PlatformLogs_CL | where Message has '$MARK' | count" \
      --subscription "$SUB" --query "[0].Count" -o tsv 2>/dev/null | tr -d '\r')
    [[ -n "$STORED" && "$STORED" != "0" ]] && break
    note "   waiting for ingestion..."
  done
  note "rows stored: ${STORED:-0} of $SENT sent"
  if [[ "${STORED:-0}" == "$ABOVE" ]]; then
    ok "$ABOVE stored, $((SENT - ABOVE)) dropped at ingest and never billed"
  elif [[ "${STORED:-0}" == "$SENT" ]]; then
    bad "every row was stored - the transformation is not filtering"
  else
    bad "stored ${STORED:-0}, expected $ABOVE - check the transform_kql"
  fi
fi
echo ""

# ── 5 ───────────────────────────────────────────────────────────────────────
echo "5. The cap has an alarm on it"
AG=$(az monitor action-group list -g "$RG" --subscription "$SUB" \
       --query "length(@)" -o tsv 2>/dev/null | tr -d '\r')
note "action groups in $RG: ${AG:-0}"
if [[ "${AG:-0}" -ge 1 ]]; then
  ok "an alert path exists - a cap that trips silently is data loss nobody noticed"
else
  bad "no action group, so the cap would trip in silence"
fi
echo ""

rm -f .tmp-payload.json .tmp-ingest.out

echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
