#!/usr/bin/env bash
# Week 12 — teardown, and the proof that it worked.
#
# Teardown here has one trap that is specific to Sentinel, and Microsoft
# states it plainly:
#
#     "Removing Microsoft Sentinel doesn't remove the Log Analytics workspace
#      Microsoft Sentinel was deployed on, or any separate charges that
#      workspace might be incurring."
#
# So "Sentinel is offboarded" is NOT cleanup. The workspace is the billable
# object and it survives. This script destroys the workspace and then asks
# AZURE whether it is gone, rather than trusting terraform destroy's exit
# code -- the same standard week 11 used when it verified every type count at
# zero instead of reading "Destroy complete".
#
# It also removes the role assignment the validation deliberately created.
# A lab that demonstrates privilege escalation and then leaves the privilege
# in place has not finished.
#
# Usage:  bash week-12-detections-as-code/scripts/cleanup.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RG="rg-detections-lab-dev-scus-001"
WS="law-wk12-dev-scus-001"

SUB=$(az account show --query id -o tsv 2>/dev/null)
[ -z "$SUB" ] && { echo "not signed in to Azure"; exit 2; }

# ── 1. remove the deliberately-created role assignment ──────────────────────
# Removed BEFORE the destroy, because it is scoped to the resource group the
# destroy is about to delete. Deleting the group would remove the assignment
# implicitly, which is tidy but proves nothing -- doing it explicitly means
# the teardown can be checked.
RA_FILE="$HERE/.trigger-assignment-id"
if [ -f "$RA_FILE" ]; then
  RA=$(tr -d '\r\n' < "$RA_FILE")
  echo "removing the role assignment created for the positive control..."
  az rest --method delete --url \
    "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Authorization/roleAssignments/$RA?api-version=2022-04-01" \
    >/dev/null 2>&1 \
    && echo "  removed" || echo "  already gone (or the group is)"
  rm -f "$RA_FILE"
else
  echo "no .trigger-assignment-id -- nothing to revoke"
fi

# ── 2. destroy ──────────────────────────────────────────────────────────────
echo
echo "terraform destroy..."
( cd "$HERE/terraform" && terraform destroy -input=false -auto-approve ) \
  | tail -4

# ── 3. ASK AZURE, do not trust the exit code ────────────────────────────────
echo
echo "verifying against Azure rather than against the destroy's exit code"
echo "  ------------------------------------------------------------------"
fail=0

GRP=$(az group exists -n "$RG" -o tsv 2>/dev/null | tr -d '\r')
if [ "$GRP" = "false" ]; then
  echo "  resource group gone                        PASS"
else
  echo "  resource group gone                        FAIL ($GRP)"; fail=1
fi

# The one that matters. Asked by name at subscription scope, so it is answered
# even if the resource group lookup above lied.
LEFT=$(az monitor log-analytics workspace list \
       --query "length([?name=='$WS'])" -o tsv 2>/dev/null | tr -d '\r')
if [ "${LEFT:-0}" = "0" ]; then
  echo "  Log Analytics workspace gone               PASS"
else
  echo "  Log Analytics workspace gone               FAIL ($LEFT left)"; fail=1
fi

# A deleted Log Analytics workspace is SOFT DELETED for 14 days and can be
# recovered by name. It stops ingesting and stops billing for ingestion, so
# this is not a cost problem -- but it does mean the name is still taken, and
# a later week reusing it would get the old workspace back with its old data.
# Reported rather than failed, because it is correct behaviour.
SOFT=$(az monitor log-analytics workspace list-deleted-workspaces \
       --query "length([?name=='$WS'])" -o tsv 2>/dev/null | tr -d '\r')
[ "${SOFT:-0}" != "0" ] && \
  echo "  note: workspace is soft-deleted for 14 days, name still reserved"

# The subscription-scope diagnostic setting is NOT in the resource group, so
# nothing above would notice if it survived. It would be a setting pointing
# at a workspace that no longer exists.
DIAG=$(az monitor diagnostic-settings subscription list \
       --query "length(value[?name=='diag-activity-to-wk12'])" -o tsv 2>/dev/null | tr -d '\r')
if [ "${DIAG:-0}" = "0" ]; then
  echo "  subscription diagnostic setting gone       PASS"
else
  echo "  subscription diagnostic setting gone       FAIL ($DIAG left)"; fail=1
fi

echo
[ $fail -eq 0 ] && echo "  teardown verified." || echo "  TEARDOWN INCOMPLETE."
exit $fail
