#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Week 09 — deploy
#
#   ./scripts/deploy.sh
#
# Provider registration is done HERE and deliberately not in Terraform.
# Registration is subscription-wide shared state: two weeks both declaring
# Microsoft.App would fight over one object, and one week's destroy would
# unregister a provider another week still needs.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Any argument starting with / is rewritten to a Windows path by Git Bash
# before az sees it, so resource IDs arrive mangled.
export MSYS_NO_PATHCONV=1
# Never let a dynamic extension install prompt block a non-interactive shell.
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors >/dev/null 2>&1 || true

WEEK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$WEEK_DIR/terraform"

SUB_LAB=$(grep -E '^subscription_id' "$TF_DIR/terraform.tfvars" | cut -d'"' -f2)
[ -n "$SUB_LAB" ] || { echo "could not read subscription_id from terraform.tfvars"; exit 1; }

echo "══ 1. resource providers on sub-lab-dev ══"
for ns in Microsoft.App Microsoft.OperationalInsights Microsoft.Insights Microsoft.ManagedIdentity; do
  state=$(az provider show --namespace "$ns" --subscription "$SUB_LAB" \
            --query registrationState -o tsv --only-show-errors 2>/dev/null | tr -d '\r' || true)
  if [ "$state" != "Registered" ]; then
    echo "   registering $ns (currently ${state:-unknown})"
    az provider register --namespace "$ns" --subscription "$SUB_LAB" --only-show-errors >/dev/null
  else
    echo "   $ns already Registered"
  fi
done

# Microsoft.App genuinely takes a few minutes, and the environment create fails
# with a MissingSubscriptionRegistration that names the namespace but reads like
# a permissions problem. Wait for it rather than racing it.
echo ""
echo "══ 2. waiting for Microsoft.App to reach Registered ══"
for i in $(seq 1 40); do
  state=$(az provider show --namespace Microsoft.App --subscription "$SUB_LAB" \
            --query registrationState -o tsv --only-show-errors 2>/dev/null | tr -d '\r' || true)
  echo "   attempt $i: ${state:-unknown}"
  [ "$state" = "Registered" ] && break
  sleep 15
done
[ "$state" = "Registered" ] || { echo "Microsoft.App did not register in time"; exit 1; }

echo ""
echo "══ 3. terraform ══"
cd "$TF_DIR"
terraform init -input=false
terraform fmt -check
terraform validate

# A Container Apps environment takes several minutes to create. apply's exit
# code is checked explicitly: week 05 shipped a teardown that reported success
# while a firewall kept billing, because set -e does not survive a pipeline.
set +e
terraform apply -input=false -auto-approve
rc=$?
set -e
[ $rc -eq 0 ] || { echo ""; echo "APPLY FAILED (exit $rc) — resources may be half-created. Do not proceed."; exit $rc; }

echo ""
echo "══ 4. what was deployed ══"
terraform output

echo ""
echo "Deployed. Next: ./scripts/validate.sh"
