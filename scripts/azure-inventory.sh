#!/usr/bin/env bash
# What exists in the tenant right now.
#
# Run at the start of a session to reconcile SESSION_CONTEXT.md against reality,
# and after any bootstrap apply to verify against Azure rather than against
# Terraform state.
#
# Prints names and structure. Account identifiers are truncated, because this
# output goes into transcripts and screenshots.

set -uo pipefail

mask() { sed -E 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<guid>/g'; }

hr() { printf '\n── %s %s\n' "$1" "$(printf '─%.0s' $(seq 1 $((60 - ${#1}))))"; }

hr "Signed in as"
az account show --query "{user:user.name, tenantDomain:tenantDefaultDomain, subscription:name}" -o yaml 2>&1 | mask

hr "Subscriptions"
az account list --all --query "[].{name:name, state:state, default:isDefault}" -o table 2>&1

hr "Management group tree"
# The tenant root group's name is the tenant ID, so mask the output. --recurse
# needs --expand; without both, children come back null and the tree looks empty.
root=$(az account management-group list --query "[0].name" -o tsv 2>/dev/null)
if [[ -n "$root" ]]; then
  az account management-group show --name "$root" --expand --recurse -o json 2>/dev/null \
    | python -c '
import json, sys

def walk(node, depth=0):
    kind = node.get("type", "")
    label = "sub " if "subscriptions" in kind else "mg  "
    print("   " * depth + label + str(node.get("displayName")))
    for child in node.get("children") or []:
        walk(child, depth + 1)

walk(json.load(sys.stdin))
' 2>&1 || echo "   could not parse tree"
else
  echo "   no management groups readable"
fi

hr "Resource groups"
az group list --query "[].{name:name, location:location}" -o table 2>&1

hr "Resources"
# Masked: auto-created resource names embed the subscription GUID
# (e.g. DefaultWorkspace-<sub-id>-SCUS).
az resource list --query "[].{name:name, type:type, rg:resourceGroup}" -o table 2>&1 | mask | head -50

hr "App registrations"
az ad app list --show-mine --query "[].{name:displayName}" -o table 2>&1

hr "Role assignments (subscription scope and above)"
az role assignment list --all \
  --query "[].{role:roleDefinitionName, principal:principalName, type:principalType}" \
  -o table 2>&1 | mask | head -40

hr "Federated identity credentials on the CI app"
ci_app=$(az ad app list --display-name "sp-hcp-terraform-lab" --query "[0].id" -o tsv 2>/dev/null)
if [[ -n "$ci_app" ]]; then
  az ad app federated-credential list --id "$ci_app" \
    --query "[].{name:name, subject:subject}" -o table 2>&1
  count=$(az ad app federated-credential list --id "$ci_app" --query "length(@)" -o tsv 2>/dev/null)
  echo ""
  echo "   $count of 20 used — Entra's per-application limit."
else
  echo "   sp-hcp-terraform-lab does not exist yet (bootstrap not applied)"
fi

hr "Budgets"
az consumption budget list --query "[].{name:name, amount:amount, grain:timeGrain}" -o table 2>&1 \
  || echo "   none, or the Consumption API is unavailable on this subscription type"

echo ""
