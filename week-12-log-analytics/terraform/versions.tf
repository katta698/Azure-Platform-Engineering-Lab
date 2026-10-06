terraform {
  required_version = ">= 1.10.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.2"
    }
    # For the custom tables. azurerm can set a plan on a table that exists; it
    # has nowhere to put a schema, so it cannot create one.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }

  cloud {
    organization = "Katta"

    workspaces {
      name    = "azure-week-12-dev"
      project = "Azure Platform Lab"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

provider "azapi" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}
