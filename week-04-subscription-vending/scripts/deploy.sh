#!/usr/bin/env bash
# Week 04 — deploy the vending pipeline.
#
#   ./scripts/deploy.sh config    vend the payload onto an EXISTING subscription
#   ./scripts/deploy.sh vend      additionally CREATE a subscription and vend onto it
#
# `config` is the default and the repeatable one. `vend` creates a subscription
# through the MCA alias API, and that is the one action in this lab which cannot
# be undone on the day: a cancelled subscription cannot be deleted for three
# days and is removed automatically only after ninety. Run it deliberately,
# once, and read the teardown section of the README first.

set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../terraform"

# ── Windows MAX_PATH ────────────────────────────────────────────────────────
#
# Kept for the same reason week 03 needs it: the module cache is relocatable and
# the repository is not. This week pulls no deep module tree, but a week that
# differs from its neighbours only in the absence of a workaround is a week
# somebody re-derives the workaround for.
: "${TF_DATA_DIR:=C:/tfd/w04}"
export TF_DATA_DIR
mkdir -p "$TF_DATA_DIR"

STAGE="${1:-config}"
case "$STAGE" in
  config) VEND_NEW=false ;;
  vend)   VEND_NEW=true  ;;
  *) echo "Usage: $0 [config|vend]" >&2; exit 2 ;;
esac

if [[ ! -f terraform.tfvars ]]; then
  echo "terraform.tfvars is missing. Copy terraform.tfvars.example and fill it in." >&2
  exit 1
fi

SUBSCRIPTION_ID=$(grep '^subscription_id' terraform.tfvars | cut -d'"' -f2)
EXISTING_ID=$(grep '^existing_subscription_id' terraform.tfvars | cut -d'"' -f2)

# ── Resource providers, on the subscription being vended onto ───────────────
#
# Subscription-wide shared state, so it is done here rather than in Terraform:
# two weeks both declaring Microsoft.Consumption would fight over it, and one
# week's destroy would unregister a provider another still needs.
#
# Microsoft.Consumption is what a budget is created through. A subscription
# without it accepts the resource group and fails on the budget, one resource
# later, with an error that names the provider and not the cause.
for ns in Microsoft.Consumption Microsoft.CostManagement; do
  state=$(az provider show --namespace "$ns" --subscription "$EXISTING_ID" \
            --query registrationState -o tsv 2>/dev/null | tr -d '\r' || echo Unknown)
  if [[ "$state" != "Registered" ]]; then
    echo "Registering $ns on the target subscription (currently $state)..."
    az provider register --namespace "$ns" --subscription "$EXISTING_ID" --wait -o none
    echo "  $ns registered"
  fi
done
echo ""

terraform init -input=false

if [[ "$STAGE" == "vend" ]]; then
  cat <<'WARN'
────────────────────────────────────────────────────────────────────────────
This stage CREATES a subscription through the MCA alias API.

  * It can take ten minutes or more, and the provider carries a 60m timeout
    because its default is shorter than Azure sometimes is.
  * It cannot be undone today. Cancelling stops billing immediately, but the
    Delete option does not appear for three days, and Azure removes the
    subscription automatically only after ninety.

Everything else this week does is repeatable. This is not.
────────────────────────────────────────────────────────────────────────────
WARN
  echo ""

  # The plan is saved and shown, because "vending placed it in the right
  # management group" is a claim about a plan as much as about the result, and
  # after the apply the plan is gone.
  terraform plan -input=false -out=tfplan -var="vend_new_subscription=true"
  echo ""
  echo "── What the plan creates ────────────────────────────────────────────"
  terraform show -json tfplan | python -c "
import json,sys
plan = json.load(sys.stdin)
for rc in plan.get('resource_changes', []):
    actions = rc['change']['actions']
    if actions == ['no-op']:
        continue
    print(f\"  {','.join(actions):8s} {rc['address']}\")
"
  echo ""
  terraform apply -input=false -auto-approve tfplan
  rm -f tfplan
else
  terraform apply -input=false -auto-approve -var="vend_new_subscription=$VEND_NEW"
fi

echo ""
echo "Deployed: $(terraform output -raw stage)"
echo ""
echo "Next: ./scripts/validate.sh"
