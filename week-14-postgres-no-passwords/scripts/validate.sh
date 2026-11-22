#!/usr/bin/env bash
# Week 14 — is there really no password, and is it really private?
#
# Checks 1-6 prove CONFIGURATION. Checks 7 and 8 are the pair that proves
# behaviour: a managed identity connects with a token, and a password attempt
# against the same server is refused. A server that merely PREFERS Entra
# would pass 7 on its own.
#
# Usage:  bash week-14-postgres-no-passwords/scripts/validate.sh
set -uo pipefail
export MSYS_NO_PATHCONV=1

RG="rg-pgnopass-lab-dev-scus-001"
SRV="psql-wk14-dev-scus-001"
VM="vm-app-wk14-dev-scus-001"
PE="pe-psql-wk14-dev-scus-001"
DBUSER="id-app-wk14-dev-scus-001"

pass=0; fail=0
row() { printf "  %-50s %-26s %s\n" "$1" "$2" "$3"; }
ok()  { row "$1" "$2" "PASS"; pass=$((pass+1)); }
bad() { row "$1" "$2" "FAIL"; fail=$((fail+1)); }

onvm() {  # run a script on the client and return ONLY its stdout
  # run-command wraps its output: "Enable succeeded:", then [stdout], then
  # [stderr]. Returning the wrapper made two checks compare an exact value
  # against a string beginning "Enable succeeded" and report FAIL over a
  # correct answer -- the check breaking, not the thing checked.
  az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
     --scripts "$1" --query "value[0].message" -o tsv 2>/dev/null \
   | tr -d '\r' \
   | sed -n '/^\[stdout\]$/,/^\[stderr\]$/p' | sed '1d;$d' | sed '/^$/d'
}

echo
echo "Week 14 validation — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  Test                                               Result"
echo "  -------------------------------------------------- --------------------------"

# Each field is asked for by JMESPath rather than parsed out of one blob:
# a typo in a path then shows up as an empty answer on ONE row instead of
# breaking every row at once.
j() { az postgres flexible-server show -g "$RG" -n "$SRV" --query "$1" -o tsv 2>/dev/null | tr -d "\r"; }
az postgres flexible-server show -g "$RG" -n "$SRV" -o none 2>/dev/null   || { echo "  server $SRV not found in $RG"; exit 1; }

# 1 — the server, and which HA mode the region actually granted
HA_MODE=$(j "highAvailability.mode")
HA_STATE=$(j "highAvailability.state")
[ -n "$HA_MODE" ] && [ "$HA_MODE" != "Disabled" ] \
  && ok "High availability enabled" "$HA_MODE / $HA_STATE" \
  || bad "High availability enabled" "${HA_MODE:-none}"

# 2 — password authentication OFF. The week's claim, as configuration.
PW=$(j "authConfig.passwordAuth")
[ "$PW" = "Disabled" ] \
  && ok "PostgreSQL password auth disabled" "$PW" \
  || bad "PostgreSQL password auth disabled" "${PW:-unknown}"

# 3 — Entra authentication ON
AAD=$(j "authConfig.activeDirectoryAuth")
[ "$AAD" = "Enabled" ] \
  && ok "Microsoft Entra auth enabled" "$AAD" \
  || bad "Microsoft Entra auth enabled" "${AAD:-unknown}"

# 4 — and there is no local administrator account AT ALL. Stronger than a
# disabled login method: there is no identity for a password to belong to.
ADMIN=$(j "administratorLogin")
[ -z "$ADMIN" ] || [ "$ADMIN" = "None" ] \
  && ok "No local administrator on the server" "none" \
  || bad "No local administrator on the server" "$ADMIN"

# 5 — no public endpoint
PUB=$(j "network.publicNetworkAccess")
[ "$PUB" = "Disabled" ] \
  && ok "Public network access disabled" "$PUB" \
  || bad "Public network access disabled" "${PUB:-unknown}"

PE_STATE=$(az network private-endpoint show -g "$RG" -n "$PE" \
  --query "privateLinkServiceConnections[0].privateLinkServiceConnectionState.status" \
  -o tsv 2>/dev/null | tr -d '\r')
[ "$PE_STATE" = "Approved" ] \
  && ok "Private endpoint approved" "$PE_STATE" \
  || bad "Private endpoint approved" "${PE_STATE:-missing}"

FQDN=$(j "fullyQualifiedDomainName")

# 6 — the documented hostname resolves to a PRIVATE address from inside the
# network. If this resolved to a public IP the private endpoint would be
# decoration.
IP=$(onvm "getent hosts $FQDN | awk '{print \$1}' | head -1")
case "$IP" in
  10.60.1.*) ok "Hostname resolves to the private endpoint" "$IP" ;;
  *)         bad "Hostname resolves to the private endpoint" "${IP:-no answer}" ;;
esac

# 7 — THE PROOF. A token from IMDS, used as the password, as the identity.
ROWS=$(onvm "export PGPASSWORD=\$(/usr/local/bin/wk14-token.sh);
  psql 'host=$FQDN user=$DBUSER dbname=orders sslmode=require' -qtAX \
    -c \"select 'connected-as='||current_user\" 2>&1 | tail -2")
case "$ROWS" in
  *connected-as=$DBUSER*) ok "Managed identity connects with a token" "current_user=$DBUSER" ;;
  *)                      bad "Managed identity connects with a token" "${ROWS:0:24}" ;;
esac

# 8 — THE CONTROL. The same server, a password, refused. Without this, check
# 7 only proves that SOMETHING can log in.
DENY=$(onvm "PGPASSWORD=not-a-real-password \
  psql 'host=$FQDN user=$DBUSER dbname=orders sslmode=require connect_timeout=10' \
    -qtAX -c 'select 1' 2>&1 | head -3")
case "$DENY" in
  *"password authentication"*|*"authentication failed"*|*"PGAadAuth"*|*FATAL*)
     ok "Password login refused" "$(echo "$DENY" | head -1 | cut -c1-24)" ;;
  *) bad "Password login refused" "accepted or unclear" ;;
esac

# 9 — a write actually lands, so the failover measurement has something to
# measure.
WROTE=$(onvm "export PGPASSWORD=\$(/usr/local/bin/wk14-token.sh);
  psql 'host=$FQDN user=$DBUSER dbname=orders sslmode=require' -qtAX \
    -c 'create table if not exists heartbeat (id bigserial primary key, at timestamptz default now())' \
    -c 'insert into heartbeat default values' \
    -c 'select count(*) from heartbeat' 2>&1 | tail -1")
case "$WROTE" in
  [1-9]*) ok "Write lands in the database" "$WROTE row(s)" ;;
  *)      bad "Write lands in the database" "${WROTE:0:24}" ;;
esac

echo
echo "  $pass passed / $fail failed"
echo
[ $fail -eq 0 ] || exit 1
