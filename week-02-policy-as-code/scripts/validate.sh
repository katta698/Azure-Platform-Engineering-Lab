#!/usr/bin/env bash
# Week 02 — prove the policy fixes what it found, or prove why it could not.
#
# The order below is the only order that works, and each step is here because
# skipping it produces a convincing wrong answer:
#
#   1. force an evaluation      — remediation acts on what the last COMPLETED
#                                 scan flagged. Straight after an apply that is
#                                 an empty list, and a task over an empty list
#                                 succeeds having done nothing
#   2. read compliance          — how many resources are actually non-compliant
#   3. create remediation tasks — one per initiative reference, by reference id
#   4. poll them                — a task is a job. "Created" is not "finished"
#   5. check the resources      — the only real evidence. A succeeded task and a
#                                 storage account with no diagnostic setting is
#                                 a thing that happens, and the task is not
#                                 where you would notice
#
# What counts as a pass depends on the deployed stage. In the no-grants stage a
# FAILED remediation is the correct result, and reporting it as a failure of the
# week would be reporting the experiment as broken because it worked.

set -uo pipefail

# Git Bash rewrites arguments that start with a slash into Windows paths.
# Every scope, assignment ID and resource ID here starts with one.
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../terraform"

RG=$(terraform output -raw test_resource_group 2>/dev/null)
STAGE=$(terraform output -raw stage 2>/dev/null || echo unknown)
ASSIGNMENT_ID=$(terraform output -raw assignment_id 2>/dev/null)
WORKSPACE_ID=$(terraform output -raw log_analytics_workspace_id 2>/dev/null)
SUBSCRIPTION_ID=$(grep '^subscription_id' terraform.tfvars | cut -d'"' -f2)
MG="mg-lz-dev"
SETTING_NAME="diag-to-law"
TAG_NAME="cost-center"

if [[ -z "$RG" || -z "$ASSIGNMENT_ID" ]]; then
  echo "Could not read the Terraform outputs. Run deploy.sh first." >&2
  exit 1
fi

case "$STAGE" in
  AUDIT*)                      MODE=audit     ;;
  "REMEDIATING WITHOUT"*)      MODE=no-grants ;;
  REMEDIATING*)                MODE=remediate ;;
  *) echo "Unrecognised stage: $STAGE" >&2; exit 1 ;;
esac

echo "Stage: $STAGE"
echo ""

pass=0
fail=0

note() { echo "   $*"; }
ok()   { echo "   RESULT: $*"; pass=$((pass + 1)); }
bad()  { echo "   RESULT: $*"; fail=$((fail + 1)); }

# Name, resource ID and tag in ONE call per run rather than two calls per
# account. The first version read the ID back with a separate `az storage
# account show` per account, and one of those returned a Bad Request mid-run —
# leaving an empty resource ID, which the next command rejected as a usage
# error. Fewer calls is not the point; not having a lookup that can half-fail
# between two checks of the same resource is.
storage_inventory() {
  az storage account list --resource-group "$RG" --subscription "$SUBSCRIPTION_ID"     --query "[].[name, id, tags.\"$TAG_NAME\"]" -o tsv
}

# ── 1. Force an evaluation ──────────────────────────────────────────────────
#
# Policy evaluates on resource write immediately — that is why week 01's deny
# was instant. The scan of resources that already exist is scheduled: roughly
# 15 minutes after a change, ~30 after a subscription moves, and every 24 hours
# otherwise. trigger-scan blocks until it completes, which is why this takes a
# few minutes and why it is worth doing rather than sleeping and hoping.
echo "── Forcing a compliance scan over $RG (a few minutes)"
if az policy state trigger-scan --resource-group "$RG" --subscription "$SUBSCRIPTION_ID" -o none 2>/dev/null; then
  note "scan complete"
else
  note "trigger-scan failed. Microsoft.PolicyInsights registration is the usual"
  note "cause; without it the portal reports 100% (0 of 0), which reads as"
  note "compliant rather than never-evaluated."
fi
echo ""

# ── 2. What the scan found ──────────────────────────────────────────────────
echo "── Compliance for this assignment, per rule"
az policy state summarize \
  --resource-group "$RG" \
  --subscription "$SUBSCRIPTION_ID" \
  --filter "PolicyAssignmentId eq '$ASSIGNMENT_ID'" \
  --query "policyAssignments[0].policyDefinitions[].{rule:policyDefinitionReferenceId, nonCompliant:results.nonCompliantResources}" \
  -o table 2>/dev/null || note "no compliance data yet"
echo ""

if [[ "$MODE" == "audit" ]]; then
  # The assignment carries an identity even here, because Azure requires one on
  # any assignment whose definitions contain a deployment — the effect selected
  # does not enter into it. So the check is not "is there an identity" but "did
  # anything change", which is the question an audit stage actually answers.
  echo "── The assignment carries an identity even in audit mode"
  identity=$(az policy assignment show --name "assign-remediation-dev" \
    --scope "/providers/Microsoft.Management/managementGroups/$MG" \
    --query "identity.type" -o tsv 2>/dev/null || echo "None")
  note "identity type: ${identity:-None} — required by the definition, idle at this effect"
  echo ""

  echo "── Nothing may have been changed by an audit"
  while IFS=$'	' read -r name id tag; do
    [[ -z "$name" ]] && continue
    # A bare array, not an object with a value property. `value[?...]` resolves
    # to null, length(null) is a CLI error, and with the error swallowed the
    # count reads as zero — a check that passes because the lookup broke.
    setting=$(az monitor diagnostic-settings list --resource "$id" \
                --query "length([?name=='$SETTING_NAME'])" -o tsv) || setting="ERROR"

    if [[ "$setting" == "ERROR" ]]; then
      bad "$name could not be read — a lookup that fails is not evidence of anything"
    elif [[ "$setting" == "0" && ( -z "$tag" || "$tag" == "None" ) ]]; then
      ok "$name untouched — reported, not fixed"
    else
      bad "$name changed during an audit-only stage"
    fi
  done < <(storage_inventory)
  echo ""

  echo "$pass passed, $fail failed."
  echo ""
  echo "The non-compliant count above is the preview of what stage 2 will change."
  echo "Next: ./scripts/deploy.sh no-grants"
  [[ $fail -eq 0 ]] || exit 1
  exit 0
fi

# ── 3 and 4. Remediation tasks ──────────────────────────────────────────────
#
# One task per initiative reference. A task names exactly one policy definition
# reference — there is no "remediate the whole initiative" — and a task naming a
# reference the initiative does not contain succeeds having found nothing.
#
# ExistingNonCompliant (the default) acts on what step 1 just flagged.
# ReEvaluateCompliance would evaluate first, but it re-scans the entire
# assignment scope, which at management group scope is every subscription
# underneath it.
remediate_ref() {
  local ref="$1" expect="$2"
  local name="remediate-${ref}-$(date +%H%M%S)"

  echo "── Remediating: $ref"
  note "expecting: $expect"

  if ! az policy remediation create \
        --name "$name" \
        --management-group "$MG" \
        --policy-assignment "$ASSIGNMENT_ID" \
        --definition-reference-id "$ref" \
        --resource-discovery-mode ExistingNonCompliant \
        -o none 2>/tmp/wk02-remediate.err; then
    note "the task could not be created:"
    sed 's/^/     /' /tmp/wk02-remediate.err | head -5
    bad "no task — this is a control-plane refusal, not a remediation failure"
    echo ""
    return
  fi

  # A remediation task is asynchronous. Creating it returns immediately with
  # provisioningState Accepted, and the deployments it spawns run afterwards.
  local state="" waited=0
  while [[ $waited -lt 300 ]]; do
    state=$(az policy remediation show --name "$name" --management-group "$MG" \
              --query "provisioningState" -o tsv 2>/dev/null || echo Unknown)
    [[ "$state" == "Succeeded" || "$state" == "Failed" || "$state" == "Canceled" ]] && break
    sleep 15
    waited=$((waited + 15))
  done

  read -r total succeeded failed <<<"$(az policy remediation show \
    --name "$name" --management-group "$MG" \
    --query "[deploymentStatus.totalDeployments, deploymentStatus.successfulDeployments, deploymentStatus.failedDeployments]" \
    -o tsv 2>/dev/null | tr '\t' ' ')"

  total=${total:-0}; succeeded=${succeeded:-0}; failed=${failed:-0}
  note "task $state after ${waited}s — $total deployment(s), $succeeded succeeded, $failed failed"

  # The error text is the whole point of the no-grants stage. It names the
  # deployment and the missing permission, never the role assignment that was
  # not made, which is why this failure is usually diagnosed as the wrong thing.
  if [[ "${failed:-0}" != "0" ]]; then
    az policy remediation deployment list --name "$name" --management-group "$MG" \
      --query "[?status!='Succeeded'].error.message" -o tsv 2>/dev/null \
      | head -2 | fold -w 100 -s | sed 's/^/     /'
  fi

  if [[ "$expect" == "succeed" ]]; then
    if [[ "$state" == "Succeeded" && "${failed:-0}" == "0" && "${total:-0}" != "0" ]]; then
      ok "remediated $succeeded resource(s)"
    elif [[ "${total:-0}" == "0" ]]; then
      bad "nothing to remediate — the scan found no non-compliant resource, so the task did nothing and still reported success"
    else
      bad "$failed deployment(s) failed"
    fi
  else
    if [[ "${failed:-0}" != "0" || "$state" == "Failed" ]]; then
      ok "failed, as expected — the identity holds no role at the remediation scope"
    else
      bad "succeeded without any grant, which should not be possible"
    fi
  fi
  echo ""
}

if [[ "$MODE" == "no-grants" ]]; then
  EXPECT=fail
else
  EXPECT=succeed
fi

remediate_ref "storage-diagnostics" "$EXPECT"
remediate_ref "inherit-tag" "$EXPECT"

# ── 5. The resources themselves ─────────────────────────────────────────────
#
# The only evidence that counts. Everything above is Azure reporting on its own
# work; this reads the resources back.
echo "── What the storage accounts actually look like now"
while IFS=$'	' read -r name id tag; do
  [[ -z "$name" ]] && continue
  [[ "$tag" == "None" ]] && tag=""

  setting=$(az monitor diagnostic-settings list --resource "$id" \
              --query "[?name=='$SETTING_NAME'].workspaceId | [0]" -o tsv) || setting="ERROR"

  echo "   $name"
  echo "     diagnostic setting '$SETTING_NAME': ${setting:-none}"
  echo "     $TAG_NAME tag: ${tag:-none}"

  if [[ "$MODE" == "remediate" ]]; then
    # Compare against the workspace the policy was parameterised with, not
    # merely "a setting exists". A setting pointing somewhere else satisfies a
    # careless check and satisfies nothing else.
    if [[ "$setting" == "ERROR" ]]; then
      bad "$name could not be read"
    elif [[ "$setting" == "$WORKSPACE_ID" ]]; then
      ok "$name sends diagnostics to the lab workspace"
    else
      bad "$name has no diagnostic setting pointing at the lab workspace"
    fi

    if [[ -n "$tag" ]]; then
      ok "$name inherited $TAG_NAME=$tag"
    else
      bad "$name is still missing the $TAG_NAME tag"
    fi
  else
    if [[ -z "$setting" && -z "$tag" ]]; then
      ok "$name is unchanged — nothing was applied without a grant"
    else
      bad "$name changed despite the identity holding no roles"
    fi
  fi
done < <(storage_inventory)
echo ""

echo "$pass passed, $fail failed."
if [[ "$MODE" == "no-grants" ]]; then
  echo ""
  echo "This stage is meant to fail its deployments. Screenshot the error above,"
  echo "then: ./scripts/deploy.sh remediate"
fi
[[ $fail -eq 0 ]] || exit 1
