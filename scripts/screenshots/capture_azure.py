#!/usr/bin/env python3
"""
Capture a blog screenshot of an Azure portal (or HCP Terraform) page.

Two jobs, and the second one is the important one:
  1. take the picture
  2. refuse to write it if it would leak an identifier or if it is a sign-in page

Azure-specific reasons this is not a generic screenshot script:

  * The portal renders tenant IDs, subscription IDs, object IDs and MCA billing
    identifiers as ordinary table text, in tooltips, and inside read-only
    inputs. All four surfaces are redacted below, because innerText alone does
    not see input values.
  * The portal holds long-poll connections open and never fires `load`, and it
    repaints continuously. `page.goto(wait_until="load")` times out, and
    `page.screenshot()` waits for a stability that never arrives. This uses
    domcontentloaded plus an explicit settle, and captures through CDP.
  * The management group blade renders inside an iframe and virtualises its
    grid, so redaction has to run in every frame and immediately before the
    capture.

Authentication never passes through this script. Run `--login` once, sign in
yourself in the window that opens, and the profile persists for later runs.

Usage:
  python capture_azure.py --login
  python capture_azure.py <url> <output.png> [--wait-ms 9000] [--expand-tree]

Identifiers to mask come from the environment, so they never appear in shell
history or in this file:
  AZ_TENANT_ID, AZ_SUBSCRIPTION_IDS (comma-separated), AZ_BILLING_IDS
  (comma-separated), AZ_OBJECT_IDS (comma-separated)
"""

import argparse
import base64
import os
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

MASK = "█" * 12
PROFILE = Path(__file__).parent / "playwright_profile"
PORTAL = "https://portal.azure.com/"


def secrets_from_env() -> list[tuple[str, str]]:
    """Identifier -> label pairs to mask. Missing ones are simply skipped."""
    out: list[tuple[str, str]] = []
    if tenant := os.environ.get("AZ_TENANT_ID", "").strip():
        out.append((tenant, "tenant ID"))
    for key, label in (
        ("AZ_SUBSCRIPTION_IDS", "subscription ID"),
        ("AZ_BILLING_IDS", "billing identifier"),
        ("AZ_OBJECT_IDS", "object ID"),
    ):
        for value in os.environ.get(key, "").split(","):
            if value := value.strip():
                out.append((value, label))
    return out


# Hosts and paths that only ever serve authentication. Landing on one means the
# session is gone, whatever the page happens to render.
LOGIN_HOSTS = ("login.microsoftonline.com", "login.live.com", "login.windows.net")
LOGIN_PATHS = ("/auth/login", "/signin", "/oauth2/authorize", "/common/oauth2")


def assert_not_a_login_page(page) -> None:
    """Refuse to save a sign-in screen.

    The leak assertions answer "did anything escape", not "did we capture the
    page we asked for". A login page passes them all trivially, because it
    contains nothing to leak. Two identical pictures of a login form shipped in
    a published post once for exactly this reason.

    The URL is the reliable signal and is checked first. portal.azure.com
    bounces through /auth/login/ on its way to a sign-in page while still
    reporting the portal's own title, so a DOM-text check alone misses it.
    """
    url = (page.url or "").lower()
    if any(h in url for h in LOGIN_HOSTS) or any(p in url for p in LOGIN_PATHS):
        sys.exit(
            "REFUSING TO SAVE: redirected to an authentication URL.\n"
            f"  landed on: {page.url}\n"
            "  Fix: run `python capture_azure.py --login` and sign in, then retry."
        )

    hit = page.evaluate(
        """() => {
            if (document.querySelector('input[type=password]')) return 'password field';
            if (document.querySelector('input[name=loginfmt]')) return 'Microsoft sign-in field';
            const t = (document.title || '').toLowerCase();
            if (t.includes('sign in') || t.includes('log in')) return 'title: ' + document.title;
            const body = (document.body ? document.body.innerText : '').trim().toLowerCase();
            for (const p of ['sign in', 'pick an account', 'enter password']) {
                if (body.startsWith(p)) return 'body starts with: ' + p;
            }
            return null;
        }"""
    )
    if hit:
        sys.exit(
            f"REFUSING TO SAVE: this looks like a sign-in page ({hit}).\n"
            "  Fix: run `python capture_azure.py --login` and sign in, then retry."
        )


def frames(page):
    """Every frame, because the portal renders each blade inside an iframe."""
    return [page.main_frame] + [f for f in page.frames if f != page.main_frame]


def settle(page, wait_ms: int) -> None:
    """Let navigation finish before touching the DOM.

    A redaction pass is an evaluate(), and evaluate() throws if a navigation
    lands mid-call. The portal redirects after load more often than not, so
    settling first is not optional. networkidle never arrives on a long-poll
    page, hence the try/except and the explicit wait.
    """
    try:
        page.wait_for_load_state("networkidle", timeout=12000)
    except Exception:
        pass
    page.wait_for_timeout(wait_ms)


def expand_tree(page, expect: str = "") -> None:
    """Expand the management group tree, and verify it actually expanded.

    Three things make this harder than it looks, all learned the hard way:

    * "Expand / Collapse all" is a TOGGLE. Clicking it blind on an
      already-expanded tree collapses it, and the capture then shows two rows
      where the whole point was the nesting.
    * The blade's grid uses role="presentation", not role="treegrid" or
      role="row". Counting rows by ARIA role silently returns zero and every
      heuristic built on it reports success while doing nothing.
    * Row toggles carry aria-expanded, but so do the portal's own navigation
      menus. Clicking those navigates away and captures the wrong screen.

    So the success test is not a row count or a click count — it is whether the
    thing the screenshot exists to show is present on the page. Pass `expect`
    (e.g. a subscription name) and this stops as soon as it appears.
    """
    before = page.url

    def visible_text() -> str:
        """Text from EVERY frame, not just the top document.

        The portal renders each blade in a `sandbox-N.reactblade.portal.azure.net`
        iframe, so the top document contains only the chrome — the banner, the
        left nav and the Copilot suggestions. `page.evaluate` sees none of the
        grid. Any check written against the top document alone reports an empty
        page while the screenshot plainly shows a table, which is how several
        rounds of "expansion silently did nothing" happened here.
        """
        out = []
        for frame in frames(page):
            try:
                out.append(frame.evaluate("() => document.body ? document.body.innerText : ''") or "")
            except Exception:
                continue
        return "\n".join(out)

    def done() -> bool:
        return bool(expect) and expect in visible_text()

    if done():
        return

    # The blade iframe attaches a few seconds after the top document loads, so
    # wait for the grid itself rather than assuming it is already there.
    for _ in range(20):
        if any("Expand / Collapse" in t for t in [visible_text()]):
            break
        page.wait_for_timeout(1000)

    # First try the portal's own control. Look for it by TEXT, in every frame —
    # it is not exposed with an accessible button name, so get_by_role finds
    # nothing.
    for frame in frames(page):
        try:
            control = frame.get_by_text("Expand / Collapse all", exact=False)
            if control.count():
                control.first.click(timeout=8000)
                page.wait_for_timeout(4000)
                break
        except Exception:
            continue

    # Then click row toggles directly until the expected text shows up. Scoped
    # away from the portal chrome: anything inside a nav, menu, banner or
    # complementary region is navigation, and clicking those navigates away.
    for _ in range(5):
        if done():
            break
        clicked = 0
        for frame in frames(page):
            try:
                clicked += frame.evaluate(
                    """() => {
                        const skip = 'nav, [role=navigation], [role=menu], [role=menubar], [role=banner], [role=complementary]';
                        let n = 0;
                        for (const el of document.querySelectorAll('[aria-expanded="false"]')) {
                            if (el.closest(skip)) continue;
                            if (!(el.offsetWidth || el.offsetHeight)) continue;
                            try { el.click(); n++; } catch (e) {}
                        }
                        return n;
                    }"""
                ) or 0
            except Exception:
                continue
        if not clicked:
            break
        page.wait_for_timeout(2500)

    if page.url.split("?")[0] != before.split("?")[0]:
        sys.exit(
            "REFUSING TO SAVE: expanding the tree navigated away.\n"
            f"  from: {before}\n  to:   {page.url}"
        )

    if expect and not done():
        sys.exit(
            f"REFUSING TO SAVE: the tree never expanded - {expect!r} is not on the page.\n"
            "  A collapsed tree is not evidence of a hierarchy."
        )


REDACT_JS = """([pairs, mask]) => {
    const swap = (s) => {
        let v = s;
        for (const [needle] of pairs) if (v.includes(needle)) v = v.split(needle).join(mask);
        return v;
    };
    if (!document.body) return 0;
    let n = 0;
    const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walk.nextNode()) nodes.push(walk.currentNode);
    for (const node of nodes) {
        const v = swap(node.nodeValue);
        if (v !== node.nodeValue) { node.nodeValue = v; n++; }
    }
    for (const el of document.querySelectorAll('[value],[title],[aria-label]')) {
        for (const attr of ['value', 'title', 'aria-label']) {
            const cur = el.getAttribute(attr);
            if (!cur) continue;
            const v = swap(cur);
            if (v !== cur) { el.setAttribute(attr, v); n++; }
        }
    }
    // Form controls render the value PROPERTY, not the attribute, and the two
    // are independent once the page has scripted the field. The portal puts IDs
    // in read-only inputs, which the attribute pass above leaves untouched and
    // which innerText never sees.
    for (const el of document.querySelectorAll('input, textarea')) {
        if (typeof el.value !== 'string' || !el.value) continue;
        const v = swap(el.value);
        if (v !== el.value) { el.value = v; n++; }
    }
    return n;
}"""

VISIBLE_JS = """() => {
    let s = document.body ? document.body.innerText : '';
    for (const el of document.querySelectorAll('input, textarea')) {
        if (typeof el.value === 'string') s += '\\n' + el.value;
        const a = el.getAttribute('value');
        if (a) s += '\\n' + a;
    }
    for (const el of document.querySelectorAll('[title],[aria-label]')) {
        s += '\\n' + (el.getAttribute('title') || '') + '\\n' + (el.getAttribute('aria-label') || '');
    }
    return s;
}"""


def redact(page, secrets) -> int:
    if not secrets:
        return 0
    total = 0
    for frame in frames(page):
        try:
            total += frame.evaluate(REDACT_JS, [secrets, MASK]) or 0
        except Exception:
            continue  # frame detached mid-pass; the assert below is the real gate
    return total


def assert_gone(page, secrets) -> None:
    """Last line of defence: fail loudly rather than write a leaking PNG."""
    for frame in frames(page):
        try:
            visible = frame.evaluate(VISIBLE_JS)
        except Exception:
            continue
        for needle, label in secrets:
            if needle in visible:
                sys.exit(f"REFUSING TO SAVE: {label} still visible after redaction.")


def screenshot_via_cdp(page, out: Path) -> None:
    """Capture through the DevTools protocol rather than page.screenshot().

    page.screenshot() waits for the page to stop changing. The portal never
    stops changing — it holds long-poll connections and repaints continuously —
    so the call hangs for its whole timeout and fails having written nothing.
    animations="disabled" does not help: the instability is network-driven
    repaint, not CSS animation.

    Page.captureScreenshot has no stability heuristic. It grabs the frame as it
    is, which is all a blog screenshot needs.
    """
    client = page.context.new_cdp_session(page)
    try:
        result = client.send("Page.captureScreenshot", {"format": "png", "captureBeyondViewport": False})
        out.write_bytes(base64.b64decode(result["data"]))
    finally:
        try:
            client.detach()
        except Exception:
            pass


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("url", nargs="?")
    ap.add_argument("output_path", nargs="?")
    ap.add_argument("--login", action="store_true", help="Open the portal and wait while you sign in.")
    ap.add_argument("--wait-ms", type=int, default=9000, help="Settle time after load")
    ap.add_argument("--width", type=int, default=1500)
    ap.add_argument("--height", type=int, default=950)
    ap.add_argument("--goto-timeout", type=int, default=90000)
    ap.add_argument("--expand-tree", action="store_true")
    ap.add_argument("--expect", default="", help="Text that must be visible before saving")
    ap.add_argument("--login-timeout", type=int, default=300, help="Seconds to wait for sign-in")
    args = ap.parse_args()

    if not args.login and not (args.url and args.output_path):
        ap.error("give a url and an output path, or --login")

    PROFILE.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as pw:
        context = pw.chromium.launch_persistent_context(
            str(PROFILE),
            headless=False,
            viewport={"width": args.width, "height": args.height},
            args=["--start-maximized"],
        )
        page = context.pages[0] if context.pages else context.new_page()

        try:
            if args.login:
                page.goto(PORTAL, wait_until="domcontentloaded", timeout=args.goto_timeout)
                print("Sign in to the Azure portal in the window that just opened.")
                print("The profile is saved, so this is a one-time step.")
                print(f"Waiting up to {args.login_timeout}s for the portal to load...", flush=True)

                # Polled rather than input(). This is routinely run from a shell
                # with no stdin attached, where input() dies instantly with
                # EOFError and takes the sign-in window with it.
                deadline = args.login_timeout
                waited = 0
                while waited < deadline:
                    page.wait_for_timeout(5000)
                    waited += 5
                    url = (page.url or "").lower()
                    on_login = any(h in url for h in LOGIN_HOSTS) or any(p in url for p in LOGIN_PATHS)
                    if not on_login and "portal.azure.com" in url:
                        try:
                            settle(page, 3000)
                            assert_not_a_login_page(page)
                        except SystemExit:
                            continue  # still mid sign-in; keep waiting
                        print(f"Signed in after {waited}s. Profile stored at: {PROFILE}")
                        return
                    if waited % 30 == 0:
                        print(f"  {waited}s: still waiting...", flush=True)

                sys.exit(f"Timed out after {deadline}s without reaching a signed-in portal page.")

            secrets = secrets_from_env()
            if not secrets:
                print("NOTE: no AZ_* identifiers set — nothing will be masked.")

            out = Path(args.output_path)
            out.parent.mkdir(parents=True, exist_ok=True)

            page.goto(args.url, wait_until="domcontentloaded", timeout=args.goto_timeout)
            settle(page, args.wait_ms)
            assert_not_a_login_page(page)

            if args.expand_tree:
                expand_tree(page, args.expect)

            # Redact immediately before the capture. The portal virtualises its
            # grids and repaints on its own schedule, so a redaction done any
            # earlier can be undone by a re-render before the shutter fires.
            changed = redact(page, secrets)
            assert_gone(page, secrets)

            # Checked twice on purpose. A session can lapse between the first
            # check and the save, and the screenshot is what reaches disk — so
            # the guard that matters is the one closest to it.
            assert_not_a_login_page(page)
            screenshot_via_cdp(page, out)

            masked = ", ".join(sorted({label for _, label in secrets})) or "nothing"
            print(f"Verified: masked {masked} ({changed} replacements)")
            print(f"Saved: {out}")
        finally:
            context.close()


if __name__ == "__main__":
    main()
