#!/usr/bin/env bash
# Export the identifiers capture_azure.py masks. SOURCE this, do not run it:
#
#   source scripts/screenshots/mask-env.sh
#
# Masking is an ALLOWLIST. capture_azure.py redacts the values you hand it and
# nothing else, and it prints a cheerful "Verified: masked ..." line naming only
# what it did mask — so a page carrying an identifier you did not list is
# reported as a success. Measured 2026-09-03: a management group capture taken
# with only the week's own subscription in AZ_SUBSCRIPTION_IDS rendered the
# legacy sandbox subscription's GUID in clear text, and the run reported
# "Verified: masked subscription ID, tenant ID (3 replacements)".
#
# So the list is built from EVERY subscription in the tenant, not the week's.
# A portal blade shows neighbours: the management group tree lists all four, a
# resource move dialog offers all four, and Cost Management shows whatever it
# likes. Guessing which ones a blade will render is the failure above.
#
# No identifier is written into this file. `az account list` reads the local
# profile and needs no access token, so this keeps working even when the CLI's
# token cache cannot be decrypted.

export MSYS_NO_PATHCONV=1

AZ_TENANT_ID=$(az account list --all --query "[0].tenantId" -o tsv 2>/dev/null | tr -d '\r')
AZ_SUBSCRIPTION_IDS=$(az account list --all --query "[].id" -o tsv 2>/dev/null | tr -d '\r' | paste -sd, -)
export AZ_TENANT_ID AZ_SUBSCRIPTION_IDS

if [[ -z "$AZ_TENANT_ID" || -z "$AZ_SUBSCRIPTION_IDS" ]]; then
  echo "mask-env: could not read the Azure profile — capture would run UNMASKED." >&2
  echo "  Run 'az login' first. Do not capture until this prints a count." >&2
  return 1 2>/dev/null || exit 1
fi

echo "mask-env: tenant + $(tr ',' '\n' <<< "$AZ_SUBSCRIPTION_IDS" | grep -c .) subscriptions will be masked"

# Not covered here, and worth knowing before you capture:
#   AZ_OBJECT_IDS   service principal / managed identity object IDs. These need
#                   a Graph token, so they cannot be derived offline. Set them
#                   by hand for any blade showing an identity — the week 02
#                   remediation identity blades do.
#   AZ_BILLING_IDS  MCA billing account / invoice section. Only Cost Management
#                   and subscription creation blades render these.
