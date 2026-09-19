terraform {
  required_version = ">= 1.10.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.2"
    }
  }

  cloud {
    organization = "Katta"

    workspaces {
      name    = "azure-week-05-dev"
      project = "Azure Platform Lab"
    }
  }
}

# ── Two subscriptions, two providers ────────────────────────────────────────
#
# The hub lives in sub-connectivity and the spoke in sub-lab-dev, because that
# is what the bootstrap's hierarchy is for: a platform subscription that outlives
# any one workload, and a landing zone that does not.
#
# It also means this week is the first to prove the split earns its keep. A hub
# in the same subscription as its spoke demonstrates peering; a hub in a
# different subscription demonstrates peering *and* that the two halves can be
# owned by different teams with different lifecycles — which is the actual
# argument for the separation.
provider "azurerm" {
  features {}

  subscription_id = var.connectivity_subscription_id
  tenant_id       = var.tenant_id

  resource_provider_registrations = "none"
}

provider "azurerm" {
  alias = "spoke"

  features {}

  subscription_id = var.spoke_subscription_id
  tenant_id       = var.tenant_id

  resource_provider_registrations = "none"
}
