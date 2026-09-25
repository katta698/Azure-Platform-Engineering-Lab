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
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

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
    # Sites whose auth token is memory-only can only be captured in the
    # session that signed in, so every shot from such a site has to happen
    # in one run. --also adds a target to that same run.
    ap.add_argument("--also", nargs=2, action="append", metavar=("URL", "PATH"),
                    default=[], help="Capture another url/path in the same session")
    # DO NOT point --login at app.terraform.io. HCP Terraform detects the
    # automated browser and refuses the sign-in as a security risk - in
    # Chromium for Testing, in Edge and in installed Chrome alike, on
    # 2026-09-25. Four attempts, two of them after a successful sign-in that
    # was then rejected. The session-cookie work below is real and worth
    # keeping for other sites, but it does not get past this: the block is on
    # signing in at all, not on holding the session afterwards.
    #
    # HCP screenshots are taken by hand and committed like any other asset.
    # Working around a vendor's anti-automation control to screenshot your own
    # account is not a thing this repo does.
    ap.add_argument("--login", action="store_true", help="Open a site and wait while you sign in.")
    ap.add_argument(
        "--login-url",
        default=PORTAL,
        help="Where --login goes. Defaults to the Azure portal; pass "
        "https://app.terraform.io/ to sign into the private module registry.",
    )
    ap.add_argument("--wait-ms", type=int, default=9000, help="Settle time after load")
    ap.add_argument("--width", type=int, default=1500)
    ap.add_argument("--height", type=int, default=950)
    ap.add_argument("--scale", type=int, default=2,
                    help="Device scale factor. Integer only - fractional scaling blurs text.")
    ap.add_argument("--goto-timeout", type=int, default=90000)
    ap.add_argument("--expand-tree", action="store_true")
    ap.add_argument("--expect", default="", help="Text that must be visible before saving")
    ap.add_argument("--click-text", default="", help="Click this text before capturing (e.g. a tab)")
    ap.add_argument("--click-wait-ms", type=int, default=6000)
    ap.add_argument("--login-timeout", type=int, default=300, help="Seconds to wait for sign-in")
    # A memory-only session cookie is lost when the window closes, which also
    # means it is lost to any mistake made during the capture. Writing the
    # cookies out the instant sign-in is detected turns one sign-in into as
    # many retries as the session lasts. Keep the file OUT of the repo: it is
    # a bearer credential.
    # Chromium for Testing is a separate install from whatever browser the
    # machine normally runs, and it can be broken on its own. Edge ships with
    # Windows and shares the engine, so it is the fallback that needs no
    # download. Each channel keeps its OWN profile directory: a sign-in in one
    # is not a sign-in in another.
    ap.add_argument("--browser", choices=["chromium", "msedge", "chrome"], default="chromium",
                    help="Which browser to drive")
    ap.add_argument("--save-session", default="", help="Write cookies here once signed in")
    ap.add_argument("--load-session", default="", help="Replay cookies written by --save-session")
    ap.add_argument(
        "--cookie-file",
        default="",
        help="File holding ONE session cookie value, for reusing a login from "
        "another browser. Format: <domain> <name> <value> on a single line. "
        "The value is never printed or logged. Keep the file gitignored.",
    )
    args = ap.parse_args()

    if not args.login and not (args.url and args.output_path):
        ap.error("give a url and an output path, or --login")

    PROFILE.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as pw:
        profile_dir = PROFILE if args.browser == "chromium" else PROFILE.with_name(
            f"{PROFILE.name}_{args.browser}"
        )
        profile_dir.mkdir(parents=True, exist_ok=True)

        context = pw.chromium.launch_persistent_context(
            str(profile_dir),
            headless=False,
            **({} if args.browser == "chromium" else {"channel": args.browser}),
            viewport={"width": args.width, "height": args.height},
            # Pinned, and pinned to an INTEGER.
            #
            # Left unset, Chromium inherits the display scaling of whatever
            # monitor the session happens to run on. Weeks 01-03 were captured
            # at 1.5x (2250x1425) and week 04 at 2.0x (3000x1900) from the same
            # script, with nothing in the repo recording why. Fractional scaling
            # is what makes portal text look soft: glyphs are rasterised onto
            # fractional pixel boundaries. An integer factor re-renders cleanly.
            #
            # It also makes the output reproducible - the same command produces
            # the same pixels on any machine, which a screenshot that ships in a
            # published post ought to.
            device_scale_factor=args.scale,
            args=["--start-maximized"],
        )
        # A session cookie lifted from another browser, injected as plaintext.
        #
        # Chrome encrypts cookie values with a key that is per-profile, so
        # copying an encrypted blob from one profile's Cookies database into
        # another's produces a cookie the destination cannot decrypt — it is
        # silently ignored and the page renders as signed out. The value has to
        # arrive decrypted and be set through the API instead.
        #
        # Read from a file rather than a flag so the value never reaches a shell
        # history, a process list or a log. It is not echoed on success either:
        # the only confirmation is the capture succeeding.
        if args.cookie_file:
            raw = Path(args.cookie_file).read_text(encoding="utf-8").strip()
            parts = raw.split(None, 2)
            if len(parts) != 3:
                sys.exit(
                    f"{args.cookie_file}: expected '<domain> <name> <value>' on one line."
                )
            domain, cname, cvalue = parts
            context.add_cookies([{
                "name": cname,
                "value": cvalue,
                "domain": domain,
                "path": "/",
                "httpOnly": True,
                "secure": True,
                "sameSite": "Lax",
            }])
            print(f"Injected 1 cookie ({cname}) for {domain}")

        if args.load_session:
            saved = json.loads(Path(args.load_session).read_text(encoding="utf-8"))
            context.add_cookies(saved["cookies"])
            print(f"Replayed {len(saved['cookies'])} cookies from {args.load_session}")

        page = context.pages[0] if context.pages else context.new_page()

        try:
            if args.login:
                # Not every page worth screenshotting is the Azure portal. The
                # private module registry is HCP, and signing into it is a
                # separate session in the same browser profile — so the target
                # and its "you have arrived" host are parameters, not constants.
                login_url = args.login_url
                target_host = urlparse(login_url).hostname or ""

                page.goto(login_url, wait_until="domcontentloaded", timeout=args.goto_timeout)
                print(f"Sign in to {target_host} in the window that just opened.")
                print("The profile is saved, so this is a one-time step per site.")
                print(f"Waiting up to {args.login_timeout}s for {target_host} to load...", flush=True)

                # Polled rather than input(). This is routinely run from a shell
                # with no stdin attached, where input() dies instantly with
                # EOFError and takes the sign-in window with it.
                deadline = args.login_timeout
                waited = 0
                while waited < deadline:
                    page.wait_for_timeout(5000)
                    waited += 5

                    # Scan EVERY page, not just the one opened first. A sign-in
                    # that hands off to an identity provider frequently finishes
                    # in a popup or a second tab, leaving the original page on
                    # the form forever - which reads as "sign-in never happened"
                    # when in fact it happened somewhere nobody was watching.
                    if waited % 30 == 0:
                        # Emitted BEFORE the landed-branch. It used to sit after
                        # it, so an iteration that found the target host and then
                        # bounced on the login-page check skipped the tick - the
                        # run printed nothing at all in the one state anybody
                        # would want reported.
                        for i, pg in enumerate(context.pages):
                            try:
                                body = (pg.evaluate(
                                    "() => document.body ? document.body.innerText.slice(0,120) : ''"
                                ) or "").replace(chr(10), " / ")
                            except Exception:
                                body = "<unreadable>"
                            print(f"  {waited}s: [{i}] {pg.url}", flush=True)
                            print(f"         text: {body}", flush=True)

                    landed = None
                    for pg in context.pages:
                        u = (pg.url or "").lower()
                        on_login = any(h in u for h in LOGIN_HOSTS) or any(p in u for p in LOGIN_PATHS)
                        if not on_login and target_host in u:
                            landed = pg
                            break
                    if landed is not None:
                        page = landed
                        try:
                            settle(page, 3000)
                            assert_not_a_login_page(page)
                        except SystemExit:
                            continue  # still mid sign-in; keep waiting
                        except Exception as e:
                            # Closing the window mid-run surfaces as
                            # TargetClosedError from deep inside Playwright and
                            # prints a 20-line traceback that buries the cause.
                            if "closed" not in str(e).lower():
                                raise
                            sys.exit(
                                "The browser window was closed before the capture ran. "
                                "Leave it open: this site's auth token is memory-only, so "
                                "signing in and capturing must happen in one session."
                            )
                        print(f"Signed in after {waited}s. Profile stored at: {profile_dir}")
                        if args.save_session:
                            # First thing after sign-in, before the capture is
                            # attempted. Two runs died here with the window
                            # closed mid-capture and 14 minutes of sign-in
                            # thrown away with it.
                            sp = Path(args.save_session)
                            sp.parent.mkdir(parents=True, exist_ok=True)
                            sp.write_text(json.dumps({"cookies": context.cookies()}), encoding="utf-8")
                            print(f"Session saved to {sp} - retries no longer need a sign-in.")
                        # Fall THROUGH to capture when a url was also given.
                        #
                        # Some sites authenticate with a SESSION cookie, which Chromium
                        # holds in memory and never writes to the profile. HCP Terraform
                        # is one: after --login the profile keeps _atlas_session_data and
                        # loses the token, so a later run lands back on the sign-in page
                        # however carefully the sign-in was done. Measured 2026-09-25,
                        # after three failed attempts across three weeks.
                        #
                        # The only reliable fix is to not close the browser in between:
                        # sign in and capture in one session.
                        if not (args.url and args.output_path):
                            return
                        print("Signed in - capturing in the SAME session, because the")
                        print("auth token is memory-only and will not survive a restart.")
                        break
                else:
                    # Only when the loop ran out of time. A `break` above means
                    # signed in, and must not land on this exit.
                    sys.exit(f"Timed out after {deadline}s without reaching a signed-in portal page.")

            secrets = secrets_from_env()
            if not secrets:
                print("NOTE: no AZ_* identifiers set — nothing will be masked.")

            for url, output_path in [(args.url, args.output_path)] + [tuple(a) for a in args.also]:
                out = Path(output_path)
                out.parent.mkdir(parents=True, exist_ok=True)

                page.goto(url, wait_until="domcontentloaded", timeout=args.goto_timeout)
                settle(page, args.wait_ms)
                assert_not_a_login_page(page)

                # Many portal blades open on a default tab. The Remediation blade
                # opens on "Policies to remediate", so capturing it without a click
                # yields a screenshot of the wrong tab that looks entirely plausible
                # -- it is a real blade with real rows, just not the one asked for.
                if args.click_text:
                    clicked = False
                    for frame in frames(page):
                        try:
                            target = frame.get_by_text(args.click_text, exact=False)
                            if target.count():
                                target.first.click(timeout=8000)
                                page.wait_for_timeout(args.click_wait_ms)
                                clicked = True
                                break
                        except Exception:
                            continue
                    if not clicked:
                        sys.exit(f"REFUSING TO SAVE: could not find {args.click_text!r} to click.")

                if args.expand_tree:
                    expand_tree(page, args.expect)

                # An --expect with no --expand-tree still has to be honoured, or the
                # flag silently does nothing outside the tree case.
                if args.expect and not args.expand_tree:
                    found = any(
                        args.expect in (f.evaluate("() => document.body ? document.body.innerText : ''") or "")
                        for f in frames(page)
                    )
                    if not found:
                        sys.exit(f"REFUSING TO SAVE: {args.expect!r} is not on the page.")

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
        except Exception as e:
            # Same reason as the guard in the sign-in loop: closing the window
            # mid-capture raises TargetClosedError from deep inside Playwright,
            # and the traceback buries the one fact that matters.
            if "closed" not in str(e).lower():
                raise
            sys.exit(
                "The browser window was closed before the capture finished. "
                "Re-run with --load-session to reuse the saved cookies instead "
                "of signing in again."
            )
        finally:
            try:
                context.close()
            except Exception:
                pass  # already gone if the window was closed by hand


if __name__ == "__main__":
    main()
