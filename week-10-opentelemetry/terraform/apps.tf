# ═══════════════════════════════════════════════════════════════════════════
# Week 10 — two services, so the trace has somewhere to go
#
# One service produces a trace. TWO services produce a DISTRIBUTED trace, and
# that is a different claim: it proves trace context survived a network hop
# between two processes that share nothing but a header.
#
# frontend  external ingress, called by a human, does almost nothing itself
# backend   internal only, deliberately slow, where the time should show up
# ═══════════════════════════════════════════════════════════════════════════

locals {
  registry_server = azurerm_container_registry.apps.login_server

  # Every app gets these. The agent injects OTEL_EXPORTER_OTLP_ENDPOINT and
  # OTEL_EXPORTER_OTLP_PROTOCOL itself, so they are deliberately NOT set here -
  # setting them would override the agent's own values and send telemetry into
  # a void that looks exactly like a working configuration.
  otel_env = {
    OTEL_TRACES_SAMPLER     = "parentbased_traceidratio"
    OTEL_TRACES_SAMPLER_ARG = tostring(var.trace_sampler_arg)
  }
}

# ── The backend ─────────────────────────────────────────────────────────────
resource "azurerm_container_app" "backend" {
  name                         = "backend"
  resource_group_name          = azurerm_resource_group.workload.name
  container_app_environment_id = azurerm_container_app_environment.workload.id
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  # How the image is pulled, and the whole reason the identity exists. No
  # username, no password, no admin user - the registry trusts the identity.
  registry {
    server   = local.registry_server
    identity = azurerm_user_assigned_identity.app.id
  }

  ingress {
    # INTERNAL. Nothing outside the environment can reach the backend, which
    # is what makes the frontend's call a genuine service-to-service hop
    # rather than a second public endpoint.
    external_enabled           = false
    target_port                = 8080
    allow_insecure_connections = true # inside the environment only

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1 # kept warm: a cold start here would be measured as backend latency
    max_replicas = 2

    container {
      name   = "backend"
      image  = "${local.registry_server}/wk10/backend:${var.image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "OTEL_SERVICE_NAME"
        value = "backend"
      }

      env {
        name  = "WORK_MS"
        value = tostring(var.backend_work_ms)
      }

      dynamic "env" {
        for_each = local.otel_env
        content {
          name  = env.key
          value = env.value
        }
      }

      liveness_probe {
        transport = "HTTP"
        port      = 8080
        path      = "/health"
      }
    }
  }

  tags = local.common_tags

  depends_on = [azurerm_role_assignment.acr_pull]
}

# ── The frontend ────────────────────────────────────────────────────────────
resource "azurerm_container_app" "frontend" {
  name                         = "frontend"
  resource_group_name          = azurerm_resource_group.workload.name
  container_app_environment_id = azurerm_container_app_environment.workload.id
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = local.registry_server
    identity = azurerm_user_assigned_identity.app.id
  }

  ingress {
    external_enabled           = true
    target_port                = 8080
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 3

    container {
      name   = "frontend"
      image  = "${local.registry_server}/wk10/frontend:${var.image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "OTEL_SERVICE_NAME"
        value = "frontend"
      }

      # Apps inside an environment reach each other by name over the
      # environment's own network. This never leaves Azure.
      env {
        name  = "BACKEND_URL"
        value = "http://backend"
      }

      dynamic "env" {
        for_each = local.otel_env
        content {
          name  = env.key
          value = env.value
        }
      }

      liveness_probe {
        transport = "HTTP"
        port      = 8080
        path      = "/health"
      }
    }

    http_scale_rule {
      name                = "http-concurrency"
      concurrent_requests = 10
    }
  }

  tags = local.common_tags

  depends_on = [azurerm_role_assignment.acr_pull, azapi_update_resource.otel_agent]
}
