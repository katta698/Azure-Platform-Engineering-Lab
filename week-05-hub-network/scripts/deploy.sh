#!/usr/bin/env bash
# Week 05 — deploy the hub network.
#
#   ./scripts/deploy.sh hub        the permanent layer. ~$0/hour. Safe to leave.
#   ./scripts/deploy.sh firewall   that plus Azure Firewall. ~$0.405/hour.
#
# The split is the point. Everything weeks 06+ attach to — the hub VNet, the
# spoke, both peerings, the route table and the private DNS estate — costs
# essentially nothing and is meant to stay. The firewall is the only thing that
# bills by the hour, so it is a separate, deliberate step.
#
# Measured 2026-09-19 from the Azure retail price API, southcentralus:
#   Basic deployment  $0.395/hour
#   2 x public IP     $0.010/hour   (Basic mandates a management IP)
#                     ---------
#                     $0.405/hour   ~= $296/month if left running

set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../terraform"

: "${TF_DATA_DIR:=C:/tfd/w05}"
export TF_DATA_DIR
mkdir -p "$TF_DATA_DIR"

STAGE="${1:-hub}"
case "$STAGE" in
  hub)      FW=false ;;
  firewall) FW=true  ;;
  *) echo "Usage: $0 [hub|firewall]" >&2; exit 2 ;;
esac

if [[ ! -f terraform.tfvars ]]; then
  echo "terraform.tfvars is missing. Copy terraform.tfvars.example and fill it in." >&2
  exit 1
fi

HUB_SUB=$(grep '^connectivity_subscription_id' terraform.tfvars | cut -d'"' -f2)
SPOKE_SUB=$(grep '^spoke_subscription_id' terraform.tfvars | cut -d'"' -f2)

# Subscription-wide shared state, so it is done here rather than in Terraform.
# Both subscriptions need Microsoft.Network; only the hub needs the firewall's
# own providers. A spoke subscription without Microsoft.Network accepts the
# resource group and fails on the VNet, one resource later.
for pair in "$HUB_SUB:Microsoft.Network" "$SPOKE_SUB:Microsoft.Network"; do
  sub="${pair%%:*}"; ns="${pair#*:}"
  state=$(az provider show --namespace "$ns" --subscription "$sub" \
            --query registrationState -o tsv 2>/dev/null | tr -d '\r' || echo Unknown)
  if [[ "$state" != "Registered" ]]; then
    echo "Registering $ns on ${sub:0:8}... (currently $state)"
    az provider register --namespace "$ns" --subscription "$sub" --wait -o none
    echo "  registered"
  fi
done
echo ""

terraform init -input=false

if [[ "$STAGE" == "firewall" ]]; then
  cat <<'WARN'
────────────────────────────────────────────────────────────────────────────
This stage deploys Azure Firewall. It bills from the moment it is created.

  Basic:  ~$0.405/hour  (~$296/month)
  Deploy takes 10-20 minutes. Destroy takes about as long. Both are billed.

Run ./scripts/cleanup.sh when finished — it removes the firewall and leaves
the permanent layer in place.
────────────────────────────────────────────────────────────────────────────
WARN
  echo ""
fi

terraform apply -input=false -auto-approve -var="deploy_firewall=$FW"

echo ""
echo "Deployed: $(terraform output -raw layer)"
if [[ "$STAGE" == "firewall" ]]; then
  echo "BILLING FROM: $(date -u '+%Y-%m-%d %H:%M UTC')"
fi
echo ""
echo "Next: ./scripts/validate.sh"
