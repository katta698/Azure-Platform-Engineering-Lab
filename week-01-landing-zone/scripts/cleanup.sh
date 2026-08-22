#!/usr/bin/env bash
# Week 01 — teardown.
#
# This is the week where "delete the resource group" is NOT the whole answer,
# and that is the part worth carrying forward.
#
# The test bed lives in a resource group and dies with it. The policy
# definition, the initiative and both assignments live at MANAGEMENT GROUP
# scope — outside every resource group, in a part of the hierarchy that
# resource-group deletion cannot reach. Delete the group by hand and the
# guardrails are still there, still evaluating, still denying, with nothing left
# in the subscription to explain why.
#
# So this does both, in the order that works.

set -euo pipefail

# Git Bash (MSYS) rewrites any argument that looks like a Unix path into a
# Windows path before the program sees it. Every Azure resource ID starts with a
# slash, so `--scope /providers/Microsoft.Management/...` arrives at az as
# `C:/Program Files/Git/providers/Microsoft.Management/...` and fails with a
# confusing "Invalid value in --scope". Without this, nothing here that passes a
# resource ID works.
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../terraform"

RG="rg-wk01-landing-zone-dev-scus-001"
SUBSCRIPTION_ID=$(grep '^subscription_id' terraform.tfvars | cut -d'"' -f2)

echo "This removes:"
echo "  - resource group $RG and everything in it"
echo "  - the baseline assignments at mg-lz-dev and mg-platform"
echo "  - the initiative and the custom definition at mg-katta"
echo ""

# ── Delete the resource group first, wholesale ──────────────────────────────
#
# NOT a list of resource names. The first version of this script deleted the
# NICs and public IP it knew the names of, and failed for two reasons that are
# both worth keeping in mind:
#
#   1. It omitted --subscription, so every delete ran against the CLI's default
#      subscription instead of the lab one. az reported success having deleted
#      nothing, and the failure only surfaced later as a subnet still in use.
#   2. validate.sh creates storage accounts with a random suffix. A cleanup that
#      hardcodes names cannot know about them, so they survive a "successful"
#      teardown and quietly accrue cost.
#
# Deleting the whole group sidesteps both. It also removes resources Terraform
# never managed, which is most of what a test script leaves behind.
if az group show --name "$RG" --subscription "$SUBSCRIPTION_ID" -o none 2>/dev/null; then
  count=$(az resource list --resource-group "$RG" --subscription "$SUBSCRIPTION_ID" --query "length(@)" -o tsv)
  echo "Deleting $RG and the $count resource(s) in it. This takes a few minutes..."
  az group delete --name "$RG" --subscription "$SUBSCRIPTION_ID" --yes
  echo "  resource group deleted"
else
  echo "$RG does not exist — nothing to delete"
fi
echo ""

# ── Then the management-group scope objects ─────────────────────────────────
#
# terraform destroy reconciles the already-deleted resource group (the provider
# treats a 404 as gone) and removes the definition, initiative and assignments
# that live above every subscription.
echo "Destroying the management-group scope objects..."
terraform destroy -input=false -auto-approve

echo ""
echo "Verifying nothing survived..."

remaining=$(az policy assignment list \
  --scope "/providers/Microsoft.Management/managementGroups/mg-lz-dev" \
  --query "length([?name=='assign-baseline-lz-dev'])" -o tsv 2>/dev/null || echo 0)

if [[ "$remaining" != "0" ]]; then
  echo "WARNING: the dev assignment is still present. Remove it before calling this clean:"
  echo "  az policy assignment delete --name assign-baseline-lz-dev \\"
  echo "    --scope /providers/Microsoft.Management/managementGroups/mg-lz-dev"
  exit 1
fi

if az group show --name "$RG" --subscription "$SUBSCRIPTION_ID" -o none 2>/dev/null; then
  echo "WARNING: $RG still exists."
  exit 1
fi

echo "Clean. Nothing from week 01 remains in the subscription or on the tree."
echo ""
echo "The deny-all on mg-decommissioned is NOT removed by this — it lives in"
echo "bootstrap because it is permanent platform governance, not week 01's."
