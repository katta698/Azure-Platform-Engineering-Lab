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
      name    = "azure-week-01-dev"
      project = "Azure Platform Lab"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  # Policy definitions and assignments at management group scope touch no
  # resource providers in this subscription. Registration is a deliberate act by
  # the week that needs it, not a side effect of every plan.
  resource_provider_registrations = "none"
}
