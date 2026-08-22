#!/usr/bin/env bash
# Every identity holding a role assignment, resolved and classified.
#
# Start from the ASSIGNMENTS, not from a list of identities you expect to find.
#
# That distinction is the whole point of this script. The obvious way to audit
# access is to list the app registrations and check what each one holds — but
# `az ad app list --show-mine` returns only apps you are a registered owner of,
# and an app registration created by a portal wizard, a Cloud Shell session or a
# deployment template usually has no owner at all. Auditing that way found five
# identities on this tenant. Auditing from the assignment side found nine.
#
#   ./scripts/access-audit.sh
#
# Read-only. Never deletes anything.

set -uo pipefail

echo "Resolving every principal with a role assignment..."
echo ""

# --all so management group and root scopes are included, not just this
# subscription and below.
az role assignment list --all --query \
  "[].{principalId:principalId, role:roleDefinitionName, scope:scope, name:principalName, type:principalType}" \
  -o json > .access-audit.json 2>/dev/null

python - <<'PY'
import json, subprocess, collections, re

with open('.access-audit.json') as fh:
    assignments = json.load(fh)

by_principal = collections.defaultdict(list)
for a in assignments:
    by_principal[a['principalId']].append(a)

def mask(text):
    return re.sub(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
                  '<guid>', text or '')

def resolve(object_id):
    """Return (display name, kind).

    Two traps here, both of which produced a wrong answer before being fixed:

    1. A null principalName in `az role assignment list` does NOT mean the
       principal was deleted. Service principals routinely come back with a null
       name in that query. Ask Entra directly before concluding anything.
    2. On Windows `az` is a batch file, so subprocess cannot exec it without a
       shell. Without shell=True every lookup fails, every principal is reported
       ORPHANED, and the audit reads as "nothing here is real" -- the most
       dangerous possible wrong answer for a security script.
    """
    for query, kind in (
        (f'az ad sp show --id {object_id} --query displayName -o tsv', 'service principal'),
        (f'az ad user show --id {object_id} --query displayName -o tsv', 'user'),
        (f'az ad group show --group {object_id} --query displayName -o tsv', 'group'),
    ):
        try:
            out = subprocess.run(query, shell=True, capture_output=True,
                                 text=True, timeout=60)
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip(), kind
        except Exception:
            pass
    return None, 'ORPHANED - principal no longer exists'


PRIVILEGED = {'Owner', 'Contributor', 'User Access Administrator',
              'Role Based Access Control Administrator', 'Management Group Contributor'}

rows = []
for object_id, items in by_principal.items():
    name, kind = resolve(object_id)
    roles = sorted({i['role'] for i in items})
    scopes = sorted({i['scope'] for i in items})
    rows.append((name or object_id, kind, roles, scopes, bool(PRIVILEGED & set(roles))))

rows.sort(key=lambda r: (not r[4], r[1], r[0]))

for name, kind, roles, scopes, privileged in rows:
    flag = '  <-- privileged' if privileged else ''
    print(f"{mask(name)}")
    print(f"    kind   : {kind}{flag}")
    print(f"    roles  : {', '.join(roles)}")
    for s in scopes:
        print(f"    scope  : {mask(s)}")
    print()

sp_count = sum(1 for r in rows if r[1] == 'service principal')
priv = sum(1 for r in rows if r[4])
orphan = sum(1 for r in rows if r[1].startswith('ORPHANED'))

print(f"{len(rows)} principals, {sp_count} service principals, {priv} privileged, {orphan} orphaned.")
print()
print("Every service principal here is a standing credential. Each one is a way")
print("into the subscription that does not expire and that nobody is watching.")
PY

rm -f .access-audit.json
