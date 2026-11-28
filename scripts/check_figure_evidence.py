#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A figure must contain the evidence its NAME promises.

    python scripts/check_figure_evidence.py
    python scripts/check_figure_evidence.py --self-test

Why this exists
---------------
Weeks 12, 13 and 14 each shipped a figure called `02-terraform-apply.png`
whose content was `$ terraform state list`. Three published posts, one
promise, never kept. Jay found it, after asking about it more than once:

    "Didn't we use Terraform to deploy the code? If so, why we don't have
    Terraform apply screenshot? Asking again and again."

The drift is documented precisely because it is the point. Week 12's figure
plan asked for the right thing:

    | 02 | `02-terraform-apply.png` | ... | `Apply complete! Resources: 7 added` |

and its card showed a state list anyway. At week 13 I wrote a new plan by
copying week 12's, kept the filename, and rewrote the check to
`terraform state list` -- the specification was edited to match the output
instead of the output being made to satisfy the specification. Week 14
copied week 13. After that every gate was self-consistent: the card matched
the plan, the file existed, the figure rendered, the sweep passed.

So this check deliberately does NOT trust the plan's own check column. The
plan is the thing that moved. It trusts the FILENAME, which nobody ever
edits to cover a shortfall, and asserts that the card contains evidence of
the command the name claims.

A name that promises nothing specific asserts nothing. This is not a
spell-checker for filenames; it fires only on names that make a claim about
a command that was run.
"""

import argparse
import glob
import os
import re
import sys

# filename keyword -> one of these must appear in the card for the claim to
# be met. Keep this list short and literal: every entry is a promise some
# figure name has actually made in this lab.
CLAIMS = {
    "terraform-apply":   ("terraform apply", "Apply complete!"),
    "terraform-destroy": ("terraform destroy", "Destroy complete!"),
    "terraform-plan":    ("terraform plan", "Plan:"),
    "price-check":       ("price_check.py",),
    "teardown":          ("cleanup.sh", "Destroy complete!", "what Azure says is left"),
    "validate":          ("validate.sh", "passed /"),
}


def claim_for(filename):
    """The promise a figure's name makes, longest keyword first."""
    stem = os.path.basename(filename).lower()
    for key in sorted(CLAIMS, key=len, reverse=True):
        if key in stem:
            return key, CLAIMS[key]
    return None, None


def unmet(cards):
    """[(card, keyword, wanted)] for every card that breaks its own promise.

    Pure, so --self-test can drive it without touching the filesystem:
    `cards` is {path: text}.
    """
    bad = []
    for path, text in sorted(cards.items()):
        key, wanted = claim_for(path)
        if not key:
            continue
        if not any(w.lower() in text.lower() for w in wanted):
            bad.append((path, key, wanted))
    return bad


def self_test():
    cards = {
        # the real defect, three times over
        "week-14/02-terraform-apply.card": "$ terraform state list\n  azurerm_resource_group.lab",
        # what it should have been
        "week-15/02-terraform-apply.card": "$ terraform apply\nApply complete! Resources: 20 added",
        # a name that promises nothing is not this check's business
        "week-09/02-terraform-layout.card": "week-09/\n|- main.tf",
        # the promise can be met by the command or by its result line
        "week-13/07-teardown.card": "$ bash cleanup.sh\n  what Azure says is left\n  0",
        "week-12/05-validate.card": "$ bash validate.sh\n  8 passed / 0 failed",
    }
    found = [c for c, _, _ in unmet(cards)]
    cases = [
        ("a state list under an apply name is caught",
         "week-14/02-terraform-apply.card" in found),
        ("a real apply passes",
         "week-15/02-terraform-apply.card" not in found),
        ("a name making no command claim is ignored",
         "week-09/02-terraform-layout.card" not in found),
        ("teardown is met by the cleanup script's own output",
         "week-13/07-teardown.card" not in found),
        ("validate is met by its pass line",
         "week-12/05-validate.card" not in found),
        ("exactly one failure in that set, not a blanket fail",
         len(found) == 1),
    ]
    bad = 0
    for label, ok in cases:
        print("  [%s] %s" % ("PASS" if ok else "DEAD", label))
        bad += not ok
    print()
    if bad:
        print("%d case(s) DO NOT WORK." % bad)
        return 1
    print("All %d figure-evidence cases pass." % len(cases))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("weeks", nargs="*", help="substring of a week folder")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cards = {}
    for path in glob.glob(os.path.join(root, "week-*", "docs", "blog", "figures", "*.card")):
        rel = os.path.relpath(path, root).replace("\\", "/")
        if args.weeks and not any(w in rel for w in args.weeks):
            continue
        cards[rel] = open(path, encoding="utf-8").read()

    debt_file = os.path.join(root, "scripts", "figure_evidence_debt.txt")
    debt = set()
    if os.path.isfile(debt_file):
        debt = {l.strip() for l in open(debt_file, encoding="utf-8")
                if l.strip() and not l.startswith("#")}

    bad = unmet(cards)
    carried = [b for b in bad if b[0] in debt]
    bad = [b for b in bad if b[0] not in debt]
    print("  %d figure card(s) checked against the promise in their name" % len(cards))
    for path, key, _ in carried:
        print("    [DEBT] %s -- published, promises '%s', shows something else"
              % (path, key))
    if carried:
        print("           see scripts/figure_evidence_debt.txt; fixing these")
        print("           renames a PNG two live posts embed by raw URL")
    if not bad:
        print("  every figure contains the evidence its name claims.")
        return 0
    print()
    for path, key, wanted in bad:
        print("    [FAIL] %s" % path)
        print("           name promises '%s'; card contains none of: %s"
              % (key, ", ".join(repr(w) for w in wanted)))
    print()
    print("  A figure named for a command has to show that command. Rename the")
    print("  slot for what it really shows, or capture the thing it promised --")
    print("  but do NOT edit the plan's check column to match the shortfall.")
    print("  That is exactly how this went unnoticed for three weeks.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
