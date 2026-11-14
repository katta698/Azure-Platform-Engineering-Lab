#!/usr/bin/env python3
"""Every week folder has an accurate row in the root README roadmap.

    python scripts/check_root_readme_current.py
    python scripts/check_root_readme_current.py --self-test

A week number is matched with a trailing-digit guard: without it, "Week 1"
matches the "Week 13" row and the check passes against the wrong line.
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEEK_DIR = re.compile(r"^week-(\d{2})-[a-z0-9-]+$")
PLANNED = re.compile(r"planned|blocked|candidate", re.I)


def row_for(readme, n):
    """The roadmap row for week n, or None.

    Accepts every format in the file: "| Week 19 |", "| [Week 13](...) |",
    and zero-padded "| [Week 01](...) |". (?!\\d) stops week 1 matching 13.
    """
    pat = re.compile(r"^\|[^|]*?\bWeek\s+0*%d(?!\d)\b" % n, re.I)
    for line in readme.split("\n"):
        if pat.match(line.strip()):
            return line.strip()
    return None


def problems(readme, folders):
    out = []
    for folder in sorted(folders):
        m = WEEK_DIR.match(folder)
        if not m:
            continue
        n = int(m.group(1))
        row = row_for(readme, n)
        if row is None:
            out.append("week %02d has a folder but no roadmap row" % n)
            continue
        if folder not in row:
            out.append("week %02d row does not link to %s" % (n, folder))
        if PLANNED.search(row.split("|")[-2] if row.count("|") > 2 else row):
            out.append("week %02d has a folder but the row still says Planned"
                       % n)
    return out


def self_test():
    good = ("| [Week 01](./week-01-thing) | x | y | ✅ Complete |\n"
            "| [Week 13](./week-13-other) | x | y | ✅ Complete |\n")
    cases = [
        ("a complete, linked row passes", good, ["week-01-thing"], 0),
        ("week 1 does not match the week 13 row",
         "| [Week 13](./week-13-other) | x | y | ✅ Complete |\n",
         ["week-01-thing"], 1),
        ("a folder with a Planned row fails",
         "| Week 07 | x | y | 📅 Planned |\n", ["week-07-thing"], 2),
        ("a row that does not link to the folder fails",
         "| [Week 05](./week-05-wrong) | x | y | ✅ Complete |\n",
         ["week-05-right"], 1),
        ("non-padded planned rows are still found",
         "| Week 9 | x | y | 📅 Planned |\n", ["week-09-thing"], 2),
    ]
    bad = 0
    for name, readme, folders, want in cases:
        got = len(problems(readme, folders))
        ok = got == want
        print("  %-46s %s (%d problem(s))" % (name, "ok" if ok else "FAIL", got))
        bad += not ok
    print("\n  %d/%d self-test(s) passed" % (len(cases) - bad, len(cases)))
    return 1 if bad else 0


def main():
    if "--self-test" in sys.argv:
        return self_test()

    readme = open(os.path.join(REPO, "README.md"), encoding="utf-8").read()
    folders = [d for d in os.listdir(REPO) if WEEK_DIR.match(d)]
    found = problems(readme, folders)

    print("  %d week folder(s) checked against the roadmap" % len(folders))
    if not found:
        return 0
    print()
    for f in found:
        print("    %s" % f)
    print()
    print("  The roadmap is the first thing anyone reads, and a built week")
    print("  it still calls Planned contradicts the published post.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
