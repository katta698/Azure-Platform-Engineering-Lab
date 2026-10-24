terraform {
  required_version = ">= 1.10.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.2"
    }
    # The managed OpenTelemetry agent is configured through
    # openTelemetryConfiguration on the managed environment, and azurerm does
    # not expose that property at all. azapi talks to ARM directly, which is
    # the documented way to configure the agent from Terraform.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }

  cloud {
    organization = "Katta"

    workspaces {
      name    = "azure-week-10-dev"
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

# Week 08's workspace lives in sub-management. Reading it needs a provider
# pinned to that subscription - the same arrangement week 09 used.
provider "azurerm" {
  alias = "management"

  features {}
  subscription_id = var.management_subscription_id
  tenant_id       = var.tenant_id
}
