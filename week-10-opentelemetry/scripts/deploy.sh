#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Week 10 — deploy
#
#   ./scripts/deploy.sh
#
# The ordering here is the interesting part. The container apps reference
# images by tag, and Container Apps fails the revision if the tag does not
# resolve. So this runs in three passes:
#
#   1. create the registry only            (-target)
#   2. build and push the images INTO it   (az acr build)
#   3. apply everything else
#
# A single apply cannot work: the registry must exist before a build can push
# to it, and the images must exist before the apps can pull them. Week 04
# recorded that `-target` leaves a half-built object that looks finished - that
# is true, and it is why step 3 is a full, untargeted apply rather than more
# targeting.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

export MSYS_NO_PATHCONV=1
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors >/dev/null 2>&1 || true

WEEK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$WEEK_DIR/terraform"
APP_DIR="$WEEK_DIR/app"
TAG="${IMAGE_TAG:-v1}"

SUB_LAB=$(grep -E '^subscription_id' "$TF_DIR/terraform.tfvars" | cut -d'"' -f2)
[ -n "$SUB_LAB" ] || { echo "could not read subscription_id from terraform.tfvars"; exit 1; }

echo "══ 1. resource providers on sub-lab-dev ══"
for ns in Microsoft.App Microsoft.ContainerRegistry Microsoft.Insights Microsoft.OperationalInsights Microsoft.ManagedIdentity; do
  state=$(az provider show --namespace "$ns" --subscription "$SUB_LAB" \
            --query registrationState -o tsv --only-show-errors 2>/dev/null | tr -d '\r' || true)
  if [ "$state" != "Registered" ]; then
    echo "   registering $ns (currently ${state:-unknown})"
    az provider register --namespace "$ns" --subscription "$SUB_LAB" --only-show-errors >/dev/null
  else
    echo "   $ns already Registered"
  fi
done

for i in $(seq 1 40); do
  state=$(az provider show --namespace Microsoft.ContainerRegistry --subscription "$SUB_LAB" \
            --query registrationState -o tsv --only-show-errors 2>/dev/null | tr -d '\r' || true)
  [ "$state" = "Registered" ] && break
  echo "   waiting for Microsoft.ContainerRegistry: ${state:-unknown}"
  sleep 15
done

cd "$TF_DIR"
echo ""
echo "══ 2. terraform init ══"
terraform init -input=false || exit 1
terraform fmt -check || exit 1
terraform validate || exit 1

echo ""
echo "══ 3. the registry first, so there is somewhere to push ══"
set +e
terraform apply -input=false -auto-approve \
  -target=azurerm_resource_group.workload \
  -target=azurerm_container_registry.apps \
  -target=azurerm_user_assigned_identity.app \
  -target=azurerm_role_assignment.acr_pull
rc=$?
set -e
[ $rc -eq 0 ] || { echo "registry apply FAILED (exit $rc)"; exit $rc; }

ACR=$(terraform output -raw registry_name 2>/dev/null | tr -d '\r')
[ -n "$ACR" ] || { echo "no registry name in outputs"; exit 1; }

echo ""
echo "══ 4. build both images IN AZURE ══"
#
# az acr build runs the build on an ACR Task agent, not on this machine. No
# Docker daemon is needed locally, which also means the build does not depend
# on whatever happens to be installed on a laptop.
#
cd "$APP_DIR"
for svc in backend frontend; do
  echo ""
  echo "   -- $svc --"
  #
  # --no-logs is not a style preference. Streaming the build log back crashes
  # the Azure CLI on a Windows console: colorama writes the agent output
  # straight to the terminal in cp1252, pip emits a non-ASCII progress bar,
  # and the command dies with UnicodeEncodeError AFTER the build has already
  # succeeded in Azure. Measured 2026-10-23: `az acr task list-runs` reported
  # Succeeded for a build whose command had exited 1.
  #
  # So queue it without streaming and then ask Azure what happened. The run
  # status is the truth; the client exit code is not.
  set +e
  az acr build     --registry "$ACR"     --subscription "$SUB_LAB"     --image "wk10/$svc:$TAG"     --file "$svc/Dockerfile"     --no-logs     --only-show-errors     .
  rc=$?
  set -e

  status=$(az acr task list-runs --registry "$ACR" --subscription "$SUB_LAB" --top 1 --query "[0].status" -o tsv --only-show-errors 2>/dev/null | sed 's/[[:space:]]*$//') || true
  tag=$(az acr repository show-tags --name "$ACR" --repository "wk10/$svc" --subscription "$SUB_LAB" -o tsv --only-show-errors 2>/dev/null | sed 's/[[:space:]]*$//' | grep -x "$TAG") || true
  echo "   run status: ${status:-unknown} | tag $TAG present: ${tag:+yes}"

  if [ "$status" != "Succeeded" ] || [ -z "$tag" ]; then
    echo "build FAILED for $svc (cli exit $rc, run status ${status:-unknown})"
    exit 1
  fi
done

echo ""
echo "══ 5. everything else ══"
cd "$TF_DIR"
set +e
terraform apply -input=false -auto-approve -var "image_tag=$TAG"
rc=$?
set -e
[ $rc -eq 0 ] || { echo ""; echo "APPLY FAILED (exit $rc)"; exit $rc; }

echo ""
echo "══ 6. what was deployed ══"
terraform output

echo ""
echo "Deployed. Next: ./scripts/validate.sh"
