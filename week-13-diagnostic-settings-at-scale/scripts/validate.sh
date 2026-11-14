#!/usr/bin/env bash
# Week 13 — did the policy actually turn logging on, and did logs arrive?
#
# Compliance says a diagnostic setting EXISTS. It does not say a log was ever
# written. The last check is the only one that asks the workspace.
#
# Usage:  bash week-13-diagnostic-settings-at-scale/scripts/validate.sh
set -uo pipefail

RG="rg-diagnostics-lab-dev-scus-001"
WS="law-wk13-dev-scus-001"
KV="kv-wk13-dev-scus-001"
TRIES=40
SLEEP=30

pass=0; fail=0
row() { printf "  %-50s %-22s %s\n" "$1" "$2" "$3"; }
ok()  { row "$1" "$2" "PASS"; pass=$((pass+1)); }
bad() { row "$1" "$2" "FAIL"; fail=$((fail+1)); }

SUB=$(az account show --query id -o tsv 2>/dev/null)
[ -z "$SUB" ] && { echo "not signed in"; exit 2; }

echo
echo "Week 13 validation — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  Test                                               Result"
echo "  -------------------------------------------------- ----------------------"

CID=$(az monitor log-analytics workspace show -g "$RG" -n "$WS" \
      --query customerId -o tsv 2>/dev/null | tr -d '\r')
[ -n "$CID" ] && ok "Workspace exists" "$WS" || { bad "Workspace exists" "missing"; exit 1; }

CAP=$(az monitor log-analytics workspace show -g "$RG" -n "$WS" \
      --query workspaceCapping.dailyQuotaGb -o tsv 2>/dev/null | tr -d '\r')
[ "$CAP" != "-1.0" ] && [ -n "$CAP" ] \
  && ok "Daily ingestion cap set" "${CAP} GB/day" \
  || bad "Daily ingestion cap set" "uncapped"

# ── the diagnostic settings the policy was supposed to create ───────────────
# Asked of each resource directly. The compliance dashboard is a separate
# system with its own refresh and is not evidence that a setting exists.
# az monitor diagnostic-settings list --resource fails with a usage error
# on CLI 2.86.0 even given a valid resource ID; the ARM API answers fine.
check_diag() {           # $1 resource id   $2 label   $3 expect yes|no
  n=$(az rest --method get --url \
      "https://management.azure.com$1/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview" \
      --query "length(value)" -o tsv 2>/dev/null | tr -d '\r')
  n=${n:-0}
  if [ "$3" = "yes" ]; then
    [ "$n" != "0" ] && ok "Diagnostic setting on $2" "$n setting(s)" \
                    || bad "Diagnostic setting on $2" "none — not remediated"
  else
    [ "$n" = "0" ] && ok "No setting on $2 (expected)" "0, by design" \
                   || bad "No setting on $2 (expected)" "$n — unexpected"
  fi
}

BASE="/subscriptions/$SUB/resourceGroups/$RG/providers"
check_diag "$BASE/Microsoft.KeyVault/vaults/$KV" "key vault" yes
check_diag "$BASE/Microsoft.Network/publicIPAddresses/pip-wk13-dev-scus-001" "public IP" yes
# audit does not cover network security groups; allLogs does. Not a failure.
check_diag "$BASE/Microsoft.Network/networkSecurityGroups/nsg-wk13-dev-scus-001" "NSG under audit" no
# no built-in policy exists for storage accounts at any category group.
check_diag "$BASE/Microsoft.Storage/storageAccounts/stwk13devscus001" "storage" no

# ── generate something to log, then prove it arrived ────────────────────────
echo
echo "  writing a secret to generate a Key Vault audit event..."
az keyvault secret set --vault-name "$KV" --name wk13-probe \
   --value "generated-by-validate" >/dev/null 2>&1
az keyvault secret show --vault-name "$KV" --name wk13-probe >/dev/null 2>&1

echo "  waiting for AuditEvent rows to reach the workspace..."
ROWS=0
for i in $(seq 1 $TRIES); do
  ROWS=$(az monitor log-analytics query -w "$CID" --analytics-query \
    "AzureDiagnostics | where ResourceProvider == 'MICROSOFT.KEYVAULT' | count" \
    -o tsv 2>/dev/null | head -1 | cut -f1 | tr -d '\r')
  [ -n "$ROWS" ] && [ "$ROWS" != "0" ] && break
  sleep $SLEEP
done

# THE check. Everything above proves configuration; only this proves data.
[ -n "$ROWS" ] && [ "$ROWS" != "0" ] \
  && ok "Logs actually arrived in the workspace" "$ROWS Key Vault row(s)" \
  || bad "Logs actually arrived in the workspace" "AzureDiagnostics empty"

echo
echo "  $pass passed / $fail failed"
echo
[ $fail -eq 0 ] || exit 1
