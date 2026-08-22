#!/usr/bin/env bash
# Strip standing write access from the app registrations that predate this lab.
#
# Five app registrations exist in the tenant. Two of them — TerraformTesting and
# jayanthkatta_sp — hold Contributor on the subscription and almost certainly
# carry live client secrets. Three more are abandoned azure-cli-2023-* device
# code logins. There are also role assignments held by bare object IDs whose
# principals no longer resolve to a name.
#
# This is a script rather than Terraform on purpose. Terraform cannot destroy a
# role assignment it never created without importing it first, and importing
# something in order to delete it leaves a worse audit trail than a script that
# prints exactly what it removed.
#
# Two phases, a week apart:
#
#   ./scripts/revoke-legacy-sp-access.sh revoke    remove role assignments (reversible)
#   ./scripts/revoke-legacy-sp-access.sh delete    delete the registrations (not reversible)
#
# Add --apply to either. Without it, the script only reports.

set -euo pipefail

LEGACY_APPS=(
  "TerraformTesting"
  "jayanthkatta_sp"
  "azure-cli-2023-01-27-03-38-22"
  "azure-cli-2023-02-10-01-38-41"
  "azure-cli-2023-02-15-16-08-57"
)

MODE="${1:-revoke}"
APPLY=0
[[ "${2:-}" == "--apply" ]] && APPLY=1

if [[ "$MODE" != "revoke" && "$MODE" != "delete" ]]; then
  echo "Usage: $0 [revoke|delete] [--apply]" >&2
  exit 2
fi

SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
LOG="revoke-legacy-sp-$(date +%Y%m%d-%H%M%S).log"

echo "Mode:         $MODE"
echo "Apply:        $([[ $APPLY -eq 1 ]] && echo yes || echo 'no — reporting only')"
echo "Log:          $LOG"
echo ""

{
  echo "run: $(date -u +%Y-%m-%dT%H:%M:%SZ)  mode=$MODE apply=$APPLY"
} >> "$LOG"

for app in "${LEGACY_APPS[@]}"; do
  echo "── $app"

  app_id=$(az ad app list --display-name "$app" --query "[0].appId" -o tsv 2>/dev/null || true)
  if [[ -z "$app_id" ]]; then
    echo "   not found — already removed"
    continue
  fi

  sp_object_id=$(az ad sp show --id "$app_id" --query id -o tsv 2>/dev/null || true)

  if [[ "$MODE" == "revoke" ]]; then
    if [[ -z "$sp_object_id" ]]; then
      echo "   app registration exists but has no service principal — no assignments to strip"
      continue
    fi

    # --all so assignments at management group scope are included, not just
    # those at or below the current subscription.
    mapfile -t assignments < <(
      az role assignment list --all --assignee "$sp_object_id" \
        --query "[].{id:id,role:roleDefinitionName,scope:scope}" -o tsv 2>/dev/null || true
    )

    if [[ ${#assignments[@]} -eq 0 ]]; then
      echo "   no role assignments"
      continue
    fi

    for row in "${assignments[@]}"; do
      IFS=$'\t' read -r assignment_id role scope <<< "$row"
      echo "   $role  on  $scope"
      echo "   $app  $role  $scope  $assignment_id" >> "$LOG"

      if [[ $APPLY -eq 1 ]]; then
        # NOT `az role assignment delete`. On CLI 2.86.0 every form of that
        # command — --ids, --ids with --subscription, and --assignee/--role/
        # --scope — fails with:
        #
        #   (MissingSubscription) The request did not have a subscription or a
        #   valid tenant level resource provider.
        #
        # The read path (`az role assignment list`) works fine against the same
        # scope with the same credentials, so the error is not about access. The
        # ARM call underneath is well-formed and succeeds when issued directly,
        # which is what this does. Verified 2026-08-22.
        if az rest --method delete \
             --url "https://management.azure.com${assignment_id}?api-version=2022-04-01" \
             >/dev/null 2>&1; then
          echo "     removed"
          echo "   REMOVED $assignment_id" >> "$LOG"
        else
          echo "     FAILED — assignment left in place"
          echo "   FAILED  $assignment_id" >> "$LOG"
        fi
      fi
    done

  else # delete
    echo "   app registration $app_id"
    echo "   delete $app $app_id" >> "$LOG"

    if [[ $APPLY -eq 1 ]]; then
      # Deleted app registrations sit in the Entra deleted-items container for
      # 30 days and can be restored from there — this is recoverable for a month,
      # but the client secrets do not survive a restore.
      az ad app delete --id "$app_id"
      echo "     deleted (recoverable from Entra deleted items for 30 days)"
    fi
  fi
done

echo ""
echo "Assignments held by object IDs with no resolvable principal:"
az role assignment list --all --query \
  "[?principalName==null].{role:roleDefinitionName,principalId:principalId,scope:scope}" \
  -o table 2>/dev/null || echo "  none"

echo ""
echo "These are orphaned — the principal was deleted while the assignment was"
echo "left behind. They grant nothing, but they clutter every access review."
echo "Remove them by ID once you have confirmed none belongs to a live identity."

if [[ $APPLY -eq 0 ]]; then
  echo ""
  echo "Nothing was changed. Re-run with --apply to act."
fi

echo ""
# Name, not ID — this output lands in transcripts and screenshots.
echo "Subscription swept: $SUBSCRIPTION_NAME"
echo "Log written to $LOG"
