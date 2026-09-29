#!/usr/bin/env bash
# Week 07 — teardown.
#
# The role assignment, the federated credential, the identity and its resource
# group all belong to Terraform, so destroy removes the lot. Verified against
# Azure afterwards rather than trusted from an exit code.

set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

: "${TF_DATA_DIR:=C:/tfd/w07}"
export TF_DATA_DIR

SUB=$(grep '^subscription_id' terraform/terraform.tfvars | cut -d'"' -f2)
RG="rg-wk07-identity-dev-scus-001"

( cd terraform && terraform destroy -input=false -auto-approve )

echo ""
echo "Verifying nothing survived..."
if az group show --name "$RG" --subscription "$SUB" -o none 2>/dev/null; then
  echo "  STILL PRESENT: $RG" >&2
  exit 1
fi
echo "  Clean - the resource group is gone."

# A dangling role assignment outlives the identity it referenced and shows in
# the portal as an unresolvable object ID. Terraform removes its own, so this
# is a check, not a cleanup.
left=$(az role assignment list --subscription "$SUB" --all \
         --query "length([?contains(roleDefinitionName,'Reader') && principalType=='ServicePrincipal' && principalName==null])" \
         -o tsv 2>/dev/null | tr -d '\r' || echo 0)
echo "  Orphaned Reader assignments with an unresolvable principal: ${left:-0}"
