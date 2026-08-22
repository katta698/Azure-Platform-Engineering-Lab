#!/usr/bin/env bash
# Week 01 — deploy the landing zone's guardrails.
#
#   ./scripts/deploy.sh report     stage 1: assign, evaluate, block nothing
#   ./scripts/deploy.sh enforce    stage 2: same assignment, now denying
#
# Two stages on purpose. A deny introduced to an environment nobody has measured
# is how a guardrail causes the outage it exists to prevent. Stage 1 tells you
# what would have been blocked; stage 2 blocks it.

set -euo pipefail
cd "$(dirname "$0")/../terraform"

STAGE="${1:-report}"

case "$STAGE" in
  report)  ENFORCE=false ;;
  enforce) ENFORCE=true  ;;
  *) echo "Usage: $0 [report|enforce]" >&2; exit 2 ;;
esac

if [[ ! -f terraform.tfvars ]]; then
  echo "terraform.tfvars is missing. Copy terraform.tfvars.example and fill it in." >&2
  exit 1
fi

echo "Stage: $STAGE (enforce_policy=$ENFORCE)"
echo ""

# ── Resource providers ──────────────────────────────────────────────────────
#
# A brand-new subscription has almost nothing registered. Microsoft.Resources is
# there, so resource groups work and everything looks fine — then the first real
# resource fails with "MissingSubscriptionRegistration" and it reads like a
# permissions problem.
#
# This is NOT in Terraform on purpose. Registration is subscription-wide state,
# not something a week owns: if week 01 and week 05 both declared
# Microsoft.Network, they would fight over it, and a `terraform destroy` in one
# week would try to unregister a provider the other still needs. Registering
# here is idempotent and leaves no ownership claim behind.
#
# Providers this week needs:
#   Microsoft.Network        - virtual network, subnet, NICs, public IP
#   Microsoft.Storage        - the banned-region test in validate.sh
#   Microsoft.PolicyInsights - compliance state and `az policy state trigger-scan`
#
# PolicyInsights is the easiest of the three to miss. Policy still EVALUATES and
# still DENIES without it — enforcement runs in Azure Resource Manager, not in
# this provider — so the guardrail looks completely healthy. What breaks is
# reading the compliance results back: trigger-scan fails with
# SubscriptionNotRegistered, and the portal reports "100% (0 out of 0)", which
# reads as "compliant" rather than "never evaluated".
SUBSCRIPTION_ID=$(grep '^subscription_id' terraform.tfvars | cut -d'"' -f2)

for ns in Microsoft.Network Microsoft.Storage Microsoft.PolicyInsights; do
  state=$(az provider show --namespace "$ns" --subscription "$SUBSCRIPTION_ID" \
            --query registrationState -o tsv 2>/dev/null || echo Unknown)
  if [[ "$state" != "Registered" ]]; then
    echo "Registering $ns (currently $state)..."
    az provider register --namespace "$ns" --subscription "$SUBSCRIPTION_ID" --wait -o none
    echo "  $ns registered"
  fi
done
echo ""

terraform init -input=false
terraform apply -input=false -auto-approve -var="enforce_policy=$ENFORCE"

echo ""
echo "Deployed. Note what just happened at two different scopes:"
echo ""
echo "  - The definition and initiative were created at mg-katta"
echo "  - The assignments were created at mg-lz-dev and mg-platform"
echo "  - Only the test bed lives in a resource group"
echo ""
echo "Compliance data is NOT immediate. Azure Policy evaluates on resource"
echo "write straight away, but a full scan of existing resources runs on its own"
echo "schedule — up to 30 minutes. An empty compliance report right after an"
echo "apply means 'not scanned yet', not 'compliant'. To force it:"
echo ""
echo "    az policy state trigger-scan --resource-group rg-wk01-landing-zone-dev-scus-001"
echo ""
echo "Next: ./scripts/validate.sh"
