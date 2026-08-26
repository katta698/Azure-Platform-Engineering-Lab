#!/usr/bin/env bash
# Week 02 — teardown.
#
# Three kinds of thing were created and only one of them dies with the resource
# group:
#
#   in the group   the workspace, the storage accounts, the identity
#   on the tree    the definitions, the initiative, the assignment
#   on the tree    THREE ROLE ASSIGNMENTS granted to the identity
#
# The role assignments are the ones to be careful about. Deleting the resource
# group deletes the managed identity, but the grants at mg-lz-dev survive it —
# they are role assignments to a principal ID that no longer resolves, and the
# portal renders them as "Identity not found". They are harmless-looking and
# they accumulate: every re-run of this week leaves three more.
#
# So the group goes first, then terraform destroy removes everything on the
# tree, and then this verifies that no orphaned grant was left behind.

set -euo pipefail

# Git Bash rewrites arguments starting with a slash into Windows paths, and
# every scope below starts with one.
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../terraform"

RG="rg-wk02-policy-as-code-dev-scus-001"
MG_SCOPE="/providers/Microsoft.Management/managementGroups/mg-lz-dev"
SUBSCRIPTION_ID=$(grep '^subscription_id' terraform.tfvars | cut -d'"' -f2)

# Read the identity before deleting anything — afterwards there is nothing left
# to resolve the orphan check against.
PRINCIPAL_ID=$(terraform output -json remediation_identity 2>/dev/null \
                 | python -c "import json,sys; print(json.load(sys.stdin)['principal_id'])" 2>/dev/null || echo "")

echo "This removes:"
echo "  - resource group $RG (workspace, storage accounts, remediation identity)"
echo "  - the assignment at mg-lz-dev and the initiative and definitions at mg-katta"
echo "  - the remediation identity's role assignments at mg-lz-dev"
echo ""
echo "It does NOT remove the diagnostic settings the policy deployed — those are"
echo "child resources of the storage accounts and die with them."
echo ""

# ── The resource group, wholesale ───────────────────────────────────────────
#
# Not a list of names. validate.sh and the policy itself both create things
# Terraform never managed — the diagnostic settings are deployed by a
# remediation task, not by this configuration — and a cleanup that only knows
# about managed resources leaves them behind.
if az group show --name "$RG" --subscription "$SUBSCRIPTION_ID" -o none 2>/dev/null; then
  count=$(az resource list --resource-group "$RG" --subscription "$SUBSCRIPTION_ID" --query "length(@)" -o tsv)
  echo "Deleting $RG and the $count resource(s) in it. This takes a few minutes..."
  az group delete --name "$RG" --subscription "$SUBSCRIPTION_ID" --yes
  echo "  resource group deleted"
else
  echo "$RG does not exist — nothing to delete"
fi
echo ""

# ── Then everything above the subscription ──────────────────────────────────
#
# terraform destroy reconciles the already-deleted group (a 404 is "gone" to the
# provider) and removes the assignment, the initiative, the two definitions and
# the three role assignments.
echo "Destroying the management-group scope objects..."
terraform destroy -input=false -auto-approve

echo ""
echo "Verifying nothing survived..."

remaining=$(az policy assignment list --scope "$MG_SCOPE" \
  --query "length([?name=='assign-remediation-dev'])" -o tsv 2>/dev/null || echo 0)

if [[ "$remaining" != "0" ]]; then
  echo "WARNING: the assignment is still present. Remove it before calling this clean:"
  echo "  az policy assignment delete --name assign-remediation-dev --scope $MG_SCOPE"
  exit 1
fi

# The orphan check. A grant whose principal has been deleted still counts as a
# standing role assignment, and `az role assignment list` returns a null
# principalName for it — the same null a live service principal returns, which
# is why this checks by principal ID rather than by name.
if [[ -n "$PRINCIPAL_ID" ]]; then
  orphans=$(az role assignment list --scope "$MG_SCOPE" --include-inherited \
              --query "length([?principalId=='$PRINCIPAL_ID'])" -o tsv 2>/dev/null || echo 0)
  if [[ "$orphans" != "0" ]]; then
    echo "WARNING: $orphans role assignment(s) at mg-lz-dev still name the deleted"
    echo "identity $PRINCIPAL_ID. Remove them:"
    echo "  az role assignment delete --ids <id>   # broken on CLI 2.86.0, use az rest:"
    echo "  az rest --method delete --url \"https://management.azure.com<assignment-id>?api-version=2022-04-01\""
    exit 1
  fi
  echo "  no orphaned role assignments at mg-lz-dev"
fi

if az group show --name "$RG" --subscription "$SUBSCRIPTION_ID" -o none 2>/dev/null; then
  echo "WARNING: $RG still exists."
  exit 1
fi

# Remediation task records outlive the assignment they ran against. They are
# history rather than infrastructure — no cost, no permissions, no effect — and
# they are the only surviving evidence of what this week actually did. Reported
# rather than deleted, because a teardown that quietly removes the audit trail
# is worse than one that leaves it.
tasks=$(az policy remediation list --management-group mg-lz-dev \
          --query "length([?contains(name, 'remediate-')])" -o tsv 2>/dev/null | tr -d '\r')

if [[ "${tasks:-0}" != "0" ]]; then
  echo "  $tasks remediation task record(s) remain at mg-lz-dev — history, not infrastructure."
  echo "  They cost nothing and hold no permissions. To remove them:"
  echo "    az policy remediation delete --name <name> --management-group mg-lz-dev"
fi

echo "Clean. No week 02 infrastructure remains in the subscription or on the tree."
