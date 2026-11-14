#!/usr/bin/env bash
# Week 13 — teardown, verified against Azure.
#
# Two of this week's objects live OUTSIDE the resource group: the policy
# assignment and the role assignment are both at subscription scope. Deleting
# the resource group leaves both behind — the assignment would keep trying to
# remediate into a workspace that no longer exists.
#
# Usage:  bash week-13-diagnostic-settings-at-scale/scripts/cleanup.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RG="rg-diagnostics-lab-dev-scus-001"
WS="law-wk13-dev-scus-001"

SUB=$(az account show --query id -o tsv 2>/dev/null)
[ -z "$SUB" ] && { echo "not signed in"; exit 2; }

# Remediation tasks are not resources Terraform knows about; they were created
# by the CLI and have to go the same way.
echo "removing remediation tasks..."
for t in $(az policy remediation list -g "$RG" --query "[].name" -o tsv 2>/dev/null); do
  az policy remediation delete -g "$RG" --name "$t" >/dev/null 2>&1 \
    && echo "  deleted $t"
done

echo
echo "terraform destroy..."
( cd "$HERE/terraform" && terraform destroy -input=false -auto-approve ) | tail -3

echo
echo "verifying against Azure, not against the destroy's exit code"
echo "  ------------------------------------------------------------------"
fail=0

GRP=$(az group exists -n "$RG" -o tsv 2>/dev/null | tr -d '\r')
[ "$GRP" = "false" ] && echo "  resource group gone                        PASS" \
                     || { echo "  resource group gone                        FAIL ($GRP)"; fail=1; }

LEFT=$(az monitor log-analytics workspace list \
       --query "length([?name=='$WS'])" -o tsv 2>/dev/null | tr -d '\r')
[ "${LEFT:-0}" = "0" ] && echo "  Log Analytics workspace gone               PASS" \
                       || { echo "  Log Analytics workspace gone               FAIL"; fail=1; }

# The two that are NOT in the resource group.
ASSIGN=$(az policy assignment list --scope "/subscriptions/$SUB" \
         --query "length([?name=='wk13-diag-to-law'])" -o tsv 2>/dev/null | tr -d '\r')
[ "${ASSIGN:-0}" = "0" ] && echo "  subscription policy assignment gone        PASS" \
                         || { echo "  subscription policy assignment gone        FAIL"; fail=1; }

ROLE=$(az role assignment list --scope "/subscriptions/$SUB" \
       --role "Log Analytics Contributor" --query "length(@)" -o tsv 2>/dev/null | tr -d '\r')
[ "${ROLE:-0}" = "0" ] && echo "  remediation role assignment gone           PASS" \
                       || echo "  remediation role assignment: ${ROLE} left (check it is not ours)"

# Soft delete keeps the workspace name reserved for 14 days. Correct
# behaviour, reported rather than failed: it stops ingesting and stops billing.
SOFT=$(az monitor log-analytics workspace list-deleted-workspaces \
       --query "length([?name=='$WS'])" -o tsv 2>/dev/null | tr -d '\r')
[ "${SOFT:-0}" != "0" ] && \
  echo "  note: workspace soft-deleted for 14 days, name still reserved"

echo
[ $fail -eq 0 ] && echo "  teardown verified." || echo "  TEARDOWN INCOMPLETE."
exit $fail
