#!/usr/bin/env bash
# Week 12 — deploy the platform workspace.
#
#   ./scripts/deploy.sh
#
# The HCP workspace is NOT created here. It is created deliberately, before any
# of this, with its execution mode set:
#
#   azure-week-12-dev, project "Azure Platform Lab", execution-mode local
#
# Letting `terraform init` create it as a side effect is how week 07 ended up on
# REMOTE execution, where the plan ran on HCP's servers with no Azure CLI and no
# credentials, and failed with "az: executable file not found" - an error that
# points at the wrong machine entirely.

set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

: "${TF_DATA_DIR:=C:/tfd/w12}"
export TF_DATA_DIR
mkdir -p "$TF_DATA_DIR"

if [[ ! -f terraform/terraform.tfvars ]]; then
  echo "terraform/terraform.tfvars is missing. Copy the example and fill it in." >&2
  exit 1
fi

SUB=$(grep '^subscription_id' terraform/terraform.tfvars | cut -d'"' -f2)

# Both are subscription-wide preconditions. A DCR against an unregistered
# Microsoft.Insights fails as a generic deployment error, which sends you
# reading the template instead of the subscription.
for ns in Microsoft.OperationalInsights Microsoft.Insights; do
  state=$(az provider show --namespace "$ns" --subscription "$SUB" \
            --query registrationState -o tsv 2>/dev/null | tr -d '\r' || echo Unknown)
  if [[ "$state" != "Registered" ]]; then
    echo "Registering $ns (currently $state)..."
    az provider register --namespace "$ns" --subscription "$SUB" --wait -o none
  fi
done

( cd terraform && terraform init -input=false && terraform apply -input=false -auto-approve )

echo ""
echo "── Deployed ────────────────────────────────────────────────────────────"
( cd terraform
  printf "  workspace     %s\n" "$(terraform output -raw workspace_id)"
  printf "  ingestion URL %s\n" "$(terraform output -raw dce_endpoint)"
)
echo ""
echo "Next: ./scripts/validate.sh"
