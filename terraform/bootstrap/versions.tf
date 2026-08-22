terraform {
  required_version = ">= 1.10.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.2"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.9"
    }
  }

  cloud {
    organization = "Katta"

    workspaces {
      name    = "azure-bootstrap"
      project = "Azure Platform Lab"
    }
  }
}

# azurerm 5.x requires subscription_id on the provider block — it is no longer
# inferred from the CLI context. Bootstrap operates mostly at management-group
# and tenant scope, but the provider still needs a subscription to anchor to,
# and the only one that exists at bootstrap time is the pre-existing sandbox.
#
# resource_provider_registrations = "none" because bootstrap creates no
# resources inside that subscription and should not mutate its provider surface.
# Registration is done deliberately, per subscription, by the week that needs it.
provider "azurerm" {
  features {}

  subscription_id                 = var.sandbox_subscription_id
  tenant_id                       = var.tenant_id
  resource_provider_registrations = "none"
}

provider "azuread" {
  tenant_id = var.tenant_id
}
