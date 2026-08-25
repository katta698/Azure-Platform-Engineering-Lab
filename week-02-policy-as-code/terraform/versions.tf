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
      name    = "azure-week-02-dev"
      project = "Azure Platform Lab"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  # Registration is done by deploy.sh, deliberately not here. It is
  # subscription-wide state that no single week owns — two weeks both declaring
  # Microsoft.Insights would fight over it, and one week's destroy would
  # unregister a provider the other still needs.
  resource_provider_registrations = "none"
}
