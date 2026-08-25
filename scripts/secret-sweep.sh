#!/usr/bin/env bash
# Sweep the working tree for account identifiers before any git push.
#
# Run it; do not eyeball the diff. The whole point is that this catches the file
# you forgot you touched.
#
#   ./scripts/secret-sweep.sh          sweep files git would actually publish
#   ./scripts/secret-sweep.sh --all    sweep the filesystem, not just git's view
#
# Exits non-zero on any hit.

set -uo pipefail
cd "$(dirname "$0")/.."

SWEEP_ALL=0
[[ "${1:-}" == "--all" ]] && SWEEP_ALL=1

# Files that are SUPPOSED to hold identifiers. They are gitignored; sweeping
# them would report a failure on every run and train you to ignore this script.
EXPECTED_TO_HOLD_SECRETS='(scripts/secret-sweep\.sh$|terraform\.tfvars$|SESSION_CONTEXT\.md$|SESSION_ARCHIVE\.md$|docs/HIERARCHY\.md$|docs/SETUP\.md$|docs/INVENTORY\.md$|\.log$|/\.terraform/)'

if git rev-parse --git-dir >/dev/null 2>&1 && [[ $SWEEP_ALL -eq 0 ]]; then
  # What git tracks or would track — exactly what a push would publish.
  mapfile -t FILES < <(git ls-files --cached --others --exclude-standard                        | grep -vE "$EXPECTED_TO_HOLD_SECRETS")
else
  # Not a git repo yet, or --all. Fall back to the filesystem, minus the files
  # that legitimately carry identifiers.
  mapfile -t FILES < <(find . -type f -not -path './.git/*' | grep -vE "$EXPECTED_TO_HOLD_SECRETS")
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No files to sweep."
  exit 0
fi

# GUIDs that are public, global and identical in every Azure tenant: built-in
# role definitions and built-in policy definitions. They are not account
# identifiers, they appear in Microsoft's own documentation, and blocking on
# them trains you to ignore this script -- which is the failure mode that
# actually leaks something.
#
# Each one is here because a file in this repo names it in prose or in a
# variable rather than inside a /providers/... path, where the rule below would
# already have skipped it. Verify a new entry with:
#   az role definition list --query "[?name=='<guid>'].roleName"
#   az policy definition show --name <guid> --query "{n:displayName,t:policyType}"
PUBLIC_BUILTIN_GUIDS=$(printf '%s|'   749f88d5-cbae-40b8-bcfc-e573ddc772fa   92aaf0da-9dab-42b6-94a3-d43ce8d16293   4a9ae827-6dc8-4573-8ac7-8239d42aa03f   b24988ac-6180-42a0-ab88-20f7382dd24c   59759c62-9a22-4cdf-ae64-074495983fef   ea3f2387-9b95-492a-a190-fcdc54f7b070   cd3aa116-8754-49c9-a813-ad46512ece54   e56962a6-4747-49cd-b67b-bf8b01975c4c   871b6d14-10aa-478d-b590-94f262ecfa99   | sed 's/|$//')

fail=0

check() {
  local label="$1" pattern="$2"
  local hits
  hits=$(grep -nIE --binary-files=without-match "$pattern" "${FILES[@]}" 2>/dev/null \
         | grep -vE '0{8}-0{4}-0{4}-0{4}-0{12}' \
         | grep -vE 'XXXX-XXXX-XXX-XXX' \
         | grep -vE 'your-email@example\.com' \
         | grep -vE '/providers/Microsoft\.Authorization/(policy(Set)?Definitions|roleDefinitions)/'          | grep -vE "$PUBLIC_BUILTIN_GUIDS")
  if [[ -n "$hits" ]]; then
    echo ""
    echo "FAIL  $label"
    echo "$hits" | sed 's/^/      /'
    fail=1
  else
    printf 'ok    %s\n' "$label"
  fi
}

echo "Sweeping ${#FILES[@]} files..."
echo ""

# A bare GUID is almost always a tenant, subscription, client or object ID.
# Two exceptions are filtered above: the all-zero placeholder, and Azure BUILT-IN
# policy definition IDs. Those are public, global, and identical in every tenant
# on earth -- e56962a6-... is "Allowed locations" for everyone. They are not
# account identifiers and blocking on them would train you to ignore this script.
check "GUIDs (tenant / subscription / client / object IDs)" \
  '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

# MCA billing profile and invoice section names.
check "MCA billing profile / invoice section names" \
  '\b[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{3}-[A-Z0-9]{3}\b'

# Personal email. The lab's public files use your-email@example.com.
check "personal email addresses" \
  '[a-zA-Z0-9._%+-]+@(gmail|outlook|hotmail|yahoo)\.com'

# A credential VALUE, not a mention of one. Documentation legitimately names
# ARM_CLIENT_SECRET in order to say that it is never set; matching the bare token
# would fail the sweep on prose and train you to ignore it.
check "client secrets and connection strings" \
  '((client_secret|ARM_CLIENT_SECRET|password|pwd)[[:space:]]*[=:][[:space:]]*.?[A-Za-z0-9~._-]{8}|AccountKey=[A-Za-z0-9+/]|SharedAccessKey=[A-Za-z0-9+/])'

# Terraform state should never be tracked at all.
check "terraform state content" \
  '"terraform_version":|"lineage":'

echo ""
if [[ $fail -ne 0 ]]; then
  echo "SWEEP FAILED — do not push."
  echo ""
  echo "If a hit is a deliberate placeholder, add it to the filter list in this"
  echo "script. If it is a real identifier, remove it from the file — and if the"
  echo "file has already been committed, rewriting the working tree is not enough."
  exit 1
fi

echo "Sweep clean."
