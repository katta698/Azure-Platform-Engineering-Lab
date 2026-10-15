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
      name    = "azure-week-09-dev"
      project = "Azure Platform Lab"
    }
  }
}

# The workload lives in sub-lab-dev, under mg-lz-dev. It is an application,
# not platform machinery.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

# Week 08's Log Analytics workspace is in sub-management, a DIFFERENT
# subscription. Reading it needs a second provider instance, because a
# provider is pinned to one subscription. The workspace ID could have been
# pasted in as a variable; a data source means a wrong or deleted workspace
# fails at plan time instead of producing a diagnostic setting that points at
# nothing.
provider "azurerm" {
  alias = "management"

  features {}
  subscription_id = var.management_subscription_id
  tenant_id       = var.tenant_id
}
