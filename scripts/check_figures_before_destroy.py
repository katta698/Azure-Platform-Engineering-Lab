#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Refuse to destroy a week whose figures have not been captured yet.

    python scripts/check_figures_before_destroy.py week-21-bluegreen-ecs
    python scripts/check_figures_before_destroy.py --self-test

Why this exists (2026-09-30)
----------------------------
Week 21 was torn down at 21:23 and the post was written afterwards. When Jay
asked "no need to show screenshots on what we deployed?", the answer was that
there were none and none could be taken -- the ALB, the target groups and the
cluster no longer existed.

That is the same ordering mistake identified during Week 20 and stated plainly
at the time: **teardown is the only irreversible step in a week.** Publishing
can be edited. Destroying cannot. Every uncaptured figure becomes permanently
uncapturable the moment the destroy applies.

Saying so did not prevent it. This does.

THE RULE
    A week's FIGURE_PLAN.md declares its slots. Before that week may be
    destroyed, every declared slot must either exist on disk, be retired in
    UNUSED.txt with a reason, or be a cost slot -- which by definition cannot
    be captured until roughly a day after teardown.

`hcp_destroy.py` calls this first and stops on a non-zero exit. `--force`
exists for the deliberate exception and says what it is overriding.
"""
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# | 01 | `01-hcp-run-applied.png` | Section | ... |
SLOT = re.compile(r"^\|\s*(\d+)\s*\|\s*`([^`]+\.png)`\s*\|", re.M)

# A cost figure is taken from Cost Explorer once AWS posts the charges, which
# is about a day after the resources are gone. Requiring it before teardown
# would make the gate impossible to satisfy, and an impossible gate gets
# bypassed on every run until someone deletes it.
COST_HINT = re.compile(r"cost", re.I)


def missing_figures(plan_text, on_disk, declared_unused):
    """Slots that must exist and do not. Pure, so --self-test can drive it."""
    missing = []
    for num, filename in SLOT.findall(plan_text):
        if filename in on_disk or filename in declared_unused:
            continue
        if COST_HINT.search(filename):
            continue
        missing.append((num, filename))
    return missing


def self_test():
    PLAN = (
        "| 01 | `01-hcp-run-applied.png` | apply | HCP run | console | the apply |\n"
        "| 02 | `02-service.png` | apply | the service | console | the apply |\n"
        "| 03 | `03-retired.png` | testing | covered by 02 | console | never |\n"
        "| 06 | `06-cost-explorer.png` | Cost | spend by service | console | ~24h after |\n"
    )
    cases = [
        ("a missing slot is caught",
         missing_figures(PLAN, {"01-hcp-run-applied.png"}, set()) != []),
        ("names the missing slot, not just a count",
         "02-service.png" in [f for _, f in
                              missing_figures(PLAN, {"01-hcp-run-applied.png"}, set())]),
        ("a slot retired in UNUSED.txt is not missing",
         "03-retired.png" not in [f for _, f in missing_figures(
             PLAN, {"01-hcp-run-applied.png", "02-service.png"}, {"03-retired.png"})]),
        ("the cost slot is never required before teardown",
         "06-cost-explorer.png" not in [f for _, f in missing_figures(PLAN, set(), set())]),
        ("a fully captured week passes",
         missing_figures(PLAN, {"01-hcp-run-applied.png", "02-service.png"},
                         {"03-retired.png"}) == []),
        ("an empty plan cannot accidentally pass a week with no figures",
         missing_figures("", set(), set()) == []),   # documented: no plan, no claim
    ]
    bad = 0
    for label, ok in cases:
        print("  [%s] %s" % ("PASS" if ok else "DEAD", label))
        bad += not ok
    print()
    if bad:
        print("%d case(s) DO NOT WORK." % bad)
        return 1
    print("All %d teardown-gate cases pass." % len(cases))
    return 0


def main():
    if "--self-test" in sys.argv:
        return self_test()
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not args:
        print("usage: check_figures_before_destroy.py <week-folder>")
        return 2
    week = args[0]

    plan_path = os.path.join(REPO, week, "docs", "FIGURE_PLAN.md")
    shots_dir = os.path.join(REPO, week, "docs", "blog", "screenshots")

    if not os.path.isfile(plan_path):
        # No plan means no declared slots, so nothing can be shown missing.
        # Say that out loud rather than printing a reassuring pass.
        print("  no FIGURE_PLAN.md for %s -- this gate checked nothing" % week)
        return 0

    plan = open(plan_path, encoding="utf-8", errors="replace").read()
    on_disk = set(os.listdir(shots_dir)) if os.path.isdir(shots_dir) else set()

    unused_path = os.path.join(shots_dir, "UNUSED.txt")
    declared = set()
    if os.path.isfile(unused_path):
        declared = {l.strip() for l in open(unused_path, encoding="utf-8")
                    if l.strip() and not l.startswith("#")}

    missing = missing_figures(plan, on_disk, declared)
    print("  %s: %d slot(s) declared, %d captured" %
          (week, len(SLOT.findall(plan)), len(on_disk & {f for _, f in SLOT.findall(plan)})))

    if missing:
        print("  %d NOT CAPTURED:" % len(missing))
        for num, f in missing:
            print("        slot %s  %s" % (num, f))
        print()
        print("  Teardown is the only irreversible step in a week. Every one of")
        print("  these becomes permanently uncapturable the moment it applies.")
        print("  Capture them, or retire them in UNUSED.txt with a reason.")
        return 1

    print("  every declared figure is captured or retired -- safe to destroy.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
