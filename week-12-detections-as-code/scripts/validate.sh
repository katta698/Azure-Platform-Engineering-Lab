#!/usr/bin/env bash
# Week 12 — does the detection pipeline actually work?
#
# Six checks, and only two of them matter. The first four confirm things
# exist, which Terraform already told us. Checks 5 and 6 are the week:
#
#   5  the POSITIVE control fired   -- a real event became an incident
#   6  the NEGATIVE control is silent -- it fired because of what it matched
#
# Either alone proves nothing. A rule that fires on a true positive might
# fire on anything. A rule silent on a true negative might simply be broken.
# Only the pair is evidence, which is why this script fails if 6 is noisy
# even when 5 passes.
#
# Usage:  bash week-12-detections-as-code/scripts/validate.sh
set -uo pipefail

RG="rg-detections-lab-dev-scus-001"
WS="law-wk12-dev-scus-001"
RULE_POS="Role assignment created"
RULE_NEG="Policy assignment deleted"

# Ingestion is not instant and the rule runs every 5 minutes, so a single
# assertion here would be measuring luck. 40 x 30s = 20 minutes, which is
# comfortably past the Activity-log delay observed in this lab.
TRIES=40
SLEEP=30

pass=0; fail=0
row() { printf "  %-46s %-26s %s\n" "$1" "$2" "$3"; }
ok()   { row "$1" "$2" "PASS"; pass=$((pass+1)); }
bad()  { row "$1" "$2" "FAIL"; fail=$((fail+1)); }

SUB=$(az account show --query id -o tsv 2>/dev/null)
if [ -z "$SUB" ]; then echo "not signed in to Azure"; exit 2; fi

echo
echo "Week 12 validation — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  Test                                           Result"
echo "  ---------------------------------------------- --------------------------"

# ── 1. the workspace exists ─────────────────────────────────────────────────
CID=$(az monitor log-analytics workspace show -g "$RG" -n "$WS" \
      --query customerId -o tsv 2>/dev/null)
if [ -n "$CID" ]; then ok "Log Analytics workspace exists" "$WS"
else bad "Log Analytics workspace exists" "not found"; echo; exit 1; fi

# ── 2. Sentinel is enabled ON that workspace ────────────────────────────────
# Asked of the SecurityInsights onboardingStates API rather than inferred
# from the workspace existing. They are separate objects: a workspace with
# no Sentinel looks identical from check 1.
ONB=$(az rest --method get --url \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.OperationalInsights/workspaces/$WS/providers/Microsoft.SecurityInsights/onboardingStates/default?api-version=2024-03-01" \
  --query name -o tsv 2>/dev/null)
[ "$ONB" = "default" ] && ok "Sentinel enabled on the workspace" "onboardingState present" \
                       || bad "Sentinel enabled on the workspace" "not onboarded"

# ── 3+4. both detections exist and are enabled ──────────────────────────────
RULES=$(az rest --method get --url \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.OperationalInsights/workspaces/$WS/providers/Microsoft.SecurityInsights/alertRules?api-version=2024-03-01" \
  -o json 2>/dev/null)

for want in "$RULE_POS" "$RULE_NEG"; do
  en=$(echo "$RULES" | python -c "
import json,sys
d=json.load(sys.stdin)
for r in d.get('value',[]):
    p=r.get('properties',{})
    if p.get('displayName')=='''$want''':
        print('enabled' if p.get('enabled') else 'disabled'); break
else: print('missing')
" 2>/dev/null)
  [ "$en" = "enabled" ] && ok "Detection deployed and enabled: $want" "$en" \
                        || bad "Detection deployed and enabled: $want" "$en"
done

# ── the signal itself ───────────────────────────────────────────────────────
# Before asking whether the rule fired, ask whether the data arrived. If
# AzureActivity is empty the rule is not broken -- the diagnostic setting is,
# and those are different repairs.
echo
echo "  waiting for AzureActivity to carry the triggering event..."
SEEN=""
for i in $(seq 1 $TRIES); do
  SEEN=$(az monitor log-analytics query -w "$CID" --analytics-query \
    "AzureActivity | where OperationNameValue =~ 'MICROSOFT.AUTHORIZATION/ROLEASSIGNMENTS/WRITE' | where ActivityStatusValue =~ 'Success' | count" \
    -o tsv 2>/dev/null | head -1 | cut -f1 | tr -d '\r')
  [ -n "$SEEN" ] && [ "$SEEN" != "0" ] && break
  sleep $SLEEP
done
[ -n "$SEEN" ] && [ "$SEEN" != "0" ] \
  && ok "Activity log reached the workspace" "$SEEN role-assignment row(s)" \
  || bad "Activity log reached the workspace" "AzureActivity empty"

# ── 5. THE POSITIVE CONTROL ─────────────────────────────────────────────────
echo
echo "  waiting for the detection to produce an incident..."
INC_JSON=""
for i in $(seq 1 $TRIES); do
  INC_JSON=$(az rest --method get --url \
    "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.OperationalInsights/workspaces/$WS/providers/Microsoft.SecurityInsights/incidents?api-version=2024-03-01" \
    -o json 2>/dev/null)
  n=$(echo "$INC_JSON" | python -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(0); sys.exit()
print(sum(1 for i in d.get('value',[]) if i.get('properties',{}).get('title')=='''$RULE_POS'''))
" 2>/dev/null)
  [ "${n:-0}" != "0" ] && break
  sleep $SLEEP
done

POS=$(echo "$INC_JSON" | python -c "
import json,sys
d=json.load(sys.stdin)
print(sum(1 for i in d.get('value',[]) if i.get('properties',{}).get('title')=='''$RULE_POS'''))
" 2>/dev/null)
[ "${POS:-0}" != "0" ] \
  && ok "POSITIVE control fired" "$POS incident(s)" \
  || bad "POSITIVE control fired" "no incident"

# ── 6. THE NEGATIVE CONTROL ─────────────────────────────────────────────────
NEG=$(echo "$INC_JSON" | python -c "
import json,sys
d=json.load(sys.stdin)
print(sum(1 for i in d.get('value',[]) if i.get('properties',{}).get('title')=='''$RULE_NEG'''))
" 2>/dev/null)
[ "${NEG:-0}" = "0" ] \
  && ok "NEGATIVE control stayed silent" "0 incidents, as required" \
  || bad "NEGATIVE control stayed silent" "$NEG incident(s) -- rule is not specific"

# ── the automation rule's labels ────────────────────────────────────────────
LBL=$(echo "$INC_JSON" | python -c "
import json,sys
d=json.load(sys.stdin)
for i in d.get('value',[]):
    p=i.get('properties',{})
    if p.get('title')=='''$RULE_POS''':
        print(','.join(sorted(l.get('labelName','') for l in p.get('labels',[])))); break
else: print('')
" 2>/dev/null)
[ -n "$LBL" ] \
  && ok "Automation rule labelled the incident" "$LBL" \
  || bad "Automation rule labelled the incident" "no labels"

echo
echo "  $pass passed / $fail failed"
echo
[ $fail -eq 0 ] || exit 1
