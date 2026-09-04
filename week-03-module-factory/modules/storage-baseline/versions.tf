terraform {
  required_version = ">= 1.10.0"

  # These are the constraints of the module this one wraps, restated rather
  # than inherited. A module does not have to declare providers it never
  # configures, and this one declares no resources of its own — but leaving the
  # block out moves the failure. A root module on azapi 1.x would then fail
  # deep inside the AVM module's own terraform.tf, naming a module the consumer
  # did not write and does not have open.
  #
  # There is no azurerm here at all. The registry calls this module
  # `.../storage-baseline/azurerm` because the registry's third address segment
  # is a namespace label rather than a dependency, and AVM publishes under the
  # same label for the same reason. What actually creates the storage account
  # is azapi.
  required_providers {
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
}
