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

fail=0

check() {
  local label="$1" pattern="$2"
  local hits
  hits=$(grep -nIE --binary-files=without-match "$pattern" "${FILES[@]}" 2>/dev/null \
         | grep -vE '0{8}-0{4}-0{4}-0{4}-0{12}' \
         | grep -vE 'XXXX-XXXX-XXX-XXX' \
         | grep -vE 'your-email@example\.com' \
         | grep -vE '/providers/Microsoft\.Authorization/policy(Set)?Definitions/')
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
