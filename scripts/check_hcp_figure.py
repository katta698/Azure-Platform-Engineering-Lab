#!/usr/bin/env python3
"""A week whose Terraform uses HCP must show the HCP workspace.

    python scripts/check_hcp_figure.py
    python scripts/check_hcp_figure.py --self-test

Weeks 03, 05, 07, 08, 09, 10 and 11 all carry an hcp figure; weeks 12 and 13
used HCP for state and shipped without one, because FIGURE_PLAN.md is written
fresh each week and nothing compared it against what earlier weeks included.

The figure is only capturable while the week is deployed -- the workspace
reports resource-count 0 after teardown -- so this is checked before destroy,
not after.
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEEK = re.compile(r"^week-(\d{2})-[a-z0-9-]+$")
HCP = re.compile(r"^\s*cloud\s*\{", re.M)


def uses_hcp(week_dir):
    tf = os.path.join(REPO, week_dir, "terraform")
    if not os.path.isdir(tf):
        return False
    for f in os.listdir(tf):
        if f.endswith(".tf"):
            with open(os.path.join(tf, f), encoding="utf-8", errors="replace") as fh:
                if HCP.search(fh.read()):
                    return True
    return False


def has_hcp_figure(week_dir):
    for sub in ("docs/blog/screenshots", "docs/blog/figures"):
        d = os.path.join(REPO, week_dir, sub)
        if os.path.isdir(d) and any("hcp" in f.lower() for f in os.listdir(d)):
            return True
    unused = os.path.join(REPO, week_dir, "docs/blog/screenshots/UNUSED.txt")
    if os.path.isfile(unused):
        with open(unused, encoding="utf-8", errors="replace") as fh:
            if "hcp" in fh.read().lower():
                return True          # retired with a reason, which is allowed
    return False


def problems(weeks):
    return [w for w in sorted(weeks) if uses_hcp(w) and not has_hcp_figure(w)]


def self_test():
    cases = []
    real = [d for d in os.listdir(REPO) if WEEK.match(d)]
    for w in sorted(real):
        cases.append((w, uses_hcp(w), has_hcp_figure(w)))
    print("  week                                    uses HCP   has figure")
    bad = 0
    for w, u, h in cases:
        flag = "  <-- MISSING" if (u and not h) else ""
        print("  %-38s %-10s %s%s" % (w, u, h, flag))
        bad += u and not h
    print("\n  %d week(s) use HCP without a figure" % bad)
    return 0


def main():
    if "--self-test" in sys.argv:
        return self_test()
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    weeks = args if args else [d for d in os.listdir(REPO) if WEEK.match(d)]
    found = problems(weeks)
    print("  %d week(s) checked for an HCP figure" % len(weeks))
    if not found:
        return 0
    print()
    for w in found:
        print("    %s uses a cloud {} block and has no hcp figure" % w)
    print()
    print("  The HCP workspace reports resource-count 0 after teardown, so")
    print("  capture it while deployed or retire it in UNUSED.txt.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
