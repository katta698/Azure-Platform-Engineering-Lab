#!/usr/bin/env bash
# Week 14 — deploy. Everything in this week bills per hour, so the clock
# starts here and cleanup.sh runs the same day.
#
# Usage:  bash week-14-postgres-no-passwords/scripts/deploy.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1

HERE="$(cd "$(dirname "$0")" && pwd)"
TF="$HERE/../terraform"

# MSYS_NO_PATHCONV=1 is needed above so Azure resource IDs survive the trip
# to `az`, and it also stops Git Bash rewriting a POSIX path on its way to a
# NATIVE binary -- so Windows Python receives /c/Projects/... and cannot open
# it. Anything handed to python gets a Windows path.
ROOT="$(cygpath -w "$(cd "$HERE/../.." && pwd)")"

echo "== provider registration (subscription-wide, deliberately not in Terraform)"
for p in Microsoft.DBforPostgreSQL Microsoft.Network Microsoft.Compute Microsoft.ManagedIdentity; do
  state=$(az provider show -n "$p" --query registrationState -o tsv 2>/dev/null | tr -d '\r')
  if [ "$state" != "Registered" ]; then
    echo "  registering $p (was $state)"
    az provider register -n "$p" >/dev/null
  else
    echo "  $p Registered"
  fi
done

echo
echo "== cost gate"
# Run once, to a file: a second run to show the failure would mean a second
# trip through a few thousand meters and another chance at a 429. Exit 2 is
# "a service could not be priced at all", which proves nothing either way.
GATE="$(mktemp)"
if ! python "$ROOT\scripts\price_check.py" week-14-postgres-no-passwords >"$GATE" 2>&1; then
  tail -20 "$GATE"; rm -f "$GATE"
  echo "cost gate failed. Not deploying."
  exit 1
fi
rm -f "$GATE"
echo "  every flat meter acknowledged in meters.json"

echo
echo "== terraform apply   $(date -u +%H:%M:%SZ)"
cd "$TF"
# An apply can fail while the calling script exits 0 through a pipeline --
# week 05 left a firewall running that way. Capture the code explicitly, and
# note that `x=$(cmd) || x=...` is the form that works here: the fallback
# inside a substitution APPENDS instead of replacing.
rc=0
terraform apply -input=false -auto-approve || rc=$?
[ $rc -eq 0 ] || { echo "APPLY FAILED ($rc) -- resources may be running. Run cleanup.sh"; exit $rc; }

VM=$(terraform output -raw vm_name)
RG="rg-pgnopass-lab-dev-scus-001"

echo
echo "== waiting for the client to finish installing psql"
# cloud-init's runcmd waits for egress through the NAT gateway before apt,
# so this can take a few minutes after the VM reports Succeeded.
for i in $(seq 1 40); do
  out=$(az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
        --scripts "test -f /var/log/wk14-ready && command -v psql >/dev/null && echo READY" \
        --query "value[0].message" -o tsv 2>/dev/null | tr -d '\r')
  case "$out" in *READY*) echo "  client ready after $((i*15))s"; break ;; esac
  sleep 15
done
case "${out:-}" in
  *READY*) ;;
  *) echo "  client NOT ready. cloud-init log:"
     az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
       --scripts "tail -40 /var/log/cloud-init-output.log" --query "value[0].message" -o tsv
     exit 1 ;;
esac

echo
echo "deployed $(date -u +%H:%M:%SZ). Next: validate.sh, then failover.sh, then cleanup.sh TODAY."
