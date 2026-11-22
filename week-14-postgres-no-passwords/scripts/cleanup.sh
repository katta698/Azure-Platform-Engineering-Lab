#!/usr/bin/env bash
# Week 14 — teardown, verified against Azure rather than against the exit
# code of the destroy.
#
# A failed teardown here costs about $13/day: compute with a standby, a VM, a
# NAT gateway and a private endpoint. Week 05's teardown reported success
# while a firewall kept billing, which is why the counts below are asked of
# Azure after the destroy rather than inferred from it.
#
# Usage:  bash week-14-postgres-no-passwords/scripts/cleanup.sh
set -uo pipefail
export MSYS_NO_PATHCONV=1

HERE="$(cd "$(dirname "$0")" && pwd)"
RG="rg-pgnopass-lab-dev-scus-001"

# MSYS_NO_PATHCONV=1 is needed above so Azure resource IDs survive the trip
# to `az`, and it also stops Git Bash rewriting a POSIX path on its way to a
# NATIVE binary -- so Windows Python receives /c/Projects/... and cannot open
# it. Anything handed to python gets a Windows path.
ROOT="$(cygpath -w "$(cd "$HERE/../.." && pwd)")"

echo "== figures first -- teardown is the only irreversible step in a week"
python "$ROOT\scripts\check_figures_before_destroy.py" week-14-postgres-no-passwords
rc=$?
[ $rc -eq 0 ] || { echo "figure check failed ($rc). NOT destroying."; exit $rc; }

echo
echo "== deleting the resource group   $(date -u +%H:%M:%SZ)"
# The group goes first and whole: it catches anything Terraform never
# managed, and a flexible server with HA is slow enough that doing it any
# other way invites a half-destroyed state that keeps billing.
if az group show -n "$RG" -o none 2>/dev/null; then
  az group delete -n "$RG" --yes --no-wait -o none
  for i in $(seq 1 60); do
    az group show -n "$RG" -o none 2>/dev/null || break
    sleep 30
  done
fi

echo "== terraform destroy (clears state of anything already gone)"
cd "$HERE/../terraform"
terraform destroy -input=false -auto-approve
echo "  destroy exit: $?  -- not trusted, see the counts below"

echo
echo "== what Azure says is left   $(date -u +%H:%M:%SZ)"
left=0
count() {   # $1 label   $2 resource type
  n=$(az resource list --query "length([?type=='$2'])" -o tsv 2>/dev/null | tr -d "\r")
  n=${n:-unknown}
  printf "  %-34s %s\n" "$1" "$n"
  [ "$n" = "0" ] || left=$((left+1))
}
count "PostgreSQL flexible servers" "Microsoft.DBforPostgreSQL/flexibleServers"
count "virtual machines"            "Microsoft.Compute/virtualMachines"
count "managed disks"               "Microsoft.Compute/disks"
count "private endpoints"           "Microsoft.Network/privateEndpoints"
count "NAT gateways"                "Microsoft.Network/natGateways"
count "public IP addresses"         "Microsoft.Network/publicIPAddresses"
count "private DNS zones"           "Microsoft.Network/privateDnsZones"

RG_LEFT=$(az group list --query "length([?name=='$RG'])" -o tsv 2>/dev/null | tr -d "\r")
printf "  %-34s %s\n" "the resource group" "${RG_LEFT:-unknown}"
[ "${RG_LEFT:-1}" = "0" ] || left=$((left+1))

echo
if [ "$left" = "0" ]; then
  echo "  clean. Nothing from this week is billing."
else
  echo "  $left CHECK(S) NOT ZERO -- something is still running and still"
  echo "  billing. Do not call the week done."
  exit 1
fi
