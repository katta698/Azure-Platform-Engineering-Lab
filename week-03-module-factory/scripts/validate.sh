#!/usr/bin/env bash
# Week 03 — check that the factory produced what it claims, and that the pin
# does what pins are supposed to do.
#
# Seven checks, in the order that makes each one meaningful:
#
#   1. the registry holds both versions, both usable
#   2. the deployed accounts carry the baseline the module decides
#   3. the v1 consumer has NO diagnostic setting  — v1 allowed that
#   4. the v2 consumer has TWO                    — account metrics + blob logs
#   5. shared keys differ between them            — the silent breaking change,
#                                                   measured on live resources
#   6. an upgrade of the v1 consumer to 2.0.0 fails at plan — the loud one
#   7. no drift
#
# Checks 5 and 6 are the week. Everything else is establishing that the two
# accounts are otherwise identical, so that the differences are attributable to
# the module version and to nothing else.

set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../terraform"

# ── Windows MAX_PATH ────────────────────────────────────────────────────────
#
# AVM nests modules deeply: the storage account pulls avm-utl-interfaces once
# per sub-resource, producing paths like
#   .terraform/modules/app_a.storage_account.queues.role_assignments.interfaces/.git/objects/pack/pack-<sha>.pack
# which exceeds the limit from inside this repo's own path. Measured 2026-09-03:
# it fails even with core.longpaths=true AND the LongPathsEnabled registry value
# already 0x1, because git hits the ceiling mid-clone — first as
# "Filename too long", then as "unable to rename temporary '*.pack' file".
#
# The module cache is relocatable and the configuration is not, so the cache
# moves rather than the repo. Override by exporting TF_DATA_DIR yourself.
: "${TF_DATA_DIR:=C:/tfd/w03}"
export TF_DATA_DIR
mkdir -p "$TF_DATA_DIR"


ORG="Katta"
MODULE="storage-baseline"
PROVIDER="azurerm"
API="https://app.terraform.io/api/v2"

SUBSCRIPTION_ID=$(grep '^subscription_id' terraform.tfvars | cut -d'"' -f2)
RG=$(terraform output -raw resource_group 2>/dev/null)
STAGE=$(terraform output -raw stage 2>/dev/null || echo unknown)

if [[ -z "$RG" ]]; then
  echo "Could not read the Terraform outputs. Run deploy.sh first." >&2
  exit 1
fi

pass=0; fail=0
note() { echo "   $*"; }
ok()   { echo "   RESULT: $*"; pass=$((pass + 1)); }
bad()  { echo "   RESULT: $*"; fail=$((fail + 1)); }

echo "Stage: $STAGE"
echo ""

# On Windows the credentials file is at %APPDATA%/terraform.d/, and several
# Windows tools write it as UTF-8 WITH a byte order mark — which Terraform's
# own parser rejects as "At 1:1: illegal char". Stripped here so this script
# keeps working on a file Terraform itself would refuse.
read_token() {
  if [[ -n "${TFE_TOKEN:-}" ]]; then printf '%s' "$TFE_TOKEN"; return; fi
  local f="${APPDATA:-$HOME/AppData/Roaming}/terraform.d/credentials.tfrc.json"
  f="${f//\\//}"
  sed '1s/^\xEF\xBB\xBF//' "$f" \
    | python -c "import json,sys; print(json.load(sys.stdin)['credentials']['app.terraform.io']['token'])"
}

# ── 1. the registry ─────────────────────────────────────────────────────────
echo "1. Both versions are published and usable"
TOKEN="$(read_token)"
versions=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "${API}/organizations/${ORG}/registry-modules/private/${ORG}/${MODULE}/${PROVIDER}/versions" \
  | python -c "
import json,sys
d = json.load(sys.stdin)
for v in sorted(d.get('data', []), key=lambda x: x['attributes']['version']):
    print(v['attributes']['version'], v['attributes']['status'])
")
while read -r v s; do
  [[ -n "$v" ]] && note "$v  $s"
done <<< "$versions"

if [[ $(grep -c ' ok$' <<< "$versions") -ge 2 ]]; then
  ok "both versions present and ok"
else
  bad "expected two versions at status ok"
fi
echo ""

# ── the accounts ────────────────────────────────────────────────────────────
#
# One call, all the properties. az writes CRLF on Windows, so the last field of
# every tsv row arrives with a trailing carriage return that compares equal to
# nothing — stripped once here rather than at each comparison. A null tag comes
# back as the literal string None, which is not an empty field either.
inventory=$(az storage account list --resource-group "$RG" --subscription "$SUBSCRIPTION_ID" \
  --query "[].[name, minimumTlsVersion, allowBlobPublicAccess, allowSharedKeyAccess, tags.\"cost-center\"]" \
  -o tsv 2>/dev/null | tr -d '\r')

A_NAME=$(terraform output -json app_a | python -c "import json,sys; print(json.load(sys.stdin)['name'])")
A_ID=$(terraform output -json app_a | python -c "import json,sys; print(json.load(sys.stdin)['id'])")
B_NAME=$(terraform output -json app_b | python -c "import json,sys; d=json.load(sys.stdin); print(d['name'] if d else '')")

echo "2. The baseline the module decides, on the deployed accounts"
while IFS=$'\t' read -r name tls public sharedkey cc; do
  [[ -z "$name" ]] && continue
  note "$name  tls=$tls  publicblob=$public  sharedkey=$sharedkey  cost-center=$cc"
  # az renders JSON booleans Python-style — True/False, capitalised — so a
  # compare against lowercase "false" fails on a correct resource. Lowercased
  # here rather than at each call site.
  if [[ "$tls" == "TLS1_2" && "${public,,}" == "false" && "$cc" == "platform-lab" ]]; then
    ok "$name is on the baseline"
  else
    bad "$name is off the baseline"
  fi
done <<< "$inventory"
echo ""

# ── diagnostics ─────────────────────────────────────────────────────────────
#
# `az monitor diagnostic-settings list` returns a BARE JSON ARRAY, not an
# object with a value property. Querying value[?...] against it fails with a
# jmespath type error, and with the error swallowed the count reads as zero —
# which passes a check for "no diagnostic setting" because the lookup broke
# rather than because there is nothing there. Counted with length(@).
diag_count() {
  az monitor diagnostic-settings list --resource "$1" --subscription "$SUBSCRIPTION_ID" \
    --query "length(@)" -o tsv 2>/dev/null | tr -d '\r' || echo ERROR
}

echo "3. The v1 consumer has no diagnostic setting"
a_acct=$(diag_count "$A_ID")
a_blob=$(diag_count "${A_ID}/blobServices/default")
note "account: ${a_acct:-0}   blob service: ${a_blob:-0}"
if [[ "${a_acct:-0}" == "0" && "${a_blob:-0}" == "0" ]]; then
  ok "none, as 1.0.0 allows — the workspace was never passed"
else
  bad "expected none on a 1.0.0 consumer that passed no workspace"
fi
echo ""

echo "4. The v2 consumer has two, on two different resources"
if [[ -z "$B_NAME" ]]; then
  note "the 2.0.0 consumer is not deployed — run ./scripts/deploy.sh v2"
  note "SKIPPED"
else
  B_ID=$(terraform output -json app_b | python -c "import json,sys; print(json.load(sys.stdin)['id'])")
  b_acct=$(diag_count "$B_ID")
  b_blob=$(diag_count "${B_ID}/blobServices/default")
  note "account: ${b_acct:-0} (Transaction metrics)   blob service: ${b_blob:-0} (audit logs)"
  if [[ "${b_acct:-0}" == "1" && "${b_blob:-0}" == "1" ]]; then
    ok "one each — a storage account emits no logs of its own, the blob service does"
  else
    bad "expected one setting on the account and one on the blob service"
  fi
fi
echo ""

# ── 5. the silent breaking change ───────────────────────────────────────────
echo "5. Shared key access differs between the two versions"
if [[ -z "$B_NAME" ]]; then
  note "SKIPPED — the 2.0.0 consumer is not deployed"
else
  a_key=$(awk -F'\t' -v n="$A_NAME" '$1==n {print $4}' <<< "$inventory")
  b_key=$(awk -F'\t' -v n="$B_NAME" '$1==n {print $4}' <<< "$inventory")
  note "$A_NAME (1.0.0): allowSharedKeyAccess=$a_key"
  note "$B_NAME (2.0.0): allowSharedKeyAccess=$b_key"
  if [[ "${a_key,,}" == "true" && "${b_key,,}" == "false" ]]; then
    ok "the default flipped, and neither call site changed"
    note "this is the dangerous half of a major bump: no plan error, no apply"
    note "error, and a connection string that stops working at runtime"
  else
    bad "expected true on the 1.0.0 consumer and false on the 2.0.0 one"
  fi
fi
echo ""

# ── 6. the loud breaking change ─────────────────────────────────────────────
#
# A throwaway root that calls 2.0.0 with exactly the arguments app_a passes.
# `terraform validate` rather than plan: a missing required argument is a
# configuration error raised before any provider is configured, so this needs
# no Azure credentials and touches nothing in the subscription.
echo "6. Upgrading the v1 consumer to 2.0.0 fails before it plans"
TMP=$(mktemp -d -t wk03-upgrade-XXXXXX)
{
  echo 'terraform {'
  echo '  required_providers {'
  echo '    azapi  = { source = "Azure/azapi", version = "~> 2.11" }'
  echo '    modtm  = { source = "Azure/modtm", version = "~> 0.3" }'
  echo '    random = { source = "hashicorp/random", version = ">= 3.5.0, < 4.0.0" }'
  echo '  }'
  echo '}'
  echo ''
  echo 'module "app_a_upgraded" {'
  echo "  source  = \"app.terraform.io/${ORG}/${MODULE}/${PROVIDER}\""
  echo '  version = "2.0.0"'
  echo ''
  echo '  workload          = "appa"'
  echo '  environment       = "dev"'
  echo '  location          = "southcentralus"'
  echo "  resource_group_id = \"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/${RG}\""
  echo '  cost_center       = "platform-lab"'
  echo '  container_name    = "app-a-data"'
  echo '}'
} > "$TMP/main.tf"

# TF_DATA_DIR is set for this week's root at the top of the script. It must NOT
# leak into this throwaway root, or init reuses the week's module cache and
# fails against a configuration that never asked for it.
if (cd "$TMP" && unset TF_DATA_DIR && terraform init -input=false -no-color >/dev/null 2>&1); then
  out=$( (cd "$TMP" && unset TF_DATA_DIR && terraform validate -no-color) 2>&1 )
  if grep -q "Missing required argument" <<< "$out"; then
    grep -B1 -A3 "Missing required argument" <<< "$out" | sed 's/^/   /'
    ok "the upgrade is refused before anything is planned"
  else
    bad "expected a Missing required argument error, got:"
    head -12 <<< "$out"
  fi
else
  bad "could not initialise the upgrade check against the registry"
fi
rm -rf "$TMP"
echo ""

# ── 7. drift ────────────────────────────────────────────────────────────────
echo "7. The deployed state matches the configuration"
terraform plan -input=false -detailed-exitcode -no-color \
  -var="enable_v2_consumer=$([[ -n "$B_NAME" ]] && echo true || echo false)" >/dev/null 2>&1
case $? in
  0) ok "no drift" ;;
  2) bad "the plan proposes changes — the deployment does not match the code" ;;
  *) bad "the plan errored" ;;
esac
echo ""

echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
