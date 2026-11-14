#!/usr/bin/env python3
"""Every week folder is linked from the tracker in README.md.

    python scripts/check_week_tracker.py

The tracker drifts because updating it is a manual step nothing verifies:
week 12 shipped, was published and torn down, and its row still read
"Planned". A folder that exists must be linked from its row.
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    weeks = sorted(d for d in os.listdir(REPO)
                   if re.fullmatch(r"week-\d{2}-[a-z0-9-]+", d))
    readme = open(os.path.join(REPO, "README.md"), encoding="utf-8").read()

    missing = [w for w in weeks if "(%s)" % w not in readme]
    print("  %d week folder(s), %d linked" % (len(weeks), len(weeks) - len(missing)))
    if not missing:
        return 0
    print("\n  NOT LINKED from the week tracker:")
    for w in missing:
        n = w.split("-")[1]
        print("      %s   expected a row starting  | [%s](%s) |" % (w, n, w))
    print("\n  A built week that the tracker still calls Planned is the only")
    print("  public signal that it shipped, and it is wrong.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
