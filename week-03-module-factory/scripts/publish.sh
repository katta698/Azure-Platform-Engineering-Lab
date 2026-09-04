#!/usr/bin/env bash
# Week 03 — publish a version of storage-baseline to the private registry.
#
#   ./scripts/publish.sh 1.0.0
#   ./scripts/publish.sh 2.0.0
#
# What gets published is the module AS IT EXISTS AT THE GIT TAG, extracted with
# `git archive` rather than copied from the working tree. That is not caution
# for its own sake: a registry version is immutable, so a tarball built from a
# dirty checkout publishes 1.0.0 as something that matches no commit, and the
# only way to correct it is to delete a version other configurations may
# already be pinned to.
#
# Publishing goes through the API rather than a VCS connection. Either is
# legitimate, and the trade is visible: with a VCS connection HCP watches for
# tags and the tag IS the trigger, while here the tag is still the source of
# the content but a human runs the publish. The API path is what makes a
# monorepo work without splitting each module into its own repository.

set -euo pipefail
export MSYS_NO_PATHCONV=1

# The REPO ROOT, not the week directory, because MODULE_PATH below is
# repo-root-relative and git resolves `<rev>:<path>` relative to the current
# directory. Run from the week directory, `git archive <tag>:week-03-.../modules/...`
# does not error — it resolves to an EMPTY TREE and produces a valid tarball
# containing nothing, which uploads fine and publishes an empty module version.
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

ORG="Katta"
MODULE="storage-baseline"
PROVIDER="azurerm"
MODULE_PATH="week-03-module-factory/modules/storage-baseline"
API="https://app.terraform.io/api/v2"

# ── Scratch space, in two spellings ─────────────────────────────────────────
#
# curl here is a native Windows build, and MSYS_NO_PATHCONV=1 above (which the
# Azure resource IDs need) stops Git Bash rewriting POSIX paths on its way to
# native binaries. So `curl -o /tmp/x` writes C:\tmp\x while bash reads
# /tmp = C:\Users\<user>\AppData\Local\Temp — two different files, and the
# failure is a "no such file" against a path that curl reported writing fine.
#
# WORK is what bash reads. WORK_WIN is what curl is given. Same directory.
WORK=$(mktemp -d -t wk03-publish-XXXXXX)
WORK_WIN=$(cygpath -w "$WORK" 2>/dev/null || printf '%s' "$WORK")
trap 'rm -rf "$WORK"' EXIT

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 <x.y.z>" >&2
  exit 2
fi
TAG="${MODULE}-v${VERSION}"

# ── The token ───────────────────────────────────────────────────────────────
#
# On Windows the credentials file is at %APPDATA%/terraform.d/, not
# ~/.terraform.d/ — checking the Unix path here produces a confident "you are
# not logged in" against a machine that has been logged in for weeks.
#
# The BOM strip is not defensive programming. Several Windows tools write JSON
# as UTF-8 with a byte order mark, and Terraform's own HCL parser rejects the
# file outright with `At 1:1: illegal char` — every HCP operation then fails
# for a reason that has nothing to do with the configuration being run.
read_token() {
  if [[ -n "${TFE_TOKEN:-}" ]]; then
    printf '%s' "$TFE_TOKEN"
    return
  fi
  local f="${APPDATA:-$HOME/AppData/Roaming}/terraform.d/credentials.tfrc.json"
  # Backslashes to forward slashes. %APPDATA% is a Windows path and the rest of
  # this string is POSIX, so the result is mixed; bash reads that fine. Note the
  # pattern is \\ -> / — `${f//\//}` would DELETE every slash instead, leaving a
  # path that does not exist and a confident "you are not logged in".
  f="${f//\\//}"
  if [[ ! -f "$f" ]]; then
    echo "No token: set TFE_TOKEN, or run 'terraform login'." >&2
    exit 1
  fi
  sed '1s/^\xEF\xBB\xBF//' "$f" \
    | python -c "import json,sys; print(json.load(sys.stdin)['credentials']['app.terraform.io']['token'])"
}

TOKEN="$(read_token)"
auth=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/vnd.api+json")

# ── The tag ─────────────────────────────────────────────────────────────────
if ! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  cat >&2 <<MSG
Tag ${TAG} does not exist.

A registry version is immutable and this script will not invent one. Create the
tag on the commit that holds the module you mean to publish:

  git tag ${TAG}
  git push origin ${TAG}

The prefix matters in a monorepo: plain v${VERSION} would be the repository's
version, and this repository will eventually hold more than one module.
MSG
  exit 1
fi

COMMIT_SHA=$(git rev-parse "refs/tags/${TAG}^{commit}")
echo "Publishing ${MODULE} ${VERSION}"
echo "  tag    ${TAG}"
echo "  commit ${COMMIT_SHA}"

if ! git rev-parse -q --verify "${TAG}^{tree}:${MODULE_PATH}" >/dev/null 2>&1; then
  echo "The tag does not contain ${MODULE_PATH}." >&2
  exit 1
fi

# Extracted from the tag, with the module at the root of the archive — the
# registry expects to find main.tf at the top level, not three directories down.
TARBALL="${WORK}/${MODULE}-${VERSION}.tar.gz"
TARBALL_WIN="${WORK_WIN}\\${MODULE}-${VERSION}.tar.gz"
git archive --format=tar "${TAG}:${MODULE_PATH}" | gzip > "$TARBALL"

# An empty archive is a valid archive. It uploads with a 200, reaches status ok
# and publishes a version containing nothing, which a consumer meets as a module
# with no inputs rather than as a failure — so it is checked here, not trusted.
FILE_COUNT=$(tar -tzf "$TARBALL" | wc -l | tr -d ' ')
echo "  packaged ${FILE_COUNT} files from the tag"
if [[ "$FILE_COUNT" -eq 0 ]]; then
  echo "The archive is empty. Nothing was extracted from ${TAG}:${MODULE_PATH}." >&2
  exit 1
fi

# ── The module, once ────────────────────────────────────────────────────────
#
# Creating a module that already exists returns 422 with a name-taken error,
# and every version after the first hits that path. It is the expected result
# of the second publish, not a failure.
status=$(curl -s -o "${WORK_WIN}\wk03-mod.json" -w '%{http_code}' "${auth[@]}" -X POST \
  "${API}/organizations/${ORG}/registry-modules" \
  -d "{\"data\":{\"type\":\"registry-modules\",\"attributes\":{\"name\":\"${MODULE}\",\"provider\":\"${PROVIDER}\",\"registry-name\":\"private\"}}}")

case "$status" in
  201) echo "  registry module created" ;;
  422) echo "  registry module already exists" ;;
  *)   echo "Creating the module failed (HTTP $status):" >&2; cat "${WORK}/wk03-mod.json" >&2; exit 1 ;;
esac

# ── The version ─────────────────────────────────────────────────────────────
status=$(curl -s -o "${WORK_WIN}\wk03-ver.json" -w '%{http_code}' "${auth[@]}" -X POST \
  "${API}/organizations/${ORG}/registry-modules/private/${ORG}/${MODULE}/${PROVIDER}/versions" \
  -d "{\"data\":{\"type\":\"registry-module-versions\",\"attributes\":{\"version\":\"${VERSION}\",\"commit-sha\":\"${COMMIT_SHA}\"}}}")

if [[ "$status" == "422" ]]; then
  echo "Version ${VERSION} already exists in the registry." >&2
  echo "Registry versions are immutable. Publish ${VERSION%.*}.$(( ${VERSION##*.} + 1 )) instead of overwriting." >&2
  exit 1
fi
if [[ "$status" != "201" ]]; then
  echo "Creating the version failed (HTTP $status):" >&2; cat "${WORK}/wk03-ver.json" >&2; exit 1
fi

# Read through stdin rather than by path. Git Bash's /tmp is
# C:\Users\<user>\AppData\Local\Temp, and the Python on PATH here is a Windows
# build that cannot open a POSIX path — `open('/tmp/...')` fails with
# FileNotFoundError against a file `ls` shows plainly. The shell does the
# redirect, so only bash has to understand the path.
UPLOAD_URL=$(python -c "import json,sys;print(json.load(sys.stdin)['data']['links']['upload'])" < "${WORK}/wk03-ver.json")
echo "  version record created"

# The upload goes to archivist, not to the API host, and it is a PUT of raw
# bytes. It carries no Authorization header — the URL is the credential, which
# is why it is single-use and why it must not end up in a log.
curl -s -f -X PUT --data-binary "@${TARBALL_WIN}" \
  -H "Content-Type: application/octet-stream" "$UPLOAD_URL"
echo "  tarball uploaded"

# ── Confirm from the registry, not from the upload ──────────────────────────
#
# A 200 on the upload means the bytes arrived. The registry then extracts and
# indexes them, and a version whose extraction failed sits there in a non-ok
# status that a consumer's `terraform init` reports as "module not found".
for _ in $(seq 1 20); do
  sleep 3
  state=$(curl -s "${auth[@]}" \
    "${API}/organizations/${ORG}/registry-modules/private/${ORG}/${MODULE}/${PROVIDER}/versions" \
    | python -c "
import json,sys
d=json.load(sys.stdin)
print(next((v['attributes']['status'] for v in d.get('data',[])
            if v['attributes']['version']=='${VERSION}'), 'missing'))")
  echo "  status: $state"
  [[ "$state" == "ok" ]] && break
  if [[ "$state" == "setup_failed" || "$state" == "reg_ingress_failed" ]]; then
    echo "Ingestion failed. The version exists and is unusable — delete it before retrying:" >&2
    echo "  curl -X DELETE ... /registry-modules/private/${ORG}/${MODULE}/${PROVIDER}/${VERSION}" >&2
    exit 1
  fi
done

if [[ "$state" != "ok" ]]; then
  echo "Version ${VERSION} did not reach status ok." >&2
  exit 1
fi

cat <<MSG

Published: app.terraform.io/${ORG}/${MODULE}/${PROVIDER} ${VERSION}

  module "storage" {
    source  = "app.terraform.io/${ORG}/${MODULE}/${PROVIDER}"
    version = "${VERSION}"
  }
MSG
