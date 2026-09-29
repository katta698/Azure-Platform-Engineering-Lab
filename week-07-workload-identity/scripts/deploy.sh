#!/usr/bin/env bash
# Week 07 — create the CI identity and the trust that makes it usable.
#
#   ./scripts/deploy.sh
#
# Terraform only. Afterwards the three identifiers it prints go into GitHub as
# repository VARIABLES - Settings > Secrets and variables > Actions > Variables.
# Not secrets. Nothing here is a secret, which is the week.

set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

: "${TF_DATA_DIR:=C:/tfd/w07}"
export TF_DATA_DIR
mkdir -p "$TF_DATA_DIR"

if [[ ! -f terraform/terraform.tfvars ]]; then
  echo "terraform/terraform.tfvars is missing. Copy the example and fill it in." >&2
  exit 1
fi

SUB=$(grep '^subscription_id' terraform/terraform.tfvars | cut -d'"' -f2)

# ManagedIdentity is per subscription and is a real precondition. A federated
# credential against an unregistered provider fails as a generic deployment
# error, which sends you reading the wrong file.
state=$(az provider show --namespace Microsoft.ManagedIdentity --subscription "$SUB" \
          --query registrationState -o tsv 2>/dev/null | tr -d '\r' || echo Unknown)
if [[ "$state" != "Registered" ]]; then
  echo "Registering Microsoft.ManagedIdentity (currently $state)..."
  az provider register --namespace Microsoft.ManagedIdentity --subscription "$SUB" --wait -o none
fi

ORG=$(grep '^github_org' terraform/terraform.tfvars | cut -d'"' -f2)
REPO=$(grep '^github_repo' terraform/terraform.tfvars | cut -d'"' -f2)

# Ask GitHub what subject its runners will actually present, rather than
# assuming the documented repo:owner/repo form. With immutable subject claims
# on - now the default - the prefix carries numeric owner and repo IDs, and a
# credential built from the names matches nothing. The failure is
# AADSTS700213 at login time, long after the apply reported success.
PREFIX=$(gh api "repos/${ORG}/${REPO}/actions/oidc/customization/sub"            --jq '.sub_claim_prefix' 2>/dev/null | tr -d '')
if [[ -z "$PREFIX" ]]; then
  PREFIX="repo:${ORG}/${REPO}"
  echo "NOTE: could not read the subject prefix from GitHub; assuming $PREFIX"
else
  echo "Subject prefix as GitHub reports it: $PREFIX"
fi

( cd terraform && terraform init -input=false     && terraform apply -input=false -auto-approve -var="github_subject_prefix=${PREFIX}" )

echo ""
echo "── Put these in GitHub as repository VARIABLES (not secrets) ──"
( cd terraform
  printf "  AZURE_CLIENT_ID       = %s\n" "$(terraform output -raw client_id)"
  printf "  AZURE_TENANT_ID       = %s\n" "$(terraform output -raw tenant_id)"
  printf "  AZURE_SUBSCRIPTION_ID = %s\n" "$(terraform output -raw subscription_id)"
)
echo ""
echo "Next: ./scripts/validate.sh"
