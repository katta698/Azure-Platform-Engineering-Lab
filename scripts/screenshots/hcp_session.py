#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Keep a replayable HCP session fresh, automatically.

WHY (2026-10-23)
----------------
HCP Terraform sets one persistent cookie, `_atlas_session_data`, with a ~30
day expiry. Replaying it into a clean headless browser authenticates fully -
no --cdp, no sign-in, no window.

But HCP **rotates the value** as the live session is used. Measured the same
evening: a capture worked at 21:29 and the identical command failed at 22:31
with "session expired", because the Chrome the human had open kept using HCP
and the server moved the session on. The saved snapshot was stale.

So a saved file is not a credential you export once and forget. It is a
snapshot that needs refreshing from the live browser. That refresh is one
CDP call and costs about a second, so the capture tools just do it
themselves rather than asking anyone to remember.

WHAT THIS MEANS IN PRACTICE
---------------------------
  * keep one Chrome signed in to HCP, started with --remote-debugging-port
  * captures refresh from it silently and run headless
  * nobody types a password weekly, in any lab

If that Chrome is closed, the last snapshot is used as-is. It may still work;
if it has rotated, the capture tool's own sign-in guard refuses to save and
says so, which is the correct loud failure.
"""
import json
import pathlib

DEFAULT_SESSION = pathlib.Path.home() / ".claude" / "hcp-session.json"
DEFAULT_CDP = "http://127.0.0.1:9222"


def refresh_if_possible(session_path=None, cdp=DEFAULT_CDP, domain="terraform.io", quiet=False):
    """Re-export cookies from a running signed-in browser. Best effort.

    Returns True if the file was refreshed, False if it was left alone.
    Never raises: a missing browser is normal, and the caller should fall
    back to whatever snapshot already exists.
    """
    path = pathlib.Path(session_path or DEFAULT_SESSION)
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        return False

    try:
        with sync_playwright() as p:
            browser = p.chromium.connect_over_cdp(cdp)
            cookies = [c for ctx in browser.contexts for c in ctx.cookies()
                       if domain in c.get("domain", "")]
            browser.close()
    except Exception:
        return False  # no debuggable browser: use whatever is on disk

    if not cookies:
        return False

    try:
        previous = json.loads(path.read_text(encoding="utf-8")).get("cookies", [])
    except Exception:
        previous = []

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"cookies": cookies}), encoding="utf-8")
    try:
        path.chmod(0o600)
    except Exception:
        pass

    rotated = (not previous) or previous[0].get("value") != cookies[0].get("value")
    if not quiet:
        print("Refreshed HCP session from the running browser%s"
              % (" (value had rotated)" if rotated else ""))
    return True


if __name__ == "__main__":
    ok = refresh_if_possible()
    print("refreshed" if ok else "no running browser to refresh from; existing file left as is")
