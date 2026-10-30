#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Audit every Azure lab week against the Master Standard (Jay, 2026-10-25).

    python scripts/audit_standard.py            # the gap table
    python scripts/audit_standard.py --detail   # plus what each week is missing

It reports, it does not fix, and it never guesses. A missing section is a fact
about the file; a missing MEASUREMENT is a gap that cannot be closed by editing,
because the week is torn down and the standard forbids inventing evidence.
Those two are listed separately on purpose.

WHY THE "9/9" COLUMN WAS REPLACED (2026-10-30)
----------------------------------------------
This script used to print a headline score counting HEADINGS that matched. It
reported all eleven Azure weeks at 9/9 for days while nine of them did not
follow the standard at all -- their section 2 was a bulleted list rather than
the compact table it asks for, and three still carried the retired file-tree
card. The score was true and useless: a heading is not its content.

Worse, it was the number being quoted as evidence of quality. An instrument
that answers a question nobody asked, in the shape of the question they did,
is more dangerous than no instrument.

The form check now DELEGATES to the blog repo's check_lab_post_shape.py rather
than re-implementing it here. Two checkers scoring the same posts by different
rules is exactly how the gap survived: this one said 9/9, that one said twelve
deviations, and only one of them was gated on push. If the blog checker cannot
be imported, this prints FORM NOT CHECKED and exits non-zero. It does not fall
back to counting headings and calling it a score.
"""
import argparse
import html
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BLOG_POSTS = r"C:\Projects\Engineering\katta698.github.io\posts"

# The nine blog sections. Patterns anchor on the opening words because the
# em-dash subtitles vary.
BLOG_SECTIONS = [
    ("Lab Overview",   r"^Lab Overview\b"),
    ("Services",       r"^Cloud Services\b"),
    ("Architecture",   r"^Architecture\b"),
    ("Prerequisites",  r"^Prerequisites\b"),
    ("Implementation", r"^(Step-by-Step )?Implementation\b|^How We Built It\b"),
    ("Validation",     r"^Validation\b"),
    ("Security+Cost",  r"^Security and Cost\b"),
    ("Troubleshoot",   r"^Troubleshooting\b"),
    ("Cleanup",        r"^Cleanup\b"),
]

# What the GitHub lab guide has to let someone do. Matched on README headings
# and body, because a guide can carry these under its own wording.
GUIDE_PARTS = [
    ("prereqs",     r"prerequisite|permission|required role"),
    ("versions",    r"terraform\s*[>~]?=?\s*\d|provider version|azurerm.*\d\.\d"),
    ("variables",   r"tfvars|variable\b.*required|\| *`?var"),
    ("deploy cmds", r"deploy\.sh|terraform apply"),
    ("expected out", r"expected|should print|prints when it passes|reports `|outputs?:|expect \d"),
    ("validation",  r"validate\.sh|validation"),
    ("cleanup",     r"cleanup\.sh|teardown"),
    ("verify gone", r"still there|counts? what is left|counts what|verif\w+ the teardown|verify.*remov|expect 0|0\b.*registries"),
    ("limitations", r"known limitation|what production|production adds"),
]


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None


def post_path(week_dir):
    """The blog post for a week folder, by slug. Azure posts only."""
    slug = week_dir  # folder name IS the slug for weeks 02-10
    cand = os.path.join(BLOG_POSTS, slug + ".html")
    if os.path.exists(cand):
        return cand
    # week 01 shipped as week-01-azure-landing-zone
    n = week_dir.split("-")[1]
    for name in sorted(os.listdir(BLOG_POSTS)):
        if name.startswith("week-%s-" % n) and name.endswith(".html"):
            body = read(os.path.join(BLOG_POSTS, name)) or ""
            if "Azure Platform Engineering Lab" in body or "- Azure\n" in body:
                return os.path.join(BLOG_POSTS, name)
    return None


BLOG_CHECK = r"C:\Projects\Engineering\katta698.github.io\scripts\check_lab_post_shape.py"

# The ids the Azure series uses. Declared in the blog checker too; if the two
# ever disagree this will under-report, so it is read from there when possible.
AZURE_IDS = ["overview", "services", "architecture", "prereqs", "build",
             "validation", "seccost", "troubleshooting", "cleanup"]


def _load_blog_checker():
    """Import the gated form-checker, or return None with the reason."""
    import importlib.util
    if not os.path.exists(BLOG_CHECK):
        return None, "not found at %s" % BLOG_CHECK
    try:
        spec = importlib.util.spec_from_file_location("blogcheck", BLOG_CHECK)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod, None
    except Exception as exc:                       # noqa: BLE001 - report, do not hide
        return None, "%s: %s" % (type(exc).__name__, exc)


def form_problems(checker, path):
    """What the gated checker says about this post's FORM, not its headings."""
    if checker is None:
        return None
    text = read(path)
    if text is None:
        return None
    required = getattr(checker, "SERIES", {}).get("Azure Weekly Lab") or AZURE_IDS
    report = []
    n = checker.check_text(text, os.path.basename(path), report, required=required)
    cleaned = []
    for line in report:
        line = line.strip()
        line = re.sub(r"^\[FAIL\]\s*\S+?:\s*", "", line)
        cleaned.append(line)
    return n, cleaned


def audit_post(path):
    s = read(path)
    if s is None:
        return None
    body = s[s.find('<div id="jk-post">'):] or s
    flat = re.sub(r"\s+", " ", body)
    heads = [html.unescape(re.sub(r"<[^>]+>", "", h)).strip()
             for h in re.findall(r"<h2[^>]*>(.*?)</h2>", flat, re.S)]
    heads = [h for h in heads if h and "In This Post" not in h]

    present = [lbl for lbl, pat in BLOG_SECTIONS
               if any(re.search(pat, h) for h in heads)]
    missing = [lbl for lbl, _ in BLOG_SECTIONS if lbl not in present]

    tables = len(re.findall(r"<table[\s>]", flat))
    wrapped = 0
    for m in re.finditer(r"<table[\s>]", flat):
        before = flat[max(0, m.start() - 300):m.start()]
        if "table-scroll" in before or "overflow-x" in before:
            wrapped += 1

    imgs = re.findall(r"<img [^>]*>", body)
    figs = len(re.findall(r"<figcaption", body))

    # The standard wants expected vs actual vs status in validation.
    has_status = "<th>Status</th>" in flat
    has_expected = bool(re.search(r"<th>Expected", flat))

    # Troubleshooting in the required shape.
    tshape = bool(re.search(r"Root cause|Root Cause", flat)) and \
        bool(re.search(r"Lesson learned|Lesson Learned", flat))

    txt = html.unescape(re.sub(r"<[^>]+>", " ", body))
    words = len([w for w in txt.split() if re.search(r"[A-Za-z0-9]", w)])

    return dict(missing=missing, n_present=len(present), tables=tables,
                wrapped=wrapped, imgs=len(imgs), figs=figs,
                has_status=has_status, has_expected=has_expected,
                tshape=tshape, words=words, path=path)


def audit_guide(week_dir):
    """Score the runbook, which lives in LAB.md where one exists.

    Jay, 2026-10-25, following GCP: the narrative and the runbook are
    different documents for different readers. README.md keeps the cost note
    and the design reasoning; LAB.md is how you rebuild it. Weeks not yet
    split still have everything in README.md, so fall back to it.

    CAUTION: the GUIDE_PARTS patterns below are KEYWORD matches, and keyword
    matches establish presence, never absence. This exact method produced five
    false "missing" findings against the AWS and GCP labs on 2026-10-25 --
    "The outcome" did not match "expected outcome", "Production delta" did not
    match "known limitation". Treat a missing part as a prompt to READ the
    file, not as a finding.
    """
    path = os.path.join(LAB, week_dir, "LAB.md")
    if not os.path.exists(path):
        path = os.path.join(LAB, week_dir, "README.md")
    s = read(path)
    if s is None:
        return None
    low = s.lower()
    missing = [name for name, pat in GUIDE_PARTS
               if not re.search(pat, low, re.I)]
    words = len(s.split())
    return dict(missing=missing, n_present=len(GUIDE_PARTS) - len(missing),
                words=words, path=path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--detail", action="store_true")
    args = ap.parse_args()

    weeks = sorted(d for d in os.listdir(LAB)
                   if re.match(r"^week-\d\d-", d) and
                   os.path.isdir(os.path.join(LAB, d)))

    print()
    checker, why = _load_blog_checker()
    if checker is None:
        print("  FORM NOT CHECKED: could not load the gated checker -- %s" % why)
        print("  Refusing to print a heading count in its place. Fix the path,")
        print("  or run check_lab_post_shape.py in the blog repo directly.")
        return 2

    print("  AZURE LAB vs THE MASTER STANDARD")
    print("  form verdict comes from check_lab_post_shape.py, the gated checker")
    print("  %-26s %-14s %-10s %-9s %-7s %s"
          % ("week", "blog FORM", "guide 9", "figs/cap", "words", "notes"))
    print("  " + "-" * 94)

    rows = []
    bad_form = 0
    for w in weeks:
        pp = post_path(w)
        post = audit_post(pp) if pp else None
        form = form_problems(checker, pp) if pp else None
        guide = audit_guide(w)
        notes = []
        if post:
            if post["tables"] and post["wrapped"] < post["tables"]:
                notes.append("tables unwrapped")
            if not post["has_status"]:
                notes.append("no Status col")
            elif not post["has_expected"]:
                notes.append("no Expected col")
            if not post["tshape"]:
                notes.append("troubleshoot shape")
            if post["imgs"] != post["figs"]:
                notes.append("%d img/%d cap" % (post["imgs"], post["figs"]))
            if post["words"] > 2500:
                notes.append("long")
        else:
            notes.append("POST NOT FOUND")
        if form is None:
            verdict = "-"
        elif form[0] == 0:
            verdict = "ok"
        else:
            verdict = "%d PROBLEM%s" % (form[0], "" if form[0] == 1 else "S")
            bad_form += 1
        print("  %-26s %-14s %-10s %-9s %-7s %s"
              % (w, verdict,
                 ("%d/9?" % guide["n_present"]) if guide else "-",
                 ("%d/%d" % (post["imgs"], post["figs"])) if post else "-",
                 str(post["words"]) if post else "-",
                 ", ".join(notes) or "ok"))
        rows.append((w, post, guide, form))

    if args.detail:
        for w, post, guide, form in rows:
            if form and form[0]:
                print()
                print("  == %s -- FORM" % w)
                for line in form[1]:
                    print("     %s" % line)
    if args.detail:
        for w, post, guide, form in rows:
            print()
            print("  == %s" % w)
            if post:
                print("     blog missing : %s"
                      % (", ".join(post["missing"]) or "nothing"))
            if guide:
                # NOT "missing". This is a keyword scan, and a keyword scan
                # establishes presence, never absence. Three times today it
                # flagged a requirement that was covered in different words:
                # "Verifying nothing survived" did not match `verify.*remov`,
                # "Expect `0`" did not match `expect 0` because of a backtick.
                print("     guide: READ to confirm -> %s"
                      % (", ".join(guide["missing"]) or "nothing flagged"))
    print()
    print("  blog FORM is the gated checker's verdict on CONTENT, not on")
    print("  headings -- it reads what sits under each heading.")
    print("  figs/cap counts literal tags.")
    print("  guide 9? is a KEYWORD SCAN and carries a question mark for a reason.")
    print("  A flagged part means OPEN THE FILE, not that anything is missing.")
    print()
    print("  FORM ignores the blog checker's MIGRATION_PENDING list on purpose.")
    print("  That list is what the PUSH GATE agrees to wave through; this audit")
    print("  shows what is actually true. Weeks 01-09 are parked there and")
    print("  still appear here.")
    print()
    print("  A measurement that was never captured cannot be fixed by editing:")
    print("  these weeks are torn down, and the standard forbids inventing")
    print("  evidence. Those get named, not filled.")
    print()


if __name__ == "__main__":
    # The return value is the exit code. It used to be discarded, so the
    # FORM NOT CHECKED path printed a refusal and still exited 0 -- a refusal
    # nothing could act on, which is the same defect in miniature as the score
    # this script used to print.
    raise SystemExit(main())
