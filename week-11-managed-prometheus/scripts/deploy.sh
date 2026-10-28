#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Week 11 — deploy.
#
#   ./scripts/deploy.sh
#
# One apply. No staging, unlike weeks 04, 06 and 10 — nothing here references
# something that has to exist first in a way Terraform cannot order itself.
#
# What this week does NOT do is pretend the deploy is the end of it. The role
# assignment granting Monitoring Metrics Publisher takes roughly THIRTY
# MINUTES to take effect. Until it does, Prometheus gets HTTP 403 from the
# ingestion endpoint and nothing lands in the workspace. The apply succeeds
# long before the pipeline works, which is exactly the gap validate.sh exists
# to close.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail
export MSYS_NO_PATHCONV=1

WEEK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$WEEK_DIR/terraform"
: "${TF_DATA_DIR:=C:/tfd/w11}"
export TF_DATA_DIR

cd "$TF_DIR"

if [ ! -f terraform.tfvars ]; then
  echo "terraform.tfvars is missing. Copy terraform.tfvars.example and fill it in." >&2
  exit 1
fi

SUB=$(grep -E '^subscription_id' terraform.tfvars | cut -d'"' -f2)

# The SSH key is read at plan time by file(). Failing here with a sentence is
# better than failing inside Terraform with a stack of HCL.
KEY_PATH=$(grep -E '^ssh_public_key_path' terraform.tfvars 2>/dev/null | cut -d'"' -f2 || true)
KEY_PATH="${KEY_PATH:-$HOME/.ssh/id_ed25519.pub}"
KEY_PATH="${KEY_PATH/#\~/$HOME}"
if [ ! -f "$KEY_PATH" ]; then
  echo "No SSH public key at $KEY_PATH." >&2
  echo "Azure requires a key or a password on a Linux VM, and this lab does not" >&2
  echo "create passwords. Generate one, or set ssh_public_key_path:" >&2
  echo "  ssh-keygen -t ed25519 -C azure-lab" >&2
  exit 1
fi

echo "══ 1. resource providers on sub-lab-dev ══"
# Registration is subscription-wide shared state, so it lives here rather than
# in Terraform: one week's destroy must not unregister a provider another week
# still needs.
# Microsoft.AlertsManagement is here because its absence is what failed the
# first apply: the Prometheus rule group returned 409 MissingSubscriptionRegistration
# after every other resource had been created. Six namespaces, and the one
# that is easy to forget is the one that owns alert rules rather than metrics.
for ns in Microsoft.Monitor Microsoft.Insights Microsoft.Dashboard \
          Microsoft.AlertsManagement Microsoft.Compute Microsoft.Network \
          Microsoft.ManagedIdentity; do
  state=$(az provider show --namespace "$ns" --subscription "$SUB" \
            --query registrationState -o tsv --only-show-errors 2>/dev/null | tr -d '\r' || true)
  if [ "$state" != "Registered" ]; then
    echo "   registering $ns (currently ${state:-unknown})"
    az provider register --namespace "$ns" --subscription "$SUB" --only-show-errors >/dev/null
  else
    echo "   $ns already Registered"
  fi
done

echo ""
echo "══ 2. waiting for Microsoft.Monitor and Microsoft.Dashboard ══"
for ns in Microsoft.Monitor Microsoft.Dashboard Microsoft.AlertsManagement; do
  for _ in $(seq 1 40); do
    state=$(az provider show --namespace "$ns" --subscription "$SUB" \
              --query registrationState -o tsv --only-show-errors 2>/dev/null | tr -d '\r' || true)
    [ "$state" = "Registered" ] && break
    echo "   waiting for $ns: ${state:-unknown}"
    sleep 15
  done
done

echo ""
echo "══ 3. terraform ══"
terraform init -input=false
terraform fmt -check
terraform validate
terraform apply -input=false -auto-approve

echo ""
echo "══ 4. what was deployed ══"
terraform output

echo ""
echo "══ 5. the part the apply does not prove ══"
cat <<'NOTE'
   The apply is finished. The pipeline is probably not working yet.

   Monitoring Metrics Publisher on the data collection rule takes about
   THIRTY MINUTES to propagate. Until then Prometheus on the VM gets HTTP 403
   from the ingestion endpoint, retries, and nothing appears in the workspace.

   That is not a failure. It is the documented behaviour, and it is six times
   longer than the same role took in week 08.

   Run ./scripts/validate.sh — it polls rather than asking once.
NOTE
