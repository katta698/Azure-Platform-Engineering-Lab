#!/usr/bin/env bash
# Week 05 — teardown.
#
#   ./scripts/cleanup.sh            destroy the FIREWALL only. Default.
#   ./scripts/cleanup.sh --all      destroy the hub and spoke as well
#
# This week inverts the usual default, and deliberately. Weeks 01-04 tore
# everything down because nothing depended on them. Weeks 06 onward peer into
# this hub and resolve through this private DNS estate, so destroying it by
# reflex breaks the next six weeks to save nothing — the permanent layer bills
# at approximately zero.
#
# What actually costs money is the firewall, at ~$0.405/hour on Basic. That is
# what this removes by default, and removing it is safe: the route that points
# at it is conditional on the same variable, so the spoke does not end up with a
# default route to a next hop that no longer exists.

set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../terraform"

: "${TF_DATA_DIR:=C:/tfd/w05}"
export TF_DATA_DIR

ALL=false
[[ "${1:-}" == "--all" ]] && ALL=true

if [[ "$ALL" == "true" ]]; then
  cat <<'WARN'
Destroying EVERYTHING, including the hub VNet and the private DNS estate.

Weeks 06 onward expect these to exist. Re-creating them is one apply, but any
private endpoint registered into a deleted zone loses its record, and any
peering from a later week has to be re-established.
WARN
  echo ""
  terraform destroy -input=false -auto-approve -var="deploy_firewall=false"
  echo ""
  echo "Everything destroyed."
  exit 0
fi

# The firewall is removed by re-applying the permanent layer with the flag off,
# not by `destroy -target`. A targeted destroy would leave the route table's
# 0.0.0.0/0 route pointing at an address that no longer answers; re-applying
# removes the route and the firewall together, in dependency order, because both
# are gated on the same variable.
# The apply's exit code is checked explicitly rather than trusted to `set -e`.
# Measured 2026-09-19: this teardown FAILED with
#
#   FirewallPolicyUpdateFailed - Put on Firewall Policy afwp-lz-dev... Failed
#   with 1 faulted referenced firewalls
#
# the firewall stayed up and kept billing, and the script still exited 0.
echo "Removing the firewall, keeping the hub..."
if ! terraform apply -input=false -auto-approve -var="deploy_firewall=false"; then
  echo "" >&2
  echo "THE APPLY FAILED. The firewall may still exist and may still be billing." >&2
  echo "Check, and delete it directly if so:" >&2
  echo "  az resource list -g $HUB_RG --subscription <sub> -o table" >&2
  echo "  az resource delete --ids <firewall-id>" >&2
  exit 1
fi

echo ""
echo "Verifying nothing billable survived..."
HUB_SUB=$(grep '^connectivity_subscription_id' terraform.tfvars | cut -d'"' -f2)

# `az resource list`, NOT `az network firewall list`.
#
# The latter needs the azure-firewall extension, and in a non-interactive shell
# the dynamic-install prompt dies with `EOFError: EOF when reading a line` -
# so the check that exists to catch a surviving firewall cannot itself run.
# This lab already learned that on `az account subscription list`.
left=$(az resource list --subscription "$HUB_SUB" --resource-group "$HUB_RG" \
         --query "[?type=='Microsoft.Network/azureFirewalls' || type=='Microsoft.Network/publicIPAddresses'].name" \
         -o tsv 2>/dev/null | tr -d '\r')

if [[ -z "$left" ]]; then
  echo "  Clean - no firewall, no public IPs. The permanent layer bills ~nothing."
else
  echo "  SOMETHING BILLABLE SURVIVED:" >&2
  sed 's/^/    /' <<< "$left" >&2
  exit 1
fi
