#!/usr/bin/env bash
# Week 02 — policy that fixes things, in three stages.
#
#   ./scripts/deploy.sh audit         auditIfNotExists. Reports, acts on nothing.
#                                     The identity is attached — Azure requires
#                                     it — but holds nothing and cannot act
#   ./scripts/deploy.sh no-grants     deployIfNotExists WITH an identity that
#                                     holds no roles. The deliberate failure
#   ./scripts/deploy.sh remediate     the same, with the grants in place
#
# The middle stage is the point of the week. deployIfNotExists needs a managed
# identity, that identity needs a role assignment at the remediation scope, and
# when the grant is missing the failure appears as a failed deployment inside a
# remediation task — not as an access error on the policy. Running it on purpose
# once is how that error stops being a mystery later.

set -euo pipefail

# Git Bash (MSYS) rewrites any argument that looks like a Unix path into a
# Windows path before the program sees it, and every Azure resource ID starts
# with a slash. Without this, anything here that passes a scope fails with a
# confusing "Invalid value".
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../terraform"

STAGE="${1:-audit}"

case "$STAGE" in
  audit)     REMEDIATE=false ; GRANTS=false ;;
  no-grants) REMEDIATE=true  ; GRANTS=false ;;
  remediate) REMEDIATE=true  ; GRANTS=true  ;;
  *) echo "Usage: $0 [audit|no-grants|remediate]" >&2; exit 2 ;;
esac

if [[ ! -f terraform.tfvars ]]; then
  echo "terraform.tfvars is missing. Copy terraform.tfvars.example and fill it in." >&2
  exit 1
fi

SUBSCRIPTION_ID=$(grep '^subscription_id' terraform.tfvars | cut -d'"' -f2)

echo "Stage: $STAGE (enable_remediation=$REMEDIATE, grant_remediation_roles=$GRANTS)"
echo ""

# ── Resource providers ──────────────────────────────────────────────────────
#
# Registration is subscription-wide state, so it is done here rather than in
# Terraform: two weeks both declaring Microsoft.Insights would fight over it,
# and one week's destroy would unregister a provider another still needs.
#
#   Microsoft.Storage           - the storage accounts the policy targets
#   Microsoft.OperationalInsights - the Log Analytics workspace
#   Microsoft.Insights          - diagnostic settings. This is the one the
#                                 REMEDIATION needs, not the deployment: the
#                                 policy assignment is created happily without
#                                 it and the remediation task then fails inside
#                                 its ARM deployment with
#                                 MissingSubscriptionRegistration, which looks
#                                 like a permissions problem and is not
#   Microsoft.ManagedIdentity   - the user-assigned identity
#   Microsoft.PolicyInsights    - reading compliance back, and creating
#                                 remediation tasks at all
for ns in Microsoft.Storage Microsoft.OperationalInsights Microsoft.Insights \
          Microsoft.ManagedIdentity Microsoft.PolicyInsights; do
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
terraform apply -input=false -auto-approve \
  -var="enable_remediation=$REMEDIATE" \
  -var="grant_remediation_roles=$GRANTS"

echo ""
echo "Deployed: $(terraform output -raw stage)"
echo ""

if [[ "$STAGE" == "audit" ]]; then
  cat <<'MSG'
The assignment already carries its identity in this stage, and it has to:
Azure rejects an assignment whose definitions contain a deployment unless one
is attached, whatever effect was selected. The identity is inert here — an
auditIfNotExists rule reads the target's children and never writes. What makes
it able to act is the role grants, not its presence.

Next: ./scripts/validate.sh
MSG
else
  cat <<'MSG'
Compliance data is not immediate. Policy evaluates on resource write straight
away, but the scan of EXISTING resources is scheduled — and remediation only
ever acts on what the last completed scan flagged. That is why validate.sh
forces a scan before it creates a single remediation task.

Next: ./scripts/validate.sh
MSG
fi
