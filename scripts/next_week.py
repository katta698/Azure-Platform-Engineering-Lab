#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The week number is derived, never chosen.

    python scripts/next_week.py            # what number the next week gets
    python scripts/next_week.py --check    # fail if anything is out of sequence

WHY THIS EXISTS (2026-10-10)
----------------------------
The lab published weeks 01 to 07 and then published **week 12**. Log Analytics
sat at slot 12 in ROADMAP.md, the identity weeks 08 to 11 were blocked behind an
Entra licence, so Log Analytics was pulled forward -- and kept its roadmap
number. The blog index then read "Azure Weekly Lab (8)" with a hole in the
middle, and Jay could not tell whether the post belonged to this lab at all.

Renaming it afterwards cost a folder rename, an HCP workspace rename, a changed
post slug, a redirect for the old URL, and twenty minutes of a live post with
every image 404ing because the lab repo was pushed before the blog.

None of that was a hard problem. It was a number nobody checked.

THE RULE
--------
**The next week number is the highest week that exists, plus one.** It comes
from what has been built, not from ROADMAP.md. The roadmap is an ordered list
of TOPICS; when a topic cannot be built, the ones behind it move up. A topic
keeps its place in the queue, never its number.

Three things must agree, and --check enforces it:

    the folder           week-NN-<name>/
    the HCP workspace    azure-week-NN-dev   (in terraform/versions.tf)
    the published post   slug week-NN-<name> (in the blog repo)
"""

import os
import re
import sys
import glob

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BLOG = os.path.join(os.path.dirname(REPO), "..", "katta698.github.io")

WEEK_DIR = re.compile(r"^week-(\d{2})-[a-z0-9-]+$")
WORKSPACE = re.compile(r'name\s*=\s*"azure-week-(\d{2})-dev"')


def week_folders():
    out = []
    for p in sorted(glob.glob(os.path.join(REPO, "week-*"))):
        m = WEEK_DIR.match(os.path.basename(p))
        if m:
            out.append((int(m.group(1)), os.path.basename(p)))
    return out


def workspace_number(folder):
    """The week number the HCP workspace claims, from versions.tf."""
    vf = os.path.join(REPO, folder, "terraform", "versions.tf")
    if not os.path.isfile(vf):
        return None
    m = WORKSPACE.search(open(vf, encoding="utf-8").read())
    return int(m.group(1)) if m else None


def published_weeks():
    """Azure Weekly Lab posts in the blog repo, by slug number."""
    posts = os.path.join(BLOG, "posts")
    if not os.path.isdir(posts):
        return None  # blog not checked out here; skip that half of the check
    found = []
    for f in glob.glob(os.path.join(posts, "week-*.html")):
        head = open(f, encoding="utf-8").read(2000)
        if "Azure Weekly Lab" not in head:
            continue
        m = re.search(r"^slug: week-(\d{1,2})-", head, re.M)
        if m:
            found.append((int(m.group(1)), os.path.basename(f)))
    return sorted(found)


README_ROW = re.compile(r"^\|\s*(\d{2})\s*\|[^|]*\|\s*([A-Za-z]+)\s*\|")


def readme_status():
    """What README.md's week tracker claims about each week.

    WHY THIS IS CHECKED (2026-10-24)
    --------------------------------
    Jay, looking at the repo on his phone: "Why are we not updating readme?"
    Week 10 was built, validated, torn down and PUBLISHED, and the tracker on
    the repo's landing page still said Planned - the first thing any visitor
    reads, contradicting the live post.

    It had happened once already: on 2026-10-15 the tracker still showed weeks
    03-09 as Planned, months after they shipped, alongside the pre-renumber
    plan. Fixing it by hand twice is not a fix. A published week whose tracker
    row says anything but Complete now fails the sweep.
    """
    f = os.path.join(REPO, "README.md")
    if not os.path.isfile(f):
        return None
    out = {}
    for line in open(f, encoding="utf-8").read().split("\n"):
        m = README_ROW.match(line.strip())
        if m:
            out[int(m.group(1))] = m.group(2)
    return out


def main():
    check = "--check" in sys.argv
    folders = week_folders()
    problems = []

    if not folders:
        print("no week folders yet -- the next week is 01")
        return 0

    numbers = [n for n, _ in folders]
    nxt = max(numbers) + 1

    # 1. no duplicates, no gaps among what has been BUILT
    for i, n in enumerate(sorted(numbers), start=1):
        if n != i:
            problems.append(
                "week numbers are not sequential: built weeks are %s, which "
                "breaks at %02d" % (", ".join("%02d" % x for x in sorted(numbers)), n)
            )
            break

    # 2. each folder's HCP workspace must carry the folder's own number
    for n, folder in folders:
        w = workspace_number(folder)
        if w is None:
            continue
        if w != n:
            problems.append(
                "%s declares HCP workspace azure-week-%02d-dev -- the numbers "
                "must match" % (folder, w)
            )

    # 3. each published post must carry the same number as its folder
    pub = published_weeks()
    if pub is not None:
        pubnums = [n for n, _ in pub]
        for n, name in pub:
            if n not in numbers:
                problems.append(
                    "published post %s is week %02d, but no week-%02d-* folder "
                    "exists in the lab" % (name, n, n)
                )
        for i, n in enumerate(sorted(pubnums), start=1):
            if n != i:
                problems.append(
                    "published weeks are not sequential: %s"
                    % ", ".join("%02d" % x for x in sorted(pubnums))
                )
                break

    # 4. a published week must not still read "Planned" on the landing page
    status = readme_status()
    if status is not None and pub is not None:
        for n, name in pub:
            st = status.get(n)
            if st is None:
                problems.append(
                    "week %02d is published but has no row in README.md's week tracker" % n)
            elif st.lower() != "complete":
                problems.append(
                    "week %02d is PUBLISHED but README.md's tracker still says \"%s\" - "
                    "that table is the first thing anyone reads" % (n, st))

    print("  built weeks     : %s" % ", ".join("%02d" % n for n, _ in folders))
    if pub is not None:
        print("  published weeks : %s" % (", ".join("%02d" % n for n, _ in pub) or "none"))
    print("  NEXT WEEK IS    : %02d" % nxt)

    if problems:
        print("")
        for p in problems:
            print("  PROBLEM: %s" % p)
        print("")
        print("  The next week number is the highest that exists, plus one.")
        print("  It is never taken from ROADMAP.md -- that is a list of topics")
        print("  in dependency order, and a topic that cannot be built yet moves")
        print("  the ones behind it UP.")
        return 1

    if check:
        print("  in sequence -- folder, HCP workspace and published post all agree.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
