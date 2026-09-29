# ═══════════════════════════════════════════════════════════════════════════
# Week 07 — a CI identity with no secret attached to it
#
# Four resources. The interesting one is the federated credential, which is
# the entire mechanism: it tells Entra "a token from GitHub, for THIS repo, on
# THIS branch, may act as this identity". No password is created, so none can
# be stolen, rotated, or forgotten in a repo.
# ═══════════════════════════════════════════════════════════════════════════

locals {
  common_tags = {
    week        = "07"
    env         = "dev"
    managed-by  = "terraform"
    cost-center = "platform-lab"
  }
}

resource "azurerm_resource_group" "identity" {
  name     = "rg-wk07-identity-dev-scus-001"
  location = var.location
  tags     = local.common_tags
}

# USER-assigned, and that is forced rather than chosen.
#
# Workload identity federation does not work with a system-assigned identity.
# A system-assigned identity belongs to an Azure resource and dies with it;
# there is no Azure resource here to own it, because the workload runs on
# GitHub's infrastructure, not Azure's.
resource "azurerm_user_assigned_identity" "ci" {
  name                = "id-wk07-github-ci-dev-scus-001"
  resource_group_name = azurerm_resource_group.identity.name
  location            = azurerm_resource_group.identity.location
  tags                = local.common_tags
}

# The trust itself.
#
# `subject` is the security boundary and it is exact-match, not a prefix. A
# token from a different repo, or from a branch other than main, does not
# match and is refused - which is why a fork raising a pull request cannot
# obtain this identity.
#
# The prefix is READ FROM GITHUB rather than built from the org and repo name,
# because GitHub now defaults to immutable subject claims: the owner and the
# repository each carry their numeric ID, as in
# repo:owner@63027619/repo@1342954118. Renaming or transferring the repo
# therefore does NOT carry the trust with it, which is the point of the
# feature - and it means the documented repo:owner/repo form is no longer what
# a runner actually presents. Building the string by hand produces a
# credential that looks correct and matches nothing.
resource "azurerm_federated_identity_credential" "main_branch" {
  name = "github-main"

  # azurerm 5.x takes a single user_assigned_identity_id. In 4.x this was
  # resource_group_name plus parent_id, so every published example predating
  # the 5.0 release fails on all three arguments at once.
  user_assigned_identity_id = azurerm_user_assigned_identity.ci.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = "https://token.actions.githubusercontent.com"
  subject  = "${var.github_subject_prefix}:ref:refs/heads/main"
}

# Reader, not Contributor.
#
# This week's workload only reads - it proves it authenticated and can see the
# subscription. Granting Contributor "so it works later" is how a CI identity
# quietly becomes the most powerful principal in the tenant.
resource "azurerm_role_assignment" "ci_reader" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ci.principal_id
}
