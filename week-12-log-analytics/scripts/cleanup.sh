#!/usr/bin/env bash
# Week 12 — teardown.
#
# NOTE: this week is one of the three the roadmap keeps running (05 hub, 12
# Log Analytics, 47 FinOps hub). Weeks 13 to 16 all send data here, so the
# default is to KEEP it. The script exists so the week can be torn down and
# rebuilt, and so "it was never run" is not an excuse.
#
#   ./scripts/cleanup.sh            refuses, and says why
#   ./scripts/cleanup.sh --force    actually destroys it

set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

: "${TF_DATA_DIR:=C:/tfd/w12}"
export TF_DATA_DIR

SUB=$(grep '^subscription_id' terraform/terraform.tfvars | cut -d'"' -f2)
RG="rg-observability-prod-scus-001"

if [[ "${1:-}" != "--force" ]]; then
  echo "This week is designed to STAY UP. Weeks 13-16 send their data here, and"
  echo "the workspace costs nothing while idle - ingestion is what bills."
  echo ""
  echo "Pass --force if you really mean it."
  exit 0
fi

( cd terraform && terraform destroy -input=false -auto-approve )

echo ""
echo "Verifying nothing survived..."
if az group show --name "$RG" --subscription "$SUB" -o none 2>/dev/null; then
  echo "  STILL PRESENT: $RG" >&2
  exit 1
fi
echo "  Clean - the resource group is gone."

# A deleted workspace is SOFT-deleted for 14 days and its name stays reserved.
# Re-running deploy.sh inside that window fails on a name conflict unless the
# workspace is recovered or purged, which is not obvious from the error.
echo ""
echo "  Note: the workspace is soft-deleted for 14 days and its name stays taken."
echo "  To rebuild sooner, recover it instead of creating a new one:"
echo "    az monitor log-analytics workspace recover -g $RG -n log-platform-prod-scus-001"
