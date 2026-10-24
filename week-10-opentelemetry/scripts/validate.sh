#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Week 10 — validate
#
#   ./scripts/validate.sh
#
# The goal, stated so the checks can be judged against it:
#
#   One request to a public frontend produces ONE trace that spans TWO
#   services, with the time attributed to the service that spent it - and the
#   images are pulled from a private registry with no password anywhere.
#
# Lessons from week 09 applied here, because all three cost a re-run:
#   * native curl cannot open a bash path, so there are two spellings of WORK
#   * x=$(cmd) || x=FOO replaces; x=$(cmd || echo FOO) APPENDS to a partial
#   * an unknown KQL column fails the whole query, even inside an `or`
#   * the managed agent writes AppRoleName as "<environment>.<service>", NOT
#     the bare OTEL_SERVICE_NAME. Matching the bare name returns zero rows
#     against a table that is full, which reads exactly like "no telemetry".
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

export MSYS_NO_PATHCONV=1
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors >/dev/null 2>&1 || true

WEEK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$WEEK_DIR/terraform"
WORK="$WEEK_DIR/.validate"
mkdir -p "$WORK"
WORK_WIN="$(cygpath -w "$WORK" 2>/dev/null || echo "$WORK")"
CURL_SINK="$WORK_WIN/null"
CURL_BODY="$WORK_WIN/body.json"

cd "$TF_DIR"
FRONTEND=$(terraform output -raw frontend_url 2>/dev/null | tr -d '\r')
ACR=$(terraform output -raw registry_name 2>/dev/null | tr -d '\r')
RG=$(terraform output -raw resource_group 2>/dev/null | tr -d '\r')
WS_GUID=$(terraform output -raw workspace_guid 2>/dev/null | tr -d '\r')
SAMPLER=$(terraform output -raw sampler_arg 2>/dev/null | tr -d '\r')
SUB_LAB=$(grep -E '^subscription_id' terraform.tfvars | cut -d'"' -f2)

[ -n "$FRONTEND" ] || { echo "no terraform output — run ./scripts/deploy.sh first"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "   PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "   FAIL  $1"; FAIL=$((FAIL+1)); }

echo "══════════════════════════════════════════════════════════════════════"
echo " Week 10 validation"
echo " frontend : $FRONTEND"
echo " traces   : week 08's workspace $WS_GUID"
echo " sampler  : $SAMPLER"
echo "══════════════════════════════════════════════════════════════════════"

# ── 1. the public entry point works, and it really called the backend ───────
echo ""
echo "── 1. one request, two services ──"

code=$(curl -s -o "$CURL_BODY" -w '%{http_code}' --max-time 120 "$FRONTEND/") || code="000"
echo "   GET / -> $code"
if [ "$code" = "200" ]; then
  ok "the frontend answered 200"
else
  bad "expected 200 from the frontend, got $code"
fi

# The response body is the frontend's own evidence that the hop happened: it
# contains what the BACKEND returned. A frontend that answered 200 on its own
# would not have this.
if python -c "
import json,sys
d=json.load(open(r'$WORK_WIN/body.json'))
b=d.get('backend_said',{})
sys.exit(0 if b.get('items') and 'backend_work_ms' in b else 1)
" 2>/dev/null; then
  ok "the response carries the backend's payload — the hop really happened"
  python -c "
import json
d=json.load(open(r'$WORK_WIN/body.json'))
print('         backend_work_ms=%s items=%d' % (d['backend_said'].get('backend_work_ms'), len(d['backend_said'].get('items',[]))))
"
else
  bad "the frontend answered but the backend payload is missing"
fi

# ── 2. the backend is not on the internet ───────────────────────────────────
echo ""
echo "── 2. the backend is internal only ──"

BACKEND_FQDN=$(az containerapp show -n backend -g "$RG" --subscription "$SUB_LAB" \
  --query "properties.configuration.ingress.fqdn" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
EXT=$(az containerapp show -n backend -g "$RG" --subscription "$SUB_LAB" \
  --query "properties.configuration.ingress.external" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
echo "   ingress.external = ${EXT:-?}"
if [ "$EXT" = "false" ]; then
  ok "the backend's ingress is internal"
else
  bad "the backend's ingress reports external=${EXT:-?}"
fi

if [ -n "$BACKEND_FQDN" ]; then
  bcode=$(curl -s -o "$CURL_SINK" -w '%{http_code}' --max-time 30 "https://$BACKEND_FQDN/api/items") || bcode="000"
  echo "   calling the backend from here -> $bcode"
  case "$bcode" in
    200) bad "the backend answered the public internet" ;;
    *)   ok "the backend is unreachable from outside the environment ($bcode)" ;;
  esac
fi

# ── 3. no password anywhere ─────────────────────────────────────────────────
#
# Not "a registry exists". The three things that make the pull passwordless:
# the admin user is off, the app references an identity rather than a
# credential, and the identity holds AcrPull scoped to the registry.
echo ""
echo "── 3. the image is pulled with an identity, not a secret ──"

ADMIN=$(az acr show -n "$ACR" --subscription "$SUB_LAB" --query adminUserEnabled -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
echo "   registry adminUserEnabled = ${ADMIN:-?}"
[ "$ADMIN" = "false" ] && ok "the registry admin user is disabled" || bad "the registry admin user is ${ADMIN:-?}"

REG_IDENT=$(az containerapp show -n frontend -g "$RG" --subscription "$SUB_LAB" \
  --query "properties.configuration.registries[0].identity" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
REG_PW=$(az containerapp show -n frontend -g "$RG" --subscription "$SUB_LAB" \
  --query "properties.configuration.registries[0].passwordSecretRef" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
echo "   frontend registry identity      = ${REG_IDENT:0:60}"
echo "   frontend registry passwordRef   = ${REG_PW:-<none>}"
if [ -n "$REG_IDENT" ] && [ -z "$REG_PW" ]; then
  ok "the app pulls with a managed identity and holds no registry password"
else
  bad "the app's registry config is not identity-only"
fi

ACR_ID=$(az acr show -n "$ACR" --subscription "$SUB_LAB" --query id -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
NPULL=$(az role assignment list --scope "$ACR_ID" --subscription "$SUB_LAB" \
  --query "length([?roleDefinitionName=='AcrPull'])" -o tsv --only-show-errors 2>/dev/null | tr -d '\r')
echo "   AcrPull assignments on the registry = ${NPULL:-?}"
[ "${NPULL:-0}" -ge 1 ] 2>/dev/null && ok "AcrPull is granted at the registry, not the subscription" || bad "no AcrPull assignment found on the registry"

# ── 4. traces arrived at all ────────────────────────────────────────────────
#
# Workspace-based Application Insights writes into week 08's workspace, so the
# query runs against that workspace rather than a separate store.
echo ""
echo "── 4. traces reach week 08's workspace ──"

query() {
  az monitor log-analytics query --workspace "$WS_GUID" --analytics-query "$1" \
    --only-show-errors -o json 2>"$WORK/q.err"
}

ROWS="?"
for i in $(seq 1 20); do
  ROWS=$(query "AppRequests | extend svc=tostring(split(AppRoleName,'.')[-1]) | where svc in ('frontend','backend') | summarize n=count()" | python -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d[0].get('n') if d else 0)
except Exception:
    print('?')
")
  echo "   attempt $i: AppRequests rows=$ROWS"
  case "$ROWS" in ''|'?'|0) sleep 30 ;; *) break ;; esac
done

case "$ROWS" in
  ''|'?'|0)
    bad "no AppRequests rows after ~10 minutes"
    head -5 "$WORK/q.err" | sed 's/^/      /'
    ;;
  *) ok "$ROWS request spans landed in week 08's workspace" ;;
esac

# ── 5. the trace is DISTRIBUTED ─────────────────────────────────────────────
#
# This is the week's actual claim, and the one that is easy to fake by looking
# at two services that each produced spans. The test is a single OperationId
# containing BOTH service names - which can only happen if trace context
# survived the network hop.
echo ""
echo "── 5. one operation spans both services ──"

query "AppRequests | extend svc=tostring(split(AppRoleName,'.')[-1])
  | where svc in ('frontend','backend')
  | summarize services=make_set(svc), spans=count() by OperationId
  | where array_length(services) >= 2
  | summarize distributed=count()" > "$WORK/dist.json" 2>/dev/null

DIST=$(python -c "
import json
try:
    d=json.load(open(r'$WORK_WIN/dist.json'))
    print(d[0].get('distributed') if d else 0)
except Exception:
    print('?')
")
echo "   operations containing BOTH frontend and backend: ${DIST:-?}"
if [ "${DIST:-0}" != "0" ] && [ "${DIST:-?}" != "?" ]; then
  ok "trace context survived the hop — $DIST distributed trace(s)"
else
  bad "no single operation contains both services"
fi

# ── 6. the time is attributed to the service that spent it ──────────────────
echo ""
echo "── 6. the trace says WHERE the time went ──"

# Health probes are excluded, and that is not tidying up. They are 78% of
# all requests here and they take 0.6 ms, so including them drags the p50 to
# 0.7 ms and hides the 250 ms the backend actually spends. A latency number
# averaged over a liveness probe is a number about the probe.
query "AppRequests | extend svc=tostring(split(AppRoleName,'.')[-1])
  | where svc in ('frontend','backend') and Name !contains 'health'
  | summarize p50=round(percentile(DurationMs,50),1), n=count() by svc, Name
  | order by svc asc" > "$WORK/dur.json" 2>/dev/null
python -c "
import json
try:
    d=json.load(open(r'$WORK_WIN/dur.json'))
    for r in d:
        print('   %-9s %-16s p50=%8.1f ms   n=%s' % (r.get('svc'), r.get('Name'), float(r.get('p50') or 0), r.get('n')))
except Exception as e:
    print('   could not read durations:', e)
"
echo "   (the backend sleeps 250 ms on purpose - the frontend's total should be"
echo "    that plus its own small overhead, and the trace is what separates them)"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo " $PASS passed / $FAIL failed"
echo "══════════════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ] || exit 1
