#!/usr/bin/env bash
# Week 07 — check the identity is real, trusted, and no wider than intended.
#
#   1. the identity exists and has a client ID
#   2. exactly one federated credential, with the right issuer and audience
#   3. the subject names this repo and this branch, exactly
#   4. the identity has NO password credentials - there is nothing to steal
#   5. its role is Reader, at subscription scope, and nothing more
#
# Check 4 is the week's claim. The rest is what makes it usable.

set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

: "${TF_DATA_DIR:=C:/tfd/w07}"
export TF_DATA_DIR

SUB=$(grep '^subscription_id' terraform/terraform.tfvars | cut -d'"' -f2)
ORG=$(grep '^github_org' terraform/terraform.tfvars | cut -d'"' -f2)
REPO=$(grep '^github_repo' terraform/terraform.tfvars | cut -d'"' -f2)
RG="rg-wk07-identity-dev-scus-001"
NAME="id-wk07-github-ci-dev-scus-001"

pass=0; fail=0
note() { echo "   $*"; }
ok()   { echo "   RESULT: $*"; pass=$((pass + 1)); }
bad()  { echo "   RESULT: $*"; fail=$((fail + 1)); }

echo "identity:  $NAME"
echo "repo:      $ORG/$REPO"
echo ""

# ── 1 ───────────────────────────────────────────────────────────────────────
echo "1. The managed identity exists"
CLIENT_ID=$(az identity show --name "$NAME" --resource-group "$RG" --subscription "$SUB" \
              --query clientId -o tsv 2>/dev/null | tr -d '\r')
PRINCIPAL_ID=$(az identity show --name "$NAME" --resource-group "$RG" --subscription "$SUB" \
              --query principalId -o tsv 2>/dev/null | tr -d '\r')
if [[ -n "$CLIENT_ID" ]]; then
  ok "present, client ID resolved"
else
  bad "not found - run deploy.sh first"
  echo "── $pass passed, $fail failed ──"; exit 1
fi
echo ""

# ── 2 ───────────────────────────────────────────────────────────────────────
echo "2. Exactly one federated credential, correctly configured"
n=$(az identity federated-credential list --identity-name "$NAME" --resource-group "$RG" \
      --subscription "$SUB" --query "length(@)" -o tsv 2>/dev/null | tr -d '\r')
ISSUER=$(az identity federated-credential list --identity-name "$NAME" --resource-group "$RG" \
      --subscription "$SUB" --query "[0].issuer" -o tsv 2>/dev/null | tr -d '\r')
AUD=$(az identity federated-credential list --identity-name "$NAME" --resource-group "$RG" \
      --subscription "$SUB" --query "[0].audiences[0]" -o tsv 2>/dev/null | tr -d '\r')
note "count=${n:-0}  issuer=$ISSUER  audience=$AUD"
if [[ "${n:-0}" -eq 1 && "$ISSUER" == "https://token.actions.githubusercontent.com" \
      && "$AUD" == "api://AzureADTokenExchange" ]]; then
  ok "one credential, GitHub as issuer, Entra token exchange as audience"
else
  bad "wrong count, issuer or audience"
fi
echo ""

# ── 3 ───────────────────────────────────────────────────────────────────────
#
# Exact-match, not a prefix. A token from another repo or another branch
# presents a different subject and is refused, so this string IS the boundary.
echo "3. The subject names this repo and branch exactly"
SUBJECT=$(az identity federated-credential list --identity-name "$NAME" --resource-group "$RG" \
      --subscription "$SUB" --query "[0].subject" -o tsv 2>/dev/null | tr -d '\r')
PREFIX=$(gh api "repos/${ORG}/${REPO}/actions/oidc/customization/sub" --jq '.sub_claim_prefix' 2>/dev/null | tr -d '')
EXPECTED="${PREFIX:-repo:${ORG}/${REPO}}:ref:refs/heads/main"
note "subject:  $SUBJECT"
if [[ "$SUBJECT" == "$EXPECTED" ]]; then
  ok "matches $EXPECTED"
else
  bad "expected $EXPECTED"
fi
echo ""

# ── 4. the claim ────────────────────────────────────────────────────────────
#
# A managed identity cannot hold a password at all - the API has nowhere to put
# one. That is the difference from an app registration, where "no secret" is a
# discipline you have to keep rather than a property of the object.
echo "4. There is no secret to steal"
SP_SECRETS=$(az ad sp credential list --id "$CLIENT_ID" --query "length(@)" -o tsv 2>/dev/null | tr -d '\r')
note "password credentials on the identity's service principal: ${SP_SECRETS:-0}"
if [[ "${SP_SECRETS:-0}" -eq 0 ]]; then
  ok "none - authentication is a federated token, minted per run and short lived"
else
  bad "${SP_SECRETS} credential(s) exist, which defeats the point"
fi
echo ""

# ── 5 ───────────────────────────────────────────────────────────────────────
echo "5. The role is Reader, and only Reader"
roles=$(az role assignment list --subscription "$SUB" --assignee "$PRINCIPAL_ID" --include-inherited \
          --query "[].roleDefinitionName" -o tsv 2>/dev/null | tr -d '\r' | sort -u | tr '\n' ' ')
note "roles: ${roles:-<none>}"
if [[ "$(echo "$roles" | tr -d ' ')" == "Reader" ]]; then
  ok "Reader alone - it can look, and cannot change anything"
else
  bad "expected Reader alone"
fi
echo ""

echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
