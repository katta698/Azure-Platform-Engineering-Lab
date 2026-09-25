#!/usr/bin/env bash
# Week 06 — teardown.
#
#   ./scripts/cleanup.sh
#
# The protected resources cannot be deleted directly - that is the entire point
# of the week. They are removed by deleting the STACK, which drops its deny
# assignment and then acts on what it managed.
#
#   az stack mg delete --action-on-unmanage deleteAll
#
# `deleteAll` matters. The DEFAULT is detach: "By default, deployment stacks
# detach and don't delete unmanaged resources." A teardown that omits the flag
# leaves every resource running and merely stops tracking them - the storage
# accounts survive, unowned, and nothing says so.
#
# Three ways this can fail, all documented and all handled below:
#
#   * permission. "Update or delete a deployment stack with an existing deny
#     setting of a value other than None" needs rights at the stack scope.
#     Deployment Stack CONTRIBUTOR cannot; Owner can.
#   * the stack-out-of-sync error, which refuses the delete rather than risk
#     removing something unexpected. The bypass flag is deliberately NOT used
#     here - it deletes whatever the list happens to contain.
#   * a resource group containing resources the stack does not manage will not
#     be removed, and neither will those resources.

set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

: "${TF_DATA_DIR:=C:/tfd/w06}"
export TF_DATA_DIR

STACK_NAME="stack-wk06-protected"
STACK_MG="mg-lz-dev"
SUB=$(grep '^subscription_id' terraform/terraform.tfvars | cut -d'"' -f2)
PROTECTED_RG="rg-wk06-protected-dev-scus-001"
CONTROL_RG="rg-wk06-control-dev-scus-001"

# ── 1. The stack, and everything it manages ─────────────────────────────────
echo "Deleting the stack and the resources it protects..."
if az stack mg show --name "$STACK_NAME" --management-group-id "$STACK_MG" -o none 2>/dev/null; then
  if ! az stack mg delete \
        --name "$STACK_NAME" \
        --management-group-id "$STACK_MG" \
        --action-on-unmanage deleteAll \
        --yes -o none; then
    echo "" >&2
    echo "THE STACK DELETE FAILED. Its resources are still protected and still exist." >&2
    echo "Read the error above before retrying. If it is the out-of-sync error, list" >&2
    echo "the managed resources first and confirm they are what you expect:" >&2
    echo "  az stack mg show --name $STACK_NAME --management-group-id $STACK_MG --query resources" >&2
    exit 1
  fi
  echo "  stack deleted, deny assignment gone, managed resources removed"
else
  echo "  no stack found - nothing to delete"
fi
echo ""

# ── 2. The control, in Terraform ────────────────────────────────────────────
echo "Destroying the control..."
( cd terraform && terraform destroy -input=false -auto-approve )
echo ""

# ── 3. Verify against Azure, not against exit codes ─────────────────────────
#
# Week 05's teardown reported success while a firewall kept billing, because it
# trusted an exit code and used a verification command that could not run. This
# checks the resource groups directly.
echo "Verifying nothing survived..."
left=""
for rg in "$PROTECTED_RG" "$CONTROL_RG"; do
  if az group show --name "$rg" --subscription "$SUB" -o none 2>/dev/null; then
    left="$left $rg"
  fi
done

if [[ -z "$left" ]]; then
  echo "  Clean - both resource groups are gone."
else
  echo "  STILL PRESENT:$left" >&2
  echo "  A resource group survives when it holds resources the stack did not manage." >&2
  exit 1
fi

rm -f .protected-storage-account
