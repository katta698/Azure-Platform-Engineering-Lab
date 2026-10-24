# ═══════════════════════════════════════════════════════════════════════════
# Week 10 — the registry, and the identity that pulls from it
#
# Week 09 deployed a public Microsoft image anonymously and said, in as many
# words, that the managed identity was "the seam a private registry would
# authenticate through". This is that seam, closed.
#
# Nothing here holds a password. The registry's admin user stays off, the
# identity cannot hold a credential, and the grant between them is a role
# assignment rather than a secret.
# ═══════════════════════════════════════════════════════════════════════════

locals {
  common_tags = {
    week        = "10"
    env         = "dev"
    managed-by  = "terraform"
    cost-center = "platform-lab"
  }
}

resource "azurerm_resource_group" "workload" {
  name     = "rg-tracing-lab-dev-scus-001"
  location = var.location
  tags     = local.common_tags
}

# ── The registry ────────────────────────────────────────────────────────────
#
# Basic, measured at $0.1666/day from the retail price API. Basic and Standard
# differ in included storage and throughput, not in features that matter here;
# Premium adds geo-replication, private endpoints and content trust, none of
# which a two-day lab exercises honestly.
resource "azurerm_container_registry" "apps" {
  name                = "acrwk10devscus001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location
  sku                 = "Basic"

  # OFF, and this is the decision worth copying.
  #
  # The admin user is a single username and password that every caller shares.
  # It cannot be scoped, cannot be attributed to anyone, and turns up in CI
  # variables for years. Azure disables it by default; plenty of tutorials turn
  # it back on because it is the shortest path to a working docker login.
  admin_enabled = false

  tags = local.common_tags
}

# ── The identity that pulls ─────────────────────────────────────────────────
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-wk10-app-dev-scus-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location
  tags                = local.common_tags
}

# AcrPull, and nothing else.
#
# Not Contributor on the resource group, not AcrPush. The apps only ever read
# images; the push happens from `az acr build`, authenticated as the human or
# the CI identity running it. Scoped to the REGISTRY, not the subscription.
resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.apps.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}
