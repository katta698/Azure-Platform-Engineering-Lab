# ═══════════════════════════════════════════════════════════════════════════
# Week 09 — a workload that costs nothing until someone asks it for something
#
# Weeks 01 to 08 built the place things run and the place they report to.
# Nothing was actually running. This week deploys a workload that serves real
# HTTP traffic, and the design question is not how to make it fast - it is
# what you are willing to pay while nobody is using it.
#
# The answer here is nothing, and the price of that answer is that the first
# request after an idle period waits for a container to start. That trade is
# the week's whole subject, and it is measured rather than asserted.
# ═══════════════════════════════════════════════════════════════════════════

locals {
  common_tags = {
    week        = "09"
    env         = "dev"
    managed-by  = "terraform"
    cost-center = "platform-lab"
  }
}

# Tags do not inherit in Azure - a resource group's tags are not applied to
# what is inside it. Week 02 settled the lab's answer to this with a modify
# policy; every resource here also carries them directly, so the week stands
# up with or without that assignment in place.
resource "azurerm_resource_group" "workload" {
  name     = "rg-containerapps-lab-dev-scus-001"
  location = var.location
  tags     = local.common_tags
}

# ── The identity ────────────────────────────────────────────────────────────
#
# User-assigned, for the reason week 07 established: an identity that must
# outlive the resource using it is user-assigned, and a revision is a
# disposable thing. Every deploy of this app creates a new revision; a
# system-assigned identity would be a new principal each time, and every role
# assignment granted to it would be stale on arrival.
#
# It is honest to say what this identity does NOT do this week: the image
# comes from MCR anonymously, so nothing authenticates to pull it, and the
# quickstart container makes no Azure calls. It is here because it is the
# seam. Moving to a private registry or giving the app a queue to read is a
# change to the blocks that reference this identity, never a change that
# introduces a password.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-wk09-app-dev-scus-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location
  tags                = local.common_tags
}

# ── The environment ─────────────────────────────────────────────────────────
#
# The environment is the boundary: apps inside one share a network and a log
# destination, and can reach each other by name. It is the unit you would
# create per environment-per-region, not per app.
#
# It costs nothing by itself. On the Consumption plan the meters are vCPU-
# seconds and GiB-seconds of RUNNING replicas, so an environment whose apps
# are all at zero bills nothing while still existing - which is what makes
# scale-to-zero worth having rather than a reason to delete the environment.
resource "azurerm_container_app_environment" "workload" {
  name                = "cae-wk09-dev-scus-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location

  # THE DESIGN DECISION OF THE WEEK, and it was forced by week 08.
  #
  # The default destination, "log-analytics", wires the environment to a
  # workspace using that workspace's SHARED KEY. Week 08 built its workspace
  # with local authentication disabled, so there is no key to give - the
  # default path cannot work here at all, and it fails pointing at logging
  # rather than at authentication.
  #
  # "azure-monitor" sends through a diagnostic setting instead, which
  # authenticates as Azure Resource Manager rather than with a key. It is also
  # the only destination Microsoft supports when the workspace is reached over
  # Private Link. The cost is that the portal's Logs blade on the app is
  # disabled: queries run against the workspace instead. See logging.tf.
  logs_destination = "azure-monitor"

  tags = local.common_tags
}

# ── The app ─────────────────────────────────────────────────────────────────
resource "azurerm_container_app" "hello" {
  name                         = "ca-hello-dev-scus-001"
  resource_group_name          = azurerm_resource_group.workload.name
  container_app_environment_id = azurerm_container_app_environment.workload.id

  # Single, not Multiple. Multiple revision mode keeps old revisions alive to
  # split traffic across, which is how you do a canary - and also how you keep
  # paying for the revision you thought you replaced. A week proving that idle
  # costs nothing should not leave a previous revision running.
  revision_mode = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  ingress {
    # Reachable from the internet, because the week's claim is that a real
    # request from outside Azure wakes it up. An internal-only app would be
    # the right default for anything a front end sits in front of.
    external_enabled = true
    target_port      = 80

    # HTTPS only. With this false, the ingress still terminates TLS and serves
    # the app over HTTPS, but it ALSO answers port 80 in the clear - and a
    # client that gets a 200 over HTTP has no reason to ever upgrade.
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # The smallest Consumption combination Azure accepts. CPU and memory are
    # not independent here: the allowed pairs are fixed, and 0.25 vCPU goes
    # with 0.5Gi. Asking for 0.25 and 1Gi is refused.
    container {
      name   = "quickstart"
      image  = var.container_image
      cpu    = 0.25
      memory = "0.5Gi"
    }

    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    # How long the app keeps a replica after the last request. This is the
    # knob that decides how often a user meets a cold start, and it is set
    # explicitly because the default is easy to be surprised by: leaving it
    # out means the replica lingers for five minutes, and a test that checks
    # for zero replicas a minute after the last request concludes that
    # scale-to-zero does not work.
    cooldown_period_in_seconds = 300

    # Scale on concurrent requests, not CPU. A web app's queue depth is what
    # a user experiences; CPU is a lagging proxy for it, and an app waiting on
    # a database is busy while its CPU is idle.
    http_scale_rule {
      name                = "http-concurrency"
      concurrent_requests = 10
    }
  }

  tags = local.common_tags
}
