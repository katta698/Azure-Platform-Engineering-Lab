#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Export a signed-in HCP Terraform session so captures stop needing a login.

    # once, with Chrome already open and signed in to HCP:
    python scripts/screenshots/save_hcp_session.py

    # thereafter, from any lab, for weeks:
    python scripts/screenshots/capture_azure.py <hcp-url> out.png \
        --load-session "%USERPROFILE%/.claude/hcp-session.json"

WHY THIS EXISTS (2026-10-23)
----------------------------
Jay, running three labs in parallel: "Do you have to log into HCP every single
time? ... Every week I kind of logging manually. Sometimes I'm on my phone."

He was right to push. This repo had recorded, on 2026-09-25, that HCP
screenshots must be taken by hand forever, because:

    "HCP's auth token is a SESSION cookie Chromium never writes to the
     profile, so --login, close, capture could never have worked."

That conclusion was WRONG, and it cost five weeks of manual logins across
three labs. Measured today against the live site:

    cookies for *.terraform.io : 1
    _atlas_session_data        : PERSISTENT, not session-scoped

One cookie. It survives a browser restart, and replaying it into a clean
headless Chromium loads the workspace page fully signed in - name, execution
mode, resource list, no sign-in redirect.

The 2026-10-06 CDP workaround (attach to a browser the human already has
open) still works and is still useful. This is strictly better: nothing has
to be open at capture time at all.

SECURITY - READ THIS
--------------------
The file this writes IS a credential. Anyone holding it can act as you in HCP
Terraform until it expires. So:

  * it is written OUTSIDE every repository, under %USERPROFILE%/.claude/
  * it must never be committed, pasted, or attached to anything
  * refresh it by re-running this script; revoke by signing out of HCP, which
    invalidates the session server-side

WHEN IT STOPS WORKING
---------------------
Sessions do expire, and signing out of HCP in the browser kills this one too.
The symptom is a capture that lands on the sign-in page - capture_azure.py
already refuses to save in that case, so it fails loudly rather than writing
a screenshot of a login form. Re-run this script and carry on.
"""
import argparse
import json
import pathlib
import sys

DEFAULT_OUT = pathlib.Path.home() / ".claude" / "hcp-session.json"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cdp", default="http://127.0.0.1:9222",
                    help="A running browser with remote debugging, already signed in to HCP")
    ap.add_argument("--out", default=str(DEFAULT_OUT),
                    help="Where to write the session. Keep it out of every repo.")
    ap.add_argument("--domain", default="terraform.io",
                    help="Only cookies for this domain are exported.")
    args = ap.parse_args()

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("playwright is not installed: pip install playwright")
        return 2

    with sync_playwright() as p:
        try:
            browser = p.chromium.connect_over_cdp(args.cdp)
        except Exception as e:
            print("Could not attach to %s\n   %s" % (args.cdp, e))
            print("\nStart Chrome with remote debugging and sign in to HCP first:")
            print('   chrome.exe --remote-debugging-port=9222 '
                  r'--user-data-dir="%USERPROFILE%\.claude\hcp-profile" https://app.terraform.io')
            return 1

        cookies = []
        for ctx in browser.contexts:
            for c in ctx.cookies():
                if args.domain in c.get("domain", ""):
                    cookies.append(c)
        browser.close()

    if not cookies:
        print("No %s cookies found. Is that browser signed in to HCP?" % args.domain)
        return 1

    # Report what was captured WITHOUT printing any value - these are secrets.
    print("captured %d cookie(s) for %s:" % (len(cookies), args.domain))
    for c in cookies:
        exp = c.get("expires", -1)
        kind = "session-scoped" if exp in (-1, None) or exp <= 0 else "persistent"
        print("   %-28s %-22s %s" % (c["name"][:28], c["domain"][:22], kind))
    if all((c.get("expires", -1) in (-1, None) or c.get("expires", -1) <= 0) for c in cookies):
        print("\nNOTE: every cookie is session-scoped, so this will die with the browser.")

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"cookies": cookies}), encoding="utf-8")
    try:
        out.chmod(0o600)
    except Exception:
        pass

    print("\nwritten to %s" % out)
    print("This file is a credential. It is outside every repo; keep it that way.")
    print("\nUse it with:")
    print('   python scripts/screenshots/capture_azure.py <url> out.png --load-session "%s"' % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
