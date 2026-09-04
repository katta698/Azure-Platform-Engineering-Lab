#!/usr/bin/env bash
# Week 03 — teardown.
#
# Two different kinds of thing were created and only one of them should go:
#
#   the consumers    a resource group, a workspace, two storage accounts.
#                    Deleted. They cost money and prove nothing further
#   the registry     storage-baseline 1.0.0 and 2.0.0 in the private registry.
#                    KEPT by default
#
# The registry entries are the week's actual output. They cost nothing, they
# are what week 05 and everything after it consume, and deleting a published
# version is the one destructive act a module registry does not forgive: any
# configuration pinned to it stops initialising, including configurations owned
# by people who were not asked.
#
#   ./scripts/cleanup.sh              the Azure resources
#   ./scripts/cleanup.sh --registry   those, and the published versions too

set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../terraform"

ORG="Katta"
MODULE="storage-baseline"
PROVIDER="azurerm"
API="https://app.terraform.io/api/v2"

DROP_REGISTRY=false
[[ "${1:-}" == "--registry" ]] && DROP_REGISTRY=true

RG="rg-wk03-module-factory-dev-scus-001"
SUBSCRIPTION_ID=$(grep '^subscription_id' terraform.tfvars | cut -d'"' -f2)

echo "This removes:"
echo "  - resource group $RG (workspace, both storage accounts, containers)"
echo "  - the Terraform state's record of them"
if $DROP_REGISTRY; then
  echo "  - storage-baseline 1.0.0 and 2.0.0 from the private registry"
  echo ""
  echo "    Any configuration pinned to either version stops initialising."
else
  echo ""
  echo "Kept: storage-baseline in the private registry. It is free, it is what"
  echo "later weeks consume, and unpublishing a version breaks every consumer"
  echo "pinned to it. Pass --registry to remove it anyway."
fi
echo ""

# The whole group rather than a list of names. The module creates a container
# inside the account and the policy from week 02 may have added a diagnostic
# setting Terraform never managed; a cleanup that only knows about managed
# resources leaves whatever else landed in the group.
if az group show --name "$RG" --subscription "$SUBSCRIPTION_ID" -o none 2>/dev/null; then
  count=$(az resource list --resource-group "$RG" --subscription "$SUBSCRIPTION_ID" --query "length(@)" -o tsv | tr -d '\r')
  echo "Deleting $RG and the $count resource(s) in it. This takes a few minutes..."
  az group delete --name "$RG" --subscription "$SUBSCRIPTION_ID" --yes
  echo "  resource group deleted"
else
  echo "$RG does not exist — nothing to delete"
fi
echo ""

# Reconciles the already-deleted group. A 404 is "gone" to the provider, so
# this removes the state entries rather than trying to delete anything twice.
echo "Reconciling state..."
terraform destroy -input=false -auto-approve -var="enable_v2_consumer=false" || \
  terraform destroy -input=false -auto-approve -var="enable_v2_consumer=true"

echo ""
if $DROP_REGISTRY; then
  read_token() {
    if [[ -n "${TFE_TOKEN:-}" ]]; then printf '%s' "$TFE_TOKEN"; return; fi
    local f="${APPDATA:-$HOME/AppData/Roaming}/terraform.d/credentials.tfrc.json"
    f="${f//\//}"
    sed '1s/^\xEF\xBB\xBF//' "$f" \
      | python -c "import json,sys; print(json.load(sys.stdin)['credentials']['app.terraform.io']['token'])"
  }
  TOKEN="$(read_token)"
  for v in 1.0.0 2.0.0; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" -X DELETE \
      "${API}/organizations/${ORG}/registry-modules/private/${ORG}/${MODULE}/${PROVIDER}/${v}")
    echo "  deleted $MODULE $v (HTTP $code)"
  done
fi

echo ""
echo "Verifying nothing survived..."
if az group show --name "$RG" --subscription "$SUBSCRIPTION_ID" -o none 2>/dev/null; then
  echo "WARNING: $RG still exists."
  exit 1
fi

# Azure creates NetworkWatcherRG by itself in any subscription where a VNet
# appears, and it survives every teardown. It is not week 03's and not drift.
echo "Clean. No week 03 infrastructure remains in the subscription."
if ! $DROP_REGISTRY; then
  echo "storage-baseline 1.0.0 and 2.0.0 remain published, which is the point of the week."
fi
