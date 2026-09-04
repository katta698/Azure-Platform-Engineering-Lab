#!/usr/bin/env bash
# Week 03 — deploy the consumers.
#
#   ./scripts/deploy.sh v1     one consumer, pinned to storage-baseline 1.0.0
#   ./scripts/deploy.sh v2     a second consumer on 2.0.0, alongside the first
#
# Both versions must already be in the registry before EITHER stage runs.
# terraform init resolves every module a configuration refers to, before it
# evaluates anything — the count = 0 on the v2 consumer keeps it out of the
# plan, not out of the download. Running stage v1 against a registry that has
# only 1.0.0 fails at init on a module the stage was never going to create.

set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../terraform"

STAGE="${1:-v1}"
case "$STAGE" in
  v1) ENABLE_V2=false ;;
  v2) ENABLE_V2=true  ;;
  *) echo "Usage: $0 [v1|v2]" >&2; exit 2 ;;
esac

if [[ ! -f terraform.tfvars ]]; then
  echo "terraform.tfvars is missing. Copy terraform.tfvars.example and fill it in." >&2
  exit 1
fi

SUBSCRIPTION_ID=$(grep '^subscription_id' terraform.tfvars | cut -d'"' -f2)

# Subscription-wide state, so it is done here rather than in Terraform.
#
#   Microsoft.Storage             the accounts both consumers create
#   Microsoft.OperationalInsights the workspace diagnostics are sent to
#   Microsoft.Insights            the diagnostic settings themselves. The
#                                 account deploys fine without it and the
#                                 setting is what fails, one resource later
for ns in Microsoft.Storage Microsoft.OperationalInsights Microsoft.Insights; do
  state=$(az provider show --namespace "$ns" --subscription "$SUBSCRIPTION_ID" \
            --query registrationState -o tsv 2>/dev/null | tr -d '\r' || echo Unknown)
  if [[ "$state" != "Registered" ]]; then
    echo "Registering $ns (currently $state)..."
    az provider register --namespace "$ns" --subscription "$SUBSCRIPTION_ID" --wait -o none
    echo "  $ns registered"
  fi
done
echo ""

terraform init -input=false

# The plan is saved and shown before the apply in stage v2, because the plan is
# the evidence this week is after. "app_a is unaffected by the new major" is a
# claim about a plan, and once the apply has run the plan is gone.
if [[ "$STAGE" == "v2" ]]; then
  echo "Planning the addition of the 2.0.0 consumer..."
  terraform plan -input=false -out=tfplan -var="enable_v2_consumer=true"
  echo ""
  echo "── What the plan says about the module pinned to 1.0.0 ───────────────"
  terraform show -json tfplan \
    | python -c "
import json,sys
plan = json.load(sys.stdin)
for rc in plan.get('resource_changes', []):
    actions = rc['change']['actions']
    if actions == ['no-op']:
        continue
    print(f\"  {','.join(actions):8s} {rc['address']}\")
touched_a = [rc['address'] for rc in plan.get('resource_changes', [])
             if rc['address'].startswith('module.app_a') and rc['change']['actions'] != ['no-op']]
print('')
print(f\"  module.app_a changes in this plan: {len(touched_a)}\")
"
  echo ""
  terraform apply -input=false -auto-approve tfplan
  rm -f tfplan
else
  terraform apply -input=false -auto-approve -var="enable_v2_consumer=$ENABLE_V2"
fi

echo ""
echo "Deployed: $(terraform output -raw stage)"
echo ""
echo "Next: ./scripts/validate.sh"
