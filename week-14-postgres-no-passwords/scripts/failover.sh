#!/usr/bin/env bash
# Week 14 — force a failover and measure the downtime the APPLICATION sees.
#
# Microsoft's guidance is explicit about this: the end-to-end failover
# workflow keeps running for minutes after the application is writing again,
# so measuring the operation rather than the client overstates the outage.
# The number here comes from a writer loop on the VM, with its own clock.
#
# Usage:  bash week-14-postgres-no-passwords/scripts/failover.sh
set -uo pipefail
export MSYS_NO_PATHCONV=1

RG="rg-pgnopass-lab-dev-scus-001"
SRV="psql-wk14-dev-scus-001"
VM="vm-app-wk14-dev-scus-001"
WARMUP=30          # seconds of writing before the failover
SETTLE=240         # seconds of writing after it

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

FQDN=$(az postgres flexible-server show -g "$RG" -n "$SRV" \
       --query fullyQualifiedDomainName -o tsv | tr -d "\r")
MODE=$(az postgres flexible-server show -g "$RG" -n "$SRV" \
       --query highAvailability.mode -o tsv | tr -d "\r")
PRI=$(az postgres flexible-server show -g "$RG" -n "$SRV" \
       --query availabilityZone -o tsv | tr -d "\r")
STBY=$(az postgres flexible-server show -g "$RG" -n "$SRV" \
       --query highAvailability.standbyAvailabilityZone -o tsv | tr -d "\r")

echo "Week 14 failover — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  mode     $MODE   primary zone $PRI, standby zone ${STBY:-same}"
echo

# A failover against a standby that has not caught up is a different
# experiment. Refuse to start until Azure says the pair is healthy.
STATE=$(az postgres flexible-server show -g "$RG" -n "$SRV" \
        --query highAvailability.state -o tsv | tr -d "\r")
[ "$STATE" = "Healthy" ] || { echo "HA state is $STATE, not Healthy. Not failing over."; exit 1; }

echo "== starting the writer on the client"
# setsid, and all three streams detached. run-command does not return while
# anything still holds the session's output pipe, so a plain `nohup ... &`
# leaves the invoke hanging for as long as the writer runs -- which is
# forever. The first version of this script hung exactly there.
onvm "rm -f /var/log/wk14-writer.log
      setsid /usr/local/bin/wk14-writer.sh $FQDN </dev/null >/dev/null 2>&1 &
      sleep 5; echo started" >/dev/null
sleep "$WARMUP"
BEFORE=$(onvm "grep -c '^OK' /var/log/wk14-writer.log")
echo "  $BEFORE successful writes before the failover"
[ "${BEFORE:-0}" -gt 10 ] || { echo "writer is not writing. Not failing over."; \
  onvm "tail -5 /var/log/wk14-writer.log"; exit 1; }

echo
echo "== forced failover   $(date -u +%H:%M:%SZ)"
# Forced, not planned: a planned failover waits for the standby to catch up
# and blocks writes only at the end, which measures the best case. Forced is
# the one that simulates losing the primary.
# Azure refuses a failover while the previous one is still rebuilding its
# standby -- "server not in active state" -- and the documented guidance is
# to leave 15-20 minutes between them. A refused request with the script
# carrying on would produce a measurement of an outage that never happened.
if ! az postgres flexible-server restart -g "$RG" -n "$SRV" --failover Forced -o none; then
  onvm "pkill -f wk14-writer.sh; true" >/dev/null
  echo "FAILOVER REQUEST REFUSED -- nothing to measure. Writer stopped."
  echo "If the previous failover was recent, wait 15-20 minutes and re-run."
  exit 1
fi
echo "  request returned $(date -u +%H:%M:%SZ) -- letting the client write through it"

sleep "$SETTLE"
onvm "pkill -f wk14-writer.sh; true" >/dev/null

echo
echo "== the gap, from the client's log"
onvm 'python3 - <<PY
import re
rows=[]
for line in open("/var/log/wk14-writer.log"):
    m=re.match(r"(OK|FAIL) ([0-9.]+)$", line.strip())
    if m: rows.append((m.group(1), float(m.group(2))))
oks=[t for s,t in rows if s=="OK"]
fails=[t for s,t in rows if s=="FAIL"]
print("writes attempted :", len(rows))
print("succeeded        :", len(oks))
print("failed           :", len(fails))
if not fails:
    print("NO FAILED WRITE -- either the failover did not happen or the gap")
    print("fell between two attempts. 0.25s sampling cannot see under 250ms.")
else:
    # The outage is the longest run of consecutive failures, bounded by the
    # last success before it and the first success after it.
    best=None
    for i,(s,t) in enumerate(rows):
        if s!="FAIL": continue
        j=i
        while j+1 < len(rows) and rows[j+1][0]=="FAIL": j+=1
        prev=[x for x in rows[:i] if x[0]=="OK"]
        nxt =[x for x in rows[j+1:] if x[0]=="OK"]
        if prev and nxt:
            gap=nxt[0][1]-prev[-1][1]
            if best is None or gap>best[0]: best=(gap, prev[-1][1], nxt[0][1], j-i+1)
    if best:
        print("last write before:", "%.3f" % best[1])
        print("first write after:", "%.3f" % best[2])
        print("CLIENT DOWNTIME  : %.2f seconds (%d failed attempts)" % (best[0], best[3]))
PY'

echo
echo "== server state after"
az postgres flexible-server show -g "$RG" -n "$SRV" \
  --query "{mode:highAvailability.mode, state:highAvailability.state, primaryZone:availabilityZone, standbyZone:highAvailability.standbyAvailabilityZone}" -o table
echo
echo "The zones swap: the standby is the primary now, and a new standby is"
echo "being built in the old primary's zone. That rebuild keeps running after"
echo "the application has stopped noticing anything."
