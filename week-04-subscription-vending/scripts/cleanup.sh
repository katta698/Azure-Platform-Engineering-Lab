#!/usr/bin/env bash
# Week 04 — teardown, and the honest limits of it.
#
#   ./scripts/cleanup.sh                  destroy everything destroyable
#   ./scripts/cleanup.sh --decommission   decommission a vended subscription too
#
# Most of this week tears down completely: budgets and role assignments are
# ordinary resources and `terraform destroy` removes them.
#
# A vended subscription does not. It is the one object this lab can create and
# cannot delete:
#
#   * cancelling stops billing immediately
#   * the Delete option does not appear for THREE DAYS
#   * Azure deletes it automatically only after NINETY DAYS
#
# So "cleanup" for a subscription means decommission, not delete.
#
# ── ORDER MATTERS, and this script had it wrong first time ──────────────────
#
# `terraform destroy` on azurerm_subscription CANCELS the subscription. It does
# not merely drop it from state. Measured 2026-09-11: the destroy of the alias
# took 1m39s, and afterwards ARM refused every write with
#
#   (ReadOnlyDisabledSubscription) The subscription is disabled and therefore
#   marked as read only.
#
# A deny-all probe run after that never reaches policy evaluation — it is
# refused for being cancelled, which proves nothing about the policy. The
# explicit cancel then fails too, with "Subscription is not in active state".
#
# So: MOVE and PROBE first, while the subscription is still active. DESTROY
# last, and let the destroy be the thing that cancels it.

set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../terraform"

: "${TF_DATA_DIR:=C:/tfd/w04}"
export TF_DATA_DIR

DECOMMISSION=false
[[ "${1:-}" == "--decommission" ]] && DECOMMISSION=true

VENDED_ID=$(terraform output -raw vended_subscription_id 2>/dev/null || echo "")
[[ "$VENDED_ID" == "null" ]] && VENDED_ID=""

# ── 1. Decommission, BEFORE anything is destroyed ───────────────────────────
if [[ -n "$VENDED_ID" && "$DECOMMISSION" == "true" ]]; then
  echo "Moving $VENDED_ID to mg-decommissioned..."
  az account management-group subscription add \
    --name mg-decommissioned --subscription "$VENDED_ID" -o none
  echo "  moved"
  echo ""

  # Management group placement takes a moment to be reflected in policy
  # evaluation. Probing immediately is how you get a pass that means nothing.
  echo "Waiting for the placement to take effect..."
  sleep 30

  echo "Proving the deny-all actually denies..."
  set +e
  OUT=$(az group create --name rg-decomm-probe-001 --location southcentralus \
          --subscription "$VENDED_ID" 2>&1)
  RC=$?
  set -e

  if [[ $RC -ne 0 ]] && grep -qiE 'RequestDisallowedByPolicy|disallowed by policy' <<< "$OUT"; then
    echo "  DENIED BY POLICY, as intended:"
    sed -n 's/.*Reasons: //p' <<< "$OUT" | head -1 | cut -c1-200 | sed 's/^/    /'
  elif [[ $RC -ne 0 ]] && grep -qi 'ReadOnlyDisabledSubscription' <<< "$OUT"; then
    echo "  INCONCLUSIVE — the subscription is already cancelled, so the write was" >&2
    echo "  refused before policy was evaluated. This proves nothing about the" >&2
    echo "  deny-all. It means the destroy ran before the probe." >&2
  elif [[ $RC -ne 0 ]]; then
    echo "  the probe failed, but not with a policy denial — read this before trusting it:" >&2
    head -3 <<< "$OUT" >&2
  else
    echo "  NOT DENIED. A resource group was created in a decommissioned subscription." >&2
    echo "  Check PLACEMENT before the assignment: every property of a policy" >&2
    echo "  assignment can be correct while the assignment governs nothing." >&2
    az group delete --name rg-decomm-probe-001 --subscription "$VENDED_ID" --yes -o none || true
  fi
  echo ""
fi

# ── 2. Destroy ──────────────────────────────────────────────────────────────
#
# For a vended subscription this is also the cancel: destroying the alias
# resource cancels the subscription, which is why it runs after the probe.
echo "Destroying the vended payload..."
terraform destroy -input=false -auto-approve \
  -var="vend_new_subscription=$([[ -n "$VENDED_ID" ]] && echo true || echo false)"
echo ""

# ── 3. Report what survives ─────────────────────────────────────────────────
if [[ -z "$VENDED_ID" ]]; then
  echo "No subscription was vended by this state."
  echo "Clean — nothing this run created remains."
  exit 0
fi

if [[ "$DECOMMISSION" != "true" ]]; then
  cat <<MSG
A subscription was vended by this week:

  $VENDED_ID

The destroy above CANCELLED it. It is not deleted, because nothing can delete it
today. To also move it out of the landing zone tree and prove the deny-all in
mg-decommissioned refuses a deployment, re-run with --decommission BEFORE the
destroy — that ordering is the whole point of the flag.
MSG
  exit 0
fi

cat <<MSG
Decommissioned.

  subscription   $VENDED_ID
  management gp  mg-decommissioned
  state          cancelled by the destroy, billing stopped

It still exists, and that is not a failure of this script. The Delete option
appears three days after cancellation; Azure removes it automatically after
ninety. Note the date.
MSG
