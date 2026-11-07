#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Every meter a week can be charged on, enumerated BEFORE it is deployed.

    python scripts/price_check.py week-12-detections-as-code
    python scripts/price_check.py --services Sentinel "Azure Monitor" --region southcentralus

Why this exists
---------------
Week 11 deployed Azure Managed Grafana. The week's cost note said the metrics
pipeline cost about a cent and the compute around it about $0.18/hour, and it
never mentioned that Grafana bills a flat $6.00 per user per month. That meter
is in the retail price API. I read it. The line said:

    6.00000  1/Month  Standard User

and I dropped it because I was not sure it applied to a single-user instance.
It applied. Jay found it on his own bill, as a $6 line on a $7.19 invoice --
most of the cost of the week, in the one component the post said was free.

What he said, and it is the requirement for this tool:

    "Why didn't you say, how would I trust you in future when you recommend
    something and say, hey, there's no billing associated to it, and then
    realize that there's a charge for it?"

The failure was not that the meter was hidden. It was that an UNCERTAIN meter
could be dropped silently, by one person, with no trace. So this tool does not
try to be smarter about which meters apply. It makes dropping one impossible to
do quietly:

  * it prints EVERY meter for the services a week touches, in its region
  * it separates FLAT RECURRING meters -- priced per Month, per Day, or per
    Hour against a unit that is not consumption -- from usage meters, because
    the flat ones are the ones that bill whether or not you use the thing, and
    the Grafana meter was one
  * a flat meter must be ACKNOWLEDGED in the week's meters.json, with a
    reason, or this exits non-zero. Acknowledgement is by meter FAMILY, so
    one decision ("we are not buying a commitment tier") is written once
    rather than 23 times -- an exact meter name also works and wins

meters.json sits at the week root, not under docs/, so it is committed. The
list of charges a week consciously accepted belongs next to the code, in
public, not in a local note nobody else reads.

It reads the public Azure Retail Prices API, which needs no credentials, so it
runs before any subscription exists and before anything is deployed.

What it is NOT
--------------
It is not a cost estimate. It makes no claim about how much a week will cost --
that number comes from the bill, after teardown, per the lab's standing rule
that cost is read from the invoice and never from a rate card. This answers a
different and narrower question: WHAT CAN THIS WEEK BE CHARGED FOR AT ALL.

meters.json shape
-----------------
    {
      "region": "southcentralus",
      "services": ["Sentinel", "Azure Monitor"],
      "acknowledged": {
        "Pay-as-you-go Analysis": "Sentinel analysis, $5.16/GB. The week
            ingests only AzureActivity, which is a free data type, and runs
            inside the 31-day 10GB/day trial.",
      }
    }
"""

import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request

API = "https://prices.azure.com/api/retail/prices"

# A unit of measure that bills on the passage of time rather than on
# consumption. "1/Month", "1/Day", "1/Hour" against a seat, a node or an
# instance is the Grafana shape: it accrues while the thing merely exists.
FLAT_UNITS = ("1/Month", "1/Day", "1/Hour", "1 Month", "1 Day", "1 Hour")


def fetch(service, region):
    """Every meter for one service in one region, following paging."""
    flt = "serviceName eq '%s' and armRegionName eq '%s'" % (service, region)
    url = API + "?" + urllib.parse.urlencode({"$filter": flt})
    out = []
    seen = 0
    while url:
        with urllib.request.urlopen(url, timeout=90) as r:
            page = json.load(r)
        out.extend(page.get("Items", []))
        url = page.get("NextPageLink")
        seen += 1
        if seen > 40:                      # a service with 4000 meters is a
            break                          # bug in the filter, not a price list
    return out


def is_flat(item):
    return any(item.get("unitOfMeasure", "").startswith(u) for u in FLAT_UNITS)


# Meters come in families that are ONE decision, not many. Azure prices every
# commitment tier as its own meter, so "we are not buying a commitment tier"
# arrives here as 23 separate names. A gate that demands 23 written
# justifications for one decision is a gate somebody deletes in a week -- the
# same failure the blog repo's preflight.py keeps recording as "a gate that is
# red on arrival gets uninstalled on arrival". So acknowledge the FAMILY.
#
# An exact meter name still works and still wins, for the case where one tier
# of a family is acceptable and the rest are not.
_FAMILY_RULES = (
    (re.compile(r"^\d+(\.\d+)? ?GB ", re.I), ""),            # "50000 GB X" -> "X"
    (re.compile(r" at \d+ Minutes? Frequency$", re.I), ""),   # "...at 5 Minute Frequency"
    (re.compile(r"\s+"), " "),
)


def family(meter_name):
    out = meter_name
    for pat, rep in _FAMILY_RULES:
        out = pat.sub(rep, out)
    return out.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("week", nargs="?",
                    help="week folder containing meters.json")
    ap.add_argument("--services", nargs="+",
                    help="service names, instead of a week folder")
    ap.add_argument("--region", default="southcentralus")
    ap.add_argument("--all", action="store_true",
                    help="also list zero-priced and usage meters in full")
    args = ap.parse_args()

    ack = {}
    if args.week:
        path = os.path.join(args.week, "meters.json")
        if not os.path.isfile(path):
            print("NO meters.json in %s" % args.week)
            print()
            print("  A week that can be billed has to say what it can be")
            print("  billed for, before it is deployed. Create it:")
            print()
            print('      {"region": "%s", "services": ["..."],' % args.region)
            print('       "acknowledged": {}}')
            return 2
        spec = json.load(open(path, encoding="utf-8"))
        services = spec["services"]
        region = spec.get("region", args.region)
        ack = spec.get("acknowledged", {})
    elif args.services:
        services, region = args.services, args.region
    else:
        ap.error("give a week folder or --services")

    print("Meters that can bill, region %s" % region)
    print("=" * 66)

    flat_all, usage_all, failed = [], [], []
    for svc in services:
        try:
            items = fetch(svc, region)
        except Exception as exc:                        # noqa: BLE001
            failed.append((svc, repr(exc)))
            continue
        if not items:
            failed.append((svc, "no meters returned -- check the service name"))
            continue
        for i in items:
            (flat_all if is_flat(i) else usage_all).append((svc, i))

    if failed:
        print()
        print("  COULD NOT PRICE -- this is not a clean run:")
        for svc, why in failed:
            print("    %-28s %s" % (svc, why[:70]))

    # ---- the dangerous ones -------------------------------------------
    billed_flat = [(s, i) for s, i in flat_all if i.get("retailPrice", 0) > 0]
    print()
    print("  FLAT RECURRING METERS -- bill while the thing exists (%d)"
          % len(billed_flat))
    print("  " + "-" * 62)
    if not billed_flat:
        print("    none")
    # Group into families so one decision is acknowledged once. Within a
    # family show the DEAREST meter, because that is the number that matters
    # if the family ever applies.
    fams = {}
    for svc, i in billed_flat:
        key = (svc, family(i["meterName"]))
        if key not in fams or i["retailPrice"] > fams[key][0]["retailPrice"]:
            fams[key] = (i, 0)
        fams[key] = (fams[key][0], fams[key][1] + 1)

    unacked = []
    for (svc, fam), (i, n) in sorted(fams.items(), key=lambda x: -x[1][0]["retailPrice"]):
        covered = fam in ack or i["meterName"] in ack
        if not covered:
            unacked.append((svc, fam, i, n))
        span = ("  [%d tiers]" % n) if n > 1 else ""
        print("    %s%10.5f %-10s %-36s %s%s"
              % ("ack " if covered else "    ", i["retailPrice"],
                 i["unitOfMeasure"], fam[:36], svc, span))

    # ---- usage meters --------------------------------------------------
    billed_usage = [(s, i) for s, i in usage_all if i.get("retailPrice", 0) > 0]
    print()
    print("  USAGE METERS -- bill on consumption (%d)" % len(billed_usage))
    print("  " + "-" * 62)
    shown = billed_usage if args.all else billed_usage[:14]
    for svc, i in sorted(shown, key=lambda x: -x[1]["retailPrice"]):
        print("        %10.5f %-10s %-38s %s"
              % (i["retailPrice"], i["unitOfMeasure"], i["meterName"][:38], svc))
    if not args.all and len(billed_usage) > len(shown):
        print("        ... %d more, use --all" % (len(billed_usage) - len(shown)))

    free = [i for s, i in flat_all + usage_all if i.get("retailPrice", 0) == 0]
    print()
    print("  %d meter(s) priced at zero (free tiers and benefits)" % len(free))

    # ---- the gate ------------------------------------------------------
    print()
    if failed:
        print("  FAILED: a service could not be priced, so this run proves")
        print("  nothing about it. Fix the service name and run again.")
        return 2
    if unacked:
        print("  %d FLAT METER(S) NOT ACKNOWLEDGED." % len(unacked))
        print()
        print("  Each of these bills whether or not the week uses the")
        print("  feature. Week 11 shipped with exactly one of these")
        print("  unexamined and it was 83% of the invoice.")
        print()
        print("  Add each to \"acknowledged\" in meters.json with a reason it")
        print("  is acceptable, or change the design so it cannot apply:")
        print()
        for svc, fam, i, n in unacked:
            print('      "%s": "",   # %s, dearest %.5f %s%s'
                  % (fam, svc, i["retailPrice"], i["unitOfMeasure"],
                     (", %d tiers" % n) if n > 1 else ""))
        print()
        print("  An empty reason is not an acknowledgement.")
        return 1

    print("  OK -- every flat recurring meter is acknowledged in meters.json.")
    print()
    print("  This says what CAN be billed. It is not an estimate, and it is")
    print("  not the cost of the week. Read that from the invoice after")
    print("  teardown.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
