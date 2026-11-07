#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Switch a week's HCP Terraform workspace to LOCAL execution.

    python scripts/hcp_workspace_local.py azure-week-12-dev
    python scripts/hcp_workspace_local.py --check azure-week-12-dev

Why this exists
---------------
HCP Terraform defaults a new workspace to REMOTE execution. This lab runs
every week locally, because remote execution needs Azure credentials inside
the workspace and the only acceptable way to supply them is OIDC dynamic
credentials -- never an uploaded client secret.

So a remote workspace does not fail at apply, when you would understand why.
It fails during PLAN, on an agent, with this:

    Error: unable to build authorizer for Resource Manager API: could not
    configure AzureCli Authorizer: could not parse Azure CLI version:
    launching Azure CLI: exec: "az": executable file not found in $PATH

which reads like a broken local toolchain and is not one. `az` is missing
because the plan is running on HashiCorp's agent, not on this machine. The
path in the error -- /home/tfc-agent/... -- is the only clue, and it is easy
to miss.

Every week of this lab has hit this and fixed it by hand through the API.
Week 12 is the twelfth. A manual step repeated twelve times is a script
somebody should have written after the second, so here it is.

The token comes from the Terraform CLI's own credentials file. On Windows
that is %APPDATA%/terraform.d/credentials.tfrc.json and NOT ~/.terraform.d/ --
checking the Unix path on Windows once produced a confident "you are not
logged in" that was wrong and cost a session.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

ORG = "Katta"
HOST = "app.terraform.io"


def token():
    """The Terraform CLI's stored HCP token."""
    candidates = []
    if os.environ.get("APPDATA"):                     # Windows, the real one
        candidates.append(os.path.join(os.environ["APPDATA"],
                                       "terraform.d", "credentials.tfrc.json"))
    candidates.append(os.path.expanduser(             # Unix
        "~/.terraform.d/credentials.tfrc.json"))

    for p in candidates:
        if os.path.isfile(p):
            with open(p, encoding="utf-8") as fh:
                creds = json.load(fh).get("credentials", {})
            if HOST in creds:
                return creds[HOST]["token"]

    raise SystemExit(
        "No HCP token found. Looked in:\n  " + "\n  ".join(candidates) +
        "\n\nRun `terraform login`. On Windows the file is under %APPDATA%,\n"
        "not ~/.terraform.d -- checking the Unix path there reports a false\n"
        "'not logged in'.")


def api(method, path, body=None):
    req = urllib.request.Request(
        "https://%s/api/v2%s" % (HOST, path),
        method=method,
        data=json.dumps(body).encode() if body else None,
        headers={
            "Authorization": "Bearer " + token(),
            "Content-Type": "application/vnd.api+json",
        })
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        raise SystemExit("HCP API %s %s -> %s\n  %s"
                         % (method, path, e.code, detail))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("workspace", help="e.g. azure-week-12-dev")
    ap.add_argument("--check", action="store_true",
                    help="report the mode and exit non-zero if not local")
    args = ap.parse_args()

    path = "/organizations/%s/workspaces/%s" % (ORG, args.workspace)
    attrs = api("GET", path)["data"]["attributes"]
    mode = attrs.get("execution-mode")

    if mode == "local":
        print("%s is already LOCAL execution." % args.workspace)
        return 0

    print("%s is %s execution." % (args.workspace, (mode or "unknown").upper()))
    if args.check:
        print()
        print("  A remote workspace has no Azure credentials and no `az`, so")
        print("  the next plan fails on an agent with what looks like a")
        print("  broken local toolchain. Run without --check to fix it.")
        return 1

    api("PATCH", path, {"data": {"type": "workspaces",
                                 "attributes": {"execution-mode": "local"}}})

    now = api("GET", path)["data"]["attributes"].get("execution-mode")
    if now != "local":
        print("  PATCH accepted but the mode is still %r." % now)
        return 2

    print("  switched to LOCAL.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
