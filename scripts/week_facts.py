#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Dump the facts a lab guide needs, read from the code rather than the post.

    python scripts/week_facts.py week-05-hub-network
    python scripts/week_facts.py --all

Written for the Master Standard's Prerequisites and Configuration sections.
Week 10 proved the point: the post claimed four resource providers where
deploy.sh registers five, and Terraform 1.9 where versions.tf requires 1.10.
Both were invisible from the prose. Anything this prints came out of a file.
"""
import argparse
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(p):
    try:
        with open(p, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


def tf_dir(week):
    for cand in ("terraform", "."):
        d = os.path.join(LAB, week, cand)
        if os.path.isdir(d) and any(f.endswith(".tf") for f in os.listdir(d)):
            return d
    # some weeks nest modules
    for base, _dirs, files in os.walk(os.path.join(LAB, week)):
        if any(f.endswith(".tf") for f in files) and ".terraform" not in base:
            return base
    return None


def facts(week):
    out = {"week": week}
    td = tf_dir(week)
    out["tf_dir"] = os.path.relpath(td, LAB) if td else None

    versions = read(os.path.join(td, "versions.tf")) if td else ""
    m = re.search(r'required_version\s*=\s*"([^"]+)"', versions)
    out["terraform_version"] = m.group(1) if m else None
    out["providers"] = re.findall(
        r'(\w+)\s*=\s*\{[^}]*?source\s*=\s*"([^"]+)"[^}]*?version\s*=\s*"([^"]+)"',
        versions, re.S)
    m = re.search(r'workspaces\s*\{[^}]*?name\s*=\s*"([^"]+)"', versions, re.S)
    out["hcp_workspace"] = m.group(1) if m else None

    # variables: name, whether it has a default, and its description
    vt = read(os.path.join(td, "variables.tf")) if td else ""
    vars_ = []
    for blk in re.finditer(r'variable\s+"([^"]+)"\s*\{(.*?)\n\}', vt, re.S):
        name, body = blk.group(1), blk.group(2)
        dm = re.search(r'\n\s*default\s*=\s*(.+)', body)
        desc = re.search(r'description\s*=\s*"([^"]*)"', body)
        vars_.append((name,
                      dm.group(1).strip() if dm else None,
                      (desc.group(1) if desc else "")[:70]))
    out["variables"] = vars_

    # resources actually declared, by type
    types = {}
    if td:
        for f in sorted(os.listdir(td)):
            if f.endswith(".tf"):
                for rt in re.findall(r'^resource\s+"([^"]+)"', read(os.path.join(td, f)), re.M):
                    types[rt] = types.get(rt, 0) + 1
    out["resources"] = sorted(types.items())
    out["resource_total"] = sum(types.values())

    # outputs
    out["outputs"] = re.findall(r'^output\s+"([^"]+)"',
                                read(os.path.join(td, "outputs.tf")) if td else "", re.M)

    # scripts: provider registrations and the validation checks
    sd = os.path.join(LAB, week, "scripts")
    dep = read(os.path.join(sd, "deploy.sh"))
    out["providers_registered"] = sorted(set(re.findall(r"Microsoft\.[A-Za-z]+", dep)))
    val = read(os.path.join(sd, "validate.sh"))
    # Two formats in the wild: weeks 09-10 wrap the label in box-drawing
    # rules, weeks 01-08 just number it. Matching only the first undercounted
    # every early week to zero, which read as "this week has no checks".
    out["checks"] = []
    for m in re.finditer(r'^\s*echo\s+"(?:──|--)?\s*(\d+)\.\s*(.+?)\s*(?:──|--)?"',
                         val, re.M):
        out["checks"].append("%s. %s" % (m.group(1), re.sub(r"\s+", " ", m.group(2))))
    if not out["checks"]:
        out["checks"] = ["%s" % re.sub(r"\s+", " ", c).strip()
                         for c in re.findall(r'^\s*echo\s+"(?:──|--)\s*(.+?)"', val, re.M)]
    out["assert_helper"] = bool(re.search(r"\bok\(\)|\bpass\(\)", val))
    cle = read(os.path.join(sd, "cleanup.sh"))
    out["cleanup_verifies"] = bool(re.search(r"still there|az group list|--query .length|count", cle))
    out["has_scripts"] = {n: os.path.exists(os.path.join(sd, n + ".sh"))
                          for n in ("deploy", "validate", "cleanup")}

    # figures that exist
    shots = os.path.join(LAB, week, "docs", "blog", "screenshots")
    out["screenshots"] = sorted(f for f in os.listdir(shots)) if os.path.isdir(shots) else []
    diag = os.path.join(LAB, week, "docs", "blog", "diagrams")
    out["diagrams"] = sorted(f for f in os.listdir(diag)) if os.path.isdir(diag) else []
    return out


def show(f):
    print()
    print("=" * 78)
    print(f["week"], " (tf in %s)" % f["tf_dir"])
    print("=" * 78)
    print("  terraform required_version : %s" % f["terraform_version"])
    for name, src, ver in f["providers"]:
        print("  provider %-10s %-28s %s" % (name, src, ver))
    print("  HCP workspace              : %s" % f["hcp_workspace"])
    print("  resources declared         : %d" % f["resource_total"])
    for rt, n in f["resources"]:
        print("      %-55s %d" % (rt, n))
    print("  providers registered by deploy.sh : %s"
          % (", ".join(f["providers_registered"]) or "none found"))
    print("  scripts: %s   cleanup verifies removal: %s"
          % (f["has_scripts"], f["cleanup_verifies"]))
    print("  validate.sh checks (%d):" % len(f["checks"]))
    for c in f["checks"]:
        print("      - %s" % c)
    print("  outputs: %s" % (", ".join(f["outputs"]) or "none"))
    print("  variables:")
    for name, dflt, desc in f["variables"]:
        req = "REQUIRED" if dflt is None else ("default " + str(dflt)[:30])
        print("      %-32s %-22s %s" % (name, req, desc))
    print("  screenshots: %s" % ", ".join(f["screenshots"]))
    print("  diagrams   : %s" % ", ".join(f["diagrams"]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("week", nargs="?")
    ap.add_argument("--all", action="store_true")
    a = ap.parse_args()
    weeks = ([d for d in sorted(os.listdir(LAB)) if re.match(r"^week-\d\d-", d)]
             if a.all else [a.week])
    for w in weeks:
        show(facts(w))


if __name__ == "__main__":
    main()
