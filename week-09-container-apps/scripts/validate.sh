#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Week 09 — validate
#
#   ./scripts/validate.sh
#
# The week's goal, stated so the checks can be judged against it:
#
#   A workload that serves real HTTP traffic from the internet, runs no
#   replicas when idle, and reports to week 08's workspace across a
#   subscription boundary.
#
# Every number printed here is measured from the deployment. Nothing is quoted
# from documentation, and no check passes by counting objects - week 08 shipped
# a check that passed by counting action groups while the alarm it was supposed
# to prove did not exist.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

export MSYS_NO_PATHCONV=1
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors >/dev/null 2>&1 || true

WEEK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$WEEK_DIR/terraform"
# Scratch files stay in the week directory. /tmp means two different places
# depending on whether bash or a native Windows binary resolves it.
WORK="$WEEK_DIR/.validate"
mkdir -p "$WORK"
# TWO spellings of the same directory, and both are needed.
#
# MSYS_NO_PATHCONV=1 is required above so Azure resource IDs survive the trip
# to az. It also stops Git Bash rewriting paths on their way to NATIVE Windows
# binaries - and curl is one. A bash path like /c/Projects/... is not something
# native curl can open, so it prints the status, fails to write the body, and
# exits non-zero. Measured: `curl -o "$WORK/x" -w '%{http_code}' || echo 000`
# produced the string "200000" - a successful request reported as a failure.
WORK_WIN="$(cygpath -w "$WORK" 2>/dev/null || echo "$WORK")"
CURL_SINK="$WORK_WIN/null"
CURL_BODY="$WORK_WIN/body.html"

cd "$TF_DIR"
FQDN=$(terraform output -raw app_fqdn 2>/dev/null | tr -d '\r')
APP=$(terraform output -raw app_name 2>/dev/null | tr -d '\r')
RG=$(terraform output -raw resource_group 2>/dev/null | tr -d '\r')
ENV_ID=$(terraform output -raw environment_id 2>/dev/null | tr -d '\r')
WS_GUID=$(terraform output -raw workspace_guid 2>/dev/null | tr -d '\r')
WS_ID=$(terraform output -raw workspace_resource_id 2>/dev/null | tr -d '\r')
SUB_LAB=$(grep -E '^subscription_id' terraform.tfvars | cut -d'"' -f2)

[ -n "$FQDN" ] || { echo "no terraform output — run ./scripts/deploy.sh first"; exit 1; }

PASS=0
FAIL=0
ok()   { echo "   PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "   FAIL  $1"; FAIL=$((FAIL+1)); }

echo "══════════════════════════════════════════════════════════════════════"
echo " Week 09 validation"
echo " app  : https://$FQDN"
echo " logs : $WS_GUID (week 08, sub-management)"
echo "══════════════════════════════════════════════════════════════════════"

# ── 1. the app answers, over HTTPS only ──────────────────────────────────────
echo ""
echo "── 1. the app serves traffic, and only over HTTPS ──"

code=$(curl -s -o "$CURL_BODY" -w '%{http_code}' --max-time 120 "https://$FQDN/") || code="000"
echo "   HTTPS GET /            -> $code"
if [ "$code" = "200" ]; then
  ok "the app answered 200 over HTTPS"
  head -c 200 "$WORK/body.html" | tr -d '\r' | sed 's/^/         /'
else
  bad "expected 200 over HTTPS, got $code"
fi

# allow_insecure_connections = false, so plain HTTP must not serve the app.
# A 301/302 to HTTPS is the correct behaviour; a 200 would mean the setting is
# not doing anything.
http_code=$(curl -s -o "$CURL_SINK" -w '%{http_code}' --max-time 60 "http://$FQDN/") || http_code="000"
echo "   HTTP  GET / (port 80)  -> $http_code"
case "$http_code" in
  301|302|307|308) ok "plain HTTP is redirected, not served ($http_code)" ;;
  000|403|404|426) ok "plain HTTP is refused ($http_code)" ;;
  200)             bad "plain HTTP served the app — allow_insecure_connections is not in effect" ;;
  *)               bad "unexpected response on plain HTTP: $http_code" ;;
esac

# ── 2. a warm request, for the comparison the week rests on ──────────────────
echo ""
echo "── 2. latency while a replica is already running ──"

warm_total=0
warm_n=0
for i in 1 2 3; do
  t=$(curl -s -o "$CURL_SINK" -w '%{time_total}' --max-time 120 "https://$FQDN/") || t="0"
  echo "   warm request $i: ${t}s"
  warm_total=$(python -c "print($warm_total + $t)")
  warm_n=$((warm_n+1))
done
WARM_AVG=$(python -c "print(round($warm_total/$warm_n, 3))")
echo "   warm average: ${WARM_AVG}s"
if python -c "import sys; sys.exit(0 if $WARM_AVG < 5 else 1)"; then
  ok "warm requests average ${WARM_AVG}s"
else
  bad "warm requests averaged ${WARM_AVG}s, which is not a warm replica"
fi

# ── 3. it actually scales to zero ────────────────────────────────────────────
#
# This is the week's claim and the thing that is easiest to assert without
# checking. cooldown_period_in_seconds is 300, so stop sending traffic and
# poll the replica count until Azure reports none.
echo ""
echo "── 3. replicas drop to zero when idle (cooldown 300s) ──"

replica_count() {
  az containerapp replica list \
    --name "$APP" --resource-group "$RG" --subscription "$SUB_LAB" \
    --only-show-errors -o json 2>/dev/null | python -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d) if isinstance(d,list) else 0)
except Exception:
    print("?")
'
}

start=$(date +%s)
ZERO_AT=""
for i in $(seq 1 32); do
  n=$(replica_count)
  elapsed=$(( $(date +%s) - start ))
  echo "   t+${elapsed}s  replicas=$n"
  if [ "$n" = "0" ]; then ZERO_AT=$elapsed; break; fi
  sleep 30
done

if [ -n "$ZERO_AT" ]; then
  ok "replicas reached 0 after ${ZERO_AT}s of no traffic"
else
  bad "replicas never reached 0 within $(( $(date +%s) - start ))s"
fi

# ── 4. the cold start, which is what scale-to-zero costs ─────────────────────
echo ""
echo "── 4. the first request after idle pays for the start ──"

if [ -n "$ZERO_AT" ]; then
  COLD=$(curl -s -o "$CURL_SINK" -w '%{http_code} %{time_total}' --max-time 180 "https://$FQDN/") || COLD="000 0"
  cold_code=${COLD%% *}
  COLD_T=${COLD##* }
  echo "   cold request: $cold_code in ${COLD_T}s"
  echo "   warm average: ${WARM_AVG}s"
  if [ "$cold_code" = "200" ]; then
    ok "the cold request still succeeded, in ${COLD_T}s"
    echo "   measured penalty: $(python -c "print(round($COLD_T - $WARM_AVG, 3))")s on the first request"
  else
    bad "the cold request returned $cold_code"
  fi
else
  echo "   SKIPPED — never reached zero replicas, so there is no cold start to measure"
fi

# ── 5. the diagnostic setting is wired the way the code says ─────────────────
#
# Not "a diagnostic setting exists". The three things that make it the right
# one: it points at week 08's workspace, it names both categories, and it uses
# the Dedicated destination so the rows land in per-resource tables.
echo ""
echo "── 5. logs are routed to week 08's workspace, correctly ──"

# Returns a bare JSON array, not an object with .value — a value[?...] query
# errors out and the error reads as "no settings found".
DS=$(az monitor diagnostic-settings list --resource "$ENV_ID" --subscription "$SUB_LAB" \
       --only-show-errors -o json 2>/dev/null)
echo "$DS" > "$WORK/diag.json"

# Windows Python cannot open a bash path either - same trap as curl above,
# which is why the file is WRITTEN by bash with $WORK and READ by python with
# $WORK_WIN. The failure is a FileNotFoundError against a file ls shows plainly.
python - "$WORK_WIN/diag.json" "$WS_ID" <<'PY' > "$WORK/diag.txt" 2>&1
import json,sys
path,ws = sys.argv[1], sys.argv[2].lower()
try:
    d=json.load(open(path))
except Exception as e:
    print("ERROR could not parse the diagnostic settings response: %s" % e); raise SystemExit
items = d if isinstance(d,list) else d.get("value",[])
if not items:
    print("ERROR no diagnostic settings on the environment"); raise SystemExit
want = {"ContainerAppConsoleLogs","ContainerAppSystemLogs"}
for s in items:
    name = s.get("name")
    tgt  = (s.get("workspaceId") or "").lower()
    dest = s.get("logAnalyticsDestinationType")
    cats = {l.get("category") for l in (s.get("logs") or []) if l.get("enabled")}
    print("SETTING %s" % name)
    print("  workspace_match %s" % (tgt == ws))
    # ARM does not return logAnalyticsDestinationType for this resource
    # type. It is reported, never asserted on - which TABLE the rows land
    # in is the real evidence, and check 6 tests exactly that.
    print("  destination_reported_by_arm %s" % dest)
    print("  categories %s" % ",".join(sorted(c for c in cats if c)))
    print("  categories_match %s" % (want <= cats))
PY
cat "$WORK/diag.txt" | sed 's/^/   /'

if grep -q "workspace_match True" "$WORK/diag.txt" \
   && grep -q "categories_match True" "$WORK/diag.txt"; then
  ok "routed to week 08's workspace, both named categories enabled"
else
  bad "the diagnostic setting is not wired as the code describes"
fi

# ── 6. the rows actually arrived, in week 08's workspace ─────────────────────
#
# The real test of week 08's "one workspace for the whole lab" design. Azure
# documents a delay of several minutes before ContainerAppConsoleLogs rows are
# queryable, so this polls rather than asking once and concluding.
echo ""
echo "── 6. this week's log rows are queryable in week 08's workspace ──"

# The column is ContainerAppName, with NO _s suffix, because
# log_analytics_destination_type = "Dedicated" gives resource-specific tables.
# The _s form belongs to the shared AzureDiagnostics table. Naming a column
# that does not exist fails the whole query with a SemanticError - KQL does
# not skip an unknown column just because it sits inside an `or`.
query_rows() {
  az monitor log-analytics query \
    --workspace "$WS_GUID" \
    --analytics-query "ContainerAppConsoleLogs | where ContainerAppName == '$APP' | summarize n=count()" \
    --only-show-errors -o json 2>"$WORK/q.err" | python -c '
import json,sys
try:
    d=json.load(sys.stdin)
    rows=d if isinstance(d,list) else d.get("tables",[{}])[0].get("rows",[])
    print(rows[0].get("n") if isinstance(rows[0],dict) else rows[0][0])
except Exception:
    print("?")
'
}

ROWS="?"
for i in $(seq 1 20); do
  ROWS=$(query_rows)
  echo "   attempt $i: rows=$ROWS"
  case "$ROWS" in
    ''|'?'|0) sleep 30 ;;
    *) break ;;
  esac
done

case "$ROWS" in
  ''|'?'|0)
    bad "no ContainerAppConsoleLogs rows for $APP after ~10 minutes"
    echo "   last error from the query:"
    head -5 "$WORK/q.err" | sed 's/^/      /'
    ;;
  *)
    ok "$ROWS console log rows for $APP in week 08's workspace"
    ;;
esac

# The destination, proved by where the rows ARE rather than by a field ARM
# does not return. Resource-specific tables are the whole reason week 08's
# per-table cost design works; the shared AzureDiagnostics table would opt
# this week out of it.
AZDIAG=$(az monitor log-analytics query --workspace "$WS_GUID"   --analytics-query "AzureDiagnostics | summarize n=count()"   --only-show-errors -o tsv 2>/dev/null | tr -d '' | awk '{print $NF}')
echo "   rows in the resource-specific table : ${ROWS}"
echo "   rows in the shared AzureDiagnostics : ${AZDIAG:-?}"
if [ "${AZDIAG:-1}" = "0" ] && [ "${ROWS:-0}" != "0" ]; then
  ok "the rows landed in dedicated tables, not AzureDiagnostics"
else
  bad "expected rows in the dedicated table and none in AzureDiagnostics"
fi

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " $PASS passed / $FAIL failed"
echo "══════════════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ] || exit 1
