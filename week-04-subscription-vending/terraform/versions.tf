terraform {
  required_version = ">= 1.10.0"

  required_providers {
    # azurerm only, and that is the finding rather than the default.
    #
    # `Azure/lz-vending/azurerm` is the obvious module for this week — it is
    # Microsoft's own, it is on 7.0.3, and its inputs map exactly onto what
    # vending means. It cannot be used here: its `role_definitions` and
    # `cached_data` submodules require `hashicorp/azurerm ~> 4.0`, this lab
    # standardised on `~> 5.2`, and the two constraints have no overlap. Not a
    # version to negotiate — `terraform init` refuses to resolve at all:
    #
    #   no available releases match the given constraints ~> 4.0, ~> 5.2
    #
    # 7.0.3 is the newest of its 37 releases and predates azurerm 5. Checked
    # 2026-09-11, with azurerm at 5.5.0.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.2"
    }
  }

  cloud {
    organization = "Katta"

    workspaces {
      name    = "azure-week-04-dev"
      project = "Azure Platform Lab"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  # Vending registers providers on the subscriptions it creates, deliberately
  # and by name. It must not register them on the subscription it happens to
  # authenticate through.
  resource_provider_registrations = "none"
}
