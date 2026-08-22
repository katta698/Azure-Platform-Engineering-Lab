#!/usr/bin/env bash
# Week 01 — teardown.
#
# This week is the one where "delete the resource group" is NOT the whole answer,
# and that is the point worth carrying forward.
#
# The test bed lives in a resource group and dies with it. The policy
# assignments, the initiative and the definition live at MANAGEMENT GROUP scope
# — outside every resource group, in a part of the hierarchy that resource-group
# deletion cannot reach. Delete the group and the guardrails are still there,
# still evaluating, still denying, with nothing left in the subscription to
# explain why.
#
# terraform destroy removes both because Terraform tracks both. Doing it by hand
# with `az group delete` is how you end up with an orphaned deny assignment that
# nobody can find the source of six months later.

set -euo pipefail

# Git Bash (MSYS) rewrites any argument that looks like a Unix path into a
# Windows path before the program sees it. Every Azure resource ID starts with a
# slash, so `--scope /providers/Microsoft.Management/...` arrives at az as
# `C:/Program Files/Git/providers/Microsoft.Management/...` and fails with a
# confusing "Invalid value in --scope". This disables that rewriting for the
# whole script. Without it, nothing here that passes a resource ID works.
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../terraform"

RG="rg-wk01-landing-zone-dev-scus-001"

echo "This removes:"
echo "  - resource group $RG and everything in it"
echo "  - the baseline assignments at mg-lz-dev and mg-platform"
echo "  - the initiative and the custom definition at mg-katta"
echo ""

# Resources created by validate.sh are not in Terraform state — they were made
# with az on purpose, to prove the policy blocks a real deployment rather than a
# Terraform plan. They die with the resource group, but destroy will not know
# about them, so remove them first to keep the destroy plan honest.
for name in nic-wk01-compliant nic-wk01-noncompliant pip-wk01-test; do
  az network nic delete --resource-group "$RG" --name "$name" -o none 2>/dev/null || true
  az network public-ip delete --resource-group "$RG" --name "$name" -o none 2>/dev/null || true
done

terraform destroy -input=false -auto-approve

echo ""
echo "Verifying nothing survived at management group scope..."

remaining=$(az policy assignment list \
  --scope "/providers/Microsoft.Management/managementGroups/mg-lz-dev" \
  --query "length([?name=='assign-baseline-lz-dev'])" -o tsv 2>/dev/null || echo 0)

if [[ "$remaining" != "0" ]]; then
  echo "WARNING: the dev assignment is still present. Remove it before calling this clean:"
  echo "  az policy assignment delete --name assign-baseline-lz-dev \\"
  echo "    --scope /providers/Microsoft.Management/managementGroups/mg-lz-dev"
  exit 1
fi

if az group show --name "$RG" -o none 2>/dev/null; then
  echo "WARNING: $RG still exists."
  exit 1
fi

echo "Clean. Nothing from week 01 remains in the subscription or on the tree."
