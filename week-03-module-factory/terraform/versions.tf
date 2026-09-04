terraform {
  required_version = ">= 1.10.0"

  required_providers {
    # The resource group and the workspace. Everything inside the storage
    # module is azapi — this root ends up running four providers to deploy two
    # storage accounts and a workspace, which is not a mistake and is worth
    # looking at in the state file.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.2"
    }

    # Required by the module this week publishes, because it is required by the
    # AVM module underneath it. A root module cannot opt out of a provider its
    # modules use: it can only decline to configure it and accept the defaults.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.11"
    }
    modtm = {
      source  = "Azure/modtm"
      version = "~> 0.3"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0, < 4.0.0"
    }
  }

  cloud {
    organization = "Katta"

    workspaces {
      name    = "azure-week-03-dev"
      project = "Azure Platform Lab"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  resource_provider_registrations = "none"
}

# azapi takes the same two IDs and needs them for the same reason. It is easy to
# miss because nothing in this root uses azapi directly — the requirement
# arrives three levels down, through storage-baseline into the AVM module, and
# surfaces as an authentication error against a resource this file never
# mentions.
provider "azapi" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}
