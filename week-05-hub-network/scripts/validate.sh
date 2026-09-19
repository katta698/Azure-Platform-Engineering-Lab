#!/usr/bin/env bash
# Week 05 — check the hub is a hub, not a collection of networks.
#
#   1. both peerings report Connected, not Initiated
#   2. every private DNS zone is linked to BOTH virtual networks
#   3. the firewall subnets exist and are correctly named and sized
#   4. the spoke's default route points at the firewall - when one is deployed
#   5. no drift
#
# Checks 1 and 2 are the week. A peering declared from one side only, and a DNS
# zone linked to the hub only, are both resources that exist, report healthy,
# and do nothing.

set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../terraform"

: "${TF_DATA_DIR:=C:/tfd/w05}"
export TF_DATA_DIR

HUB_SUB=$(grep '^connectivity_subscription_id' terraform.tfvars | cut -d'"' -f2)
SPOKE_SUB=$(grep '^spoke_subscription_id' terraform.tfvars | cut -d'"' -f2)
LAYER=$(terraform output -raw layer 2>/dev/null || echo unknown)
FW_IP=$(terraform output -raw firewall_private_ip 2>/dev/null || echo "")
[[ "$FW_IP" == "null" ]] && FW_IP=""

HUB_RG=rg-hub-connectivity-prod-scus-001
SPOKE_RG=rg-spoke-lab-dev-scus-001
HUB_VNET=vnet-hub-prod-scus-001
SPOKE_VNET=vnet-spoke-lab-dev-scus-001

pass=0; fail=0
note() { echo "   $*"; }
ok()   { echo "   RESULT: $*"; pass=$((pass + 1)); }
bad()  { echo "   RESULT: $*"; fail=$((fail + 1)); }

echo "Layer: $LAYER"
echo ""

# ── 1. peering state ────────────────────────────────────────────────────────
echo "1. Both peerings report Connected"
h=$(az network vnet peering show --name peer-hub-to-spoke-lab-dev \
      --vnet-name "$HUB_VNET" --resource-group "$HUB_RG" --subscription "$HUB_SUB" \
      --query peeringState -o tsv 2>/dev/null | tr -d '\r')
s=$(az network vnet peering show --name peer-spoke-lab-dev-to-hub \
      --vnet-name "$SPOKE_VNET" --resource-group "$SPOKE_RG" --subscription "$SPOKE_SUB" \
      --query peeringState -o tsv 2>/dev/null | tr -d '\r')
note "hub  -> spoke: ${h:-<missing>}"
note "spoke -> hub:  ${s:-<missing>}"
if [[ "$h" == "Connected" && "$s" == "Connected" ]]; then
  ok "both sides Connected - traffic can actually cross"
else
  bad "a peering that is Initiated exists but carries nothing"
fi
echo ""

# ── 2. DNS links on both VNets ──────────────────────────────────────────────
echo "2. Every private DNS zone is linked to BOTH virtual networks"
zones=$(az network private-dns zone list --subscription "$HUB_SUB" --resource-group "$HUB_RG" \
          --query "[].name" -o tsv 2>/dev/null | tr -d '\r')
zcount=$(grep -c . <<< "$zones")
note "zones in the hub: $zcount"
short=0
while read -r z; do
  [[ -z "$z" ]] && continue
  n=$(az network private-dns link vnet list --subscription "$HUB_SUB" \
        --resource-group "$HUB_RG" --zone-name "$z" --query "length(@)" -o tsv 2>/dev/null | tr -d '\r')
  [[ "${n:-0}" -lt 2 ]] && { note "  $z has only ${n:-0} link(s)"; short=$((short+1)); }
done <<< "$zones"
if [[ "$zcount" -gt 0 && "$short" -eq 0 ]]; then
  ok "all $zcount zones linked to hub and spoke"
else
  bad "$short zone(s) linked to fewer than two VNets - resolution is wrong somewhere"
fi
echo ""

# ── 3. the firewall subnets ─────────────────────────────────────────────────
echo "3. The firewall subnets exist, named and sized as Azure requires"
# The value is read from `addressPrefixes[0]`, not `addressPrefix`.
# The singular field is still present in the response and is now NULL - the
# prefix moved into a plural array. Querying the old field returns empty, which
# is indistinguishable from "the subnet does not exist", so a subnet created
# correctly reported as missing. Measured 2026-09-19.
sub_fail=0
for sn in AzureFirewallSubnet AzureFirewallManagementSubnet; do
  pre=$(az network vnet subnet show --name "$sn" --vnet-name "$HUB_VNET" \
          --resource-group "$HUB_RG" --subscription "$HUB_SUB" \
          --query "addressPrefixes[0] || addressPrefix" -o tsv 2>/dev/null | tr -d '\r')
  if [[ -z "$pre" || "$pre" == "None" ]]; then
    note "$sn is missing"; sub_fail=$((sub_fail+1)); continue
  fi
  note "$sn  $pre"
  size="${pre##*/}"
  if [[ "$size" -gt 26 ]]; then
    note "  /$size is smaller than the /26 Azure requires"; sub_fail=$((sub_fail+1))
  fi
done
if [[ "$sub_fail" -eq 0 ]]; then
  ok "both subnets present at /26 or larger"
else
  bad "$sub_fail firewall subnet problem(s)"
fi
echo ""

# ── 4. the route ────────────────────────────────────────────────────────────
echo "4. The spoke's default route points at the firewall"
if [[ -z "$FW_IP" ]]; then
  note "no firewall deployed - the 0.0.0.0/0 route is intentionally absent"
  note "SKIPPED"
else
  hop=$(az network route-table route show --name udr-default-to-firewall \
          --route-table-name rt-spoke-lab-dev-scus-001 --resource-group "$SPOKE_RG" \
          --subscription "$SPOKE_SUB" --query nextHopIpAddress -o tsv 2>/dev/null | tr -d '\r')
  note "next hop: ${hop:-<none>}   firewall: $FW_IP"
  if [[ "$hop" == "$FW_IP" ]]; then
    ok "the route sends the spoke's egress through the firewall"
  else
    bad "the route does not point at the firewall - it is deployed but carries nothing"
  fi
fi
echo ""

# ── 5. drift ────────────────────────────────────────────────────────────────
echo "5. The deployed state matches the configuration"
FW_FLAG=$([[ -n "$FW_IP" ]] && echo true || echo false)
terraform plan -input=false -detailed-exitcode -no-color -var="deploy_firewall=$FW_FLAG" >/dev/null 2>&1
case $? in
  0) ok "no drift" ;;
  2) bad "the plan proposes changes" ;;
  *) bad "the plan errored" ;;
esac
echo ""

echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
