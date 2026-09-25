#!/usr/bin/env bash
# Week 06 — deploy the control and the protected resources.
#
#   ./scripts/deploy.sh
#
# Two halves, two tools, and the split is deliberate rather than a compromise:
#
#   the control     Terraform, in sub-lab-dev. An ordinary storage account with
#                   no protection at all.
#   the protected   a deployment stack created at mg-lz-dev scope with the
#                   Azure CLI, deploying into sub-lab-dev with deny settings on.
#
# Deployment stacks have NO Terraform resource. Verified 2026-09-20 against the
# azurerm provider's own documentation tree - there are *_template_deployment
# resources and nothing for Microsoft.Resources/deploymentStacks. Microsoft's
# own guidance: "To create and update a deployment stack, use the Azure CLI,
# Azure PowerShell, or the Azure portal with Bicep files." Terraform is not
# listed, so this week does not pretend otherwise.

set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

: "${TF_DATA_DIR:=C:/tfd/w06}"
export TF_DATA_DIR
mkdir -p "$TF_DATA_DIR"

STACK_NAME="stack-wk06-protected"
STACK_MG="mg-lz-dev"

if [[ ! -f terraform/terraform.tfvars ]]; then
  echo "terraform/terraform.tfvars is missing. Copy the example and fill it in." >&2
  exit 1
fi

SUB=$(grep '^subscription_id' terraform/terraform.tfvars | cut -d'"' -f2)
LOCATION=$(grep '^location' terraform/terraform.tfvars | cut -d'"' -f2)
LOCATION="${LOCATION:-southcentralus}"
PROTECTED_SA="${PROTECTED_STORAGE_ACCOUNT:-stwk06prot$(date +%s | tail -c 7)}"

# Microsoft.Storage on the target subscription. Subscription-wide shared state,
# so it is done here rather than inside the stack's template - a stack that
# fails on an unregistered provider reports a template error, not a missing
# registration.
state=$(az provider show --namespace Microsoft.Storage --subscription "$SUB" \
          --query registrationState -o tsv 2>/dev/null | tr -d '\r' || echo Unknown)
if [[ "$state" != "Registered" ]]; then
  echo "Registering Microsoft.Storage (currently $state)..."
  az provider register --namespace Microsoft.Storage --subscription "$SUB" --wait -o none
fi

# ── 1. The control, in Terraform ────────────────────────────────────────────
echo "── Control: an ordinary storage account, no protection ─────────────"
( cd terraform && terraform init -input=false && terraform apply -input=false -auto-approve )
echo ""

# ── 2. The protected half, as a stack ───────────────────────────────────────
#
# Created at mg-lz-dev, deploying into sub-lab-dev. The scope is the security
# control: the deny assignment lives where the STACK lives, so a principal with
# Contributor on sub-lab-dev cannot reach the stack to lift its own restriction.
echo "── Protected: a deployment stack at $STACK_MG ──────────────────────"
echo "   storage account: $PROTECTED_SA"
echo ""

# Validate before create. A stack that fails midway still exists, and a failed
# stack with deny settings is harder to remove than one that never started.
#
# NOTE: `validate` takes no --yes; `create` does. Passing it to validate fails
# with "unrecognized arguments: --yes" - the sibling commands differ.
az stack mg validate \
  --name "$STACK_NAME" \
  --management-group-id "$STACK_MG" \
  --location "$LOCATION" \
  --deployment-subscription "$SUB" \
  --template-file stack/protected.json \
  --parameters storageAccountName="$PROTECTED_SA" location="$LOCATION" \
  --action-on-unmanage deleteAll \
  --deny-settings-mode denyWriteAndDelete \
  -o none
echo "   validate: ok"

az stack mg create \
  --name "$STACK_NAME" \
  --management-group-id "$STACK_MG" \
  --location "$LOCATION" \
  --deployment-subscription "$SUB" \
  --template-file stack/protected.json \
  --parameters storageAccountName="$PROTECTED_SA" location="$LOCATION" \
  --action-on-unmanage deleteAll \
  --deny-settings-mode denyWriteAndDelete \
  --description "Week 06 - proves a deny assignment a customer can actually create" \
  --yes -o none

echo "   stack created"
echo ""
echo "$PROTECTED_SA" > .protected-storage-account
echo "Deployed. Protected account recorded in .protected-storage-account"
echo ""
echo "Next: ./scripts/validate.sh"
