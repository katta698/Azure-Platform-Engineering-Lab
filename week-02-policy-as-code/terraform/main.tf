locals {
  common_tags = {
    week       = "02"
    env        = "dev"
    managed-by = "terraform"
  }

  # Storage account names are globally unique and allow no punctuation, so the
  # week needs a suffix that is stable across applies. A hash of the
  # subscription ID gives one without pulling in the random provider, whose
  # whole job is to keep a value in state that is already derivable.
  #
  # nonsensitive() is deliberate: the input is sensitive, an 8-character SHA-1
  # prefix of it is not, and leaving it marked sensitive redacts the storage
  # account name from every plan for no benefit.
  suffix = nonsensitive(substr(sha1(var.subscription_id), 0, 8))

  # Role definition GUIDs are identical in every tenant. Resolved here with
  # `az role definition list --name "<role>"` rather than copied.
  roles = {
    # Writes diagnostic settings on the target resource.
    monitoring_contributor = "749f88d5-cbae-40b8-bcfc-e573ddc772fa"
    # Writes to the Log Analytics workspace the setting points at. Both are
    # needed: one grants the write on the source, the other on the destination.
    log_analytics_contributor = "92aaf0da-9dab-42b6-94a3-d43ce8d16293"
    # Writes tags and nothing else. See the modify definition below for why
    # this is not Contributor.
    tag_contributor = "4a9ae827-6dc8-4573-8ac7-8239d42aa03f"
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# The test bed
#
# A resource group carrying the cost-center tag, a Log Analytics workspace to
# be the diagnostic destination, and two storage accounts that are
# non-compliant on both counts by construction: no diagnostic setting, and no
# cost-center tag.
#
# They are non-compliant deliberately and they are created BEFORE the policy
# acts. That is the case remediation exists for — a deny only ever governs the
# next deployment, while modify and deployIfNotExists reach backwards into an
# estate that already exists. An empty subscription cannot demonstrate either.
# ═══════════════════════════════════════════════════════════════════════════

resource "azurerm_resource_group" "week" {
  name     = "rg-wk02-policy-as-code-dev-scus-001"
  location = var.location

  # The cost-center tag is set HERE and nowhere else. Azure tags do not
  # inherit, so nothing inside this group has it — which is precisely what the
  # modify rule is for. Week 01 set the tag on every resource by hand; this
  # week takes the other route and enforces it.
  tags = merge(local.common_tags, {
    (var.inherited_tag_name) = var.cost_center
  })
}

resource "azurerm_log_analytics_workspace" "diagnostics" {
  name                = "law-wk02-dev-scus-001"
  resource_group_name = azurerm_resource_group.week.name
  location            = azurerm_resource_group.week.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days

  tags = local.common_tags
}

resource "azurerm_storage_account" "target" {
  for_each = toset(["a", "b"])

  name                     = "stwk02${each.key}${local.suffix}"
  resource_group_name      = azurerm_resource_group.week.name
  location                 = azurerm_resource_group.week.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # No cost-center tag. The modify rule adds it.
  tags = local.common_tags
}

# ═══════════════════════════════════════════════════════════════════════════
# The remediation identity
#
# User-assigned, not system-assigned, and that is the main design decision of
# the week.
#
# A system-assigned identity does not exist until the policy assignment that
# owns it exists, so its principal ID cannot be known before then, so the role
# assignment can only be created afterwards. Azure begins evaluating the
# assignment immediately. The window between "assignment exists" and "identity
# has permission" is real, and every remediation that starts inside it fails.
#
# A user-assigned identity inverts the order: create the identity, grant it,
# then hand it to the assignment. Terraform expresses that as a dependency
# rather than a race. It also survives the assignment being replaced, which
# matters the first time an initiative is re-created and every grant attached
# to the old system-assigned principal is silently orphaned.
#
# One assignment holds exactly one identity either way — this is not a case
# where user-assigned buys you several.
# ═══════════════════════════════════════════════════════════════════════════

resource "azurerm_user_assigned_identity" "remediation" {
  name                = "id-wk02-policy-remediation"
  resource_group_name = azurerm_resource_group.week.name
  location            = azurerm_resource_group.week.location

  tags = local.common_tags
}

# The grants. Scoped to mg-lz-dev — the same scope the initiative is assigned
# at, not the subscription and not the resource group. A remediation task runs
# against everything the assignment governs, so an identity granted only on the
# week's resource group fails on any other subscription placed under mg-lz-dev
# later, with an error about permissions that is really about scope.
#
# for_each over a map that is empty when grants are withheld: count would work
# too, but for_each keeps each role a separately addressable resource, so
# revoking one in isolation is a targeted change rather than a re-index.
resource "azurerm_role_assignment" "remediation" {
  for_each = var.grant_remediation_roles ? local.roles : {}

  scope              = var.lz_dev_management_group_id
  role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/${each.value}"
  principal_id       = azurerm_user_assigned_identity.remediation.principal_id

  # The identity is created seconds before this. Entra replication means the
  # principal is not always resolvable yet, and the failure is
  # PrincipalNotFound, which reads like a wrong object ID. This tells ARM to
  # accept the principal ID without looking it up first.
  skip_service_principal_aad_check = true
}

# ═══════════════════════════════════════════════════════════════════════════
# Definition 1 — deployIfNotExists
#
# Any storage account without a diagnostic setting pointing at the lab
# workspace gets one deployed.
#
# The shape below is the one Azure's own built-in
# (59759c62-9a22-4cdf-ae64-074495983fef) uses, read out of this tenant with
# `az policy definition show` rather than reconstructed from documentation.
# Three parts have to agree or the policy misbehaves quietly:
#
#   details.name               the setting the existence check looks for
#   details.existenceCondition what counts as "already satisfied"
#   details.deployment         what gets created when it is not
#
# If the deployment creates a setting the existence condition does not match,
# the resource is non-compliant forever and a new deployment fires on every
# evaluation cycle.
#
# details.roleDefinitionIds is the part that makes this week different from
# week 01. It is a declaration of what the assignment's identity must hold.
# ═══════════════════════════════════════════════════════════════════════════

resource "azurerm_policy_definition" "storage_diagnostics" {
  name                = "dine-storage-diagnostics-to-law"
  display_name        = "Storage accounts must send diagnostics to the lab workspace"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = var.root_management_group_id

  description = <<-EOT
    Deploys a diagnostic setting to any storage account that does not already
    have one pointing at the lab Log Analytics workspace.

    Diagnostics configured per resource, by hand, at creation time are
    diagnostics that exist on the resources someone remembered. This makes the
    workspace the default destination for every storage account in scope,
    including the ones created after the policy.
  EOT

  metadata = jsonencode({
    category = "Monitoring"
    version  = "1.0.0"
  })

  policy_rule = jsonencode({
    if = {
      field  = "type"
      equals = "Microsoft.Storage/storageAccounts"
    }
    then = {
      effect = "[parameters('effect')]"
      details = {
        type = "Microsoft.Insights/diagnosticSettings"
        name = "[parameters('diagnosticSettingName')]"

        # What the identity must be able to do. Monitoring Contributor writes
        # the setting on the storage account; Log Analytics Contributor writes
        # to the workspace it points at. Dropping either produces a remediation
        # that fails on authorization at the half of the operation you did not
        # grant.
        roleDefinitionIds = [
          "/providers/Microsoft.Authorization/roleDefinitions/${local.roles.monitoring_contributor}",
          "/providers/Microsoft.Authorization/roleDefinitions/${local.roles.log_analytics_contributor}",
        ]

        existenceCondition = {
          allOf = [
            {
              field  = "Microsoft.Insights/diagnosticSettings/metrics.enabled"
              equals = "true"
            },
            {
              field  = "Microsoft.Insights/diagnosticSettings/workspaceId"
              equals = "[parameters('logAnalyticsWorkspaceId')]"
            },
          ]
        }

        deployment = {
          properties = {
            mode = "incremental"
            parameters = {
              location     = { value = "[field('location')]" }
              logAnalytics = { value = "[parameters('logAnalyticsWorkspaceId')]" }
              profileName  = { value = "[parameters('diagnosticSettingName')]" }
              # field('fullName'), not field('name'). They are the same string
              # for a top-level resource and different for a nested one, and
              # the nested case is the one that fails in production.
              resourceName = { value = "[field('fullName')]" }
            }
            template = {
              "$schema"      = "http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#"
              contentVersion = "1.0.0.0"
              parameters = {
                location     = { type = "string" }
                logAnalytics = { type = "string" }
                profileName  = { type = "string" }
                resourceName = { type = "string" }
              }
              resources = [
                {
                  type       = "Microsoft.Storage/storageAccounts/providers/diagnosticSettings"
                  apiVersion = "2021-05-01-preview"
                  name       = "[concat(parameters('resourceName'), '/', 'Microsoft.Insights/', parameters('profileName'))]"
                  location   = "[parameters('location')]"
                  properties = {
                    workspaceId = "[parameters('logAnalytics')]"
                    # Metrics only, and that is a property of storage rather
                    # than a shortcut. A storage account's log categories
                    # (StorageRead, StorageWrite, StorageDelete) belong to its
                    # blobServices/default child, not to the account, so a
                    # setting written at account scope can carry metrics and
                    # nothing else. Asking for log categories here fails inside
                    # the remediation deployment, where it surfaces as a failed
                    # job rather than as a policy problem.
                    metrics = [
                      {
                        category = "AllMetrics"
                        enabled  = true
                      },
                    ]
                  }
                },
              ]
              outputs   = {}
              variables = {}
            }
          }
        }
      }
    }
  })

  parameters = jsonencode({
    effect = {
      type = "String"
      metadata = {
        displayName = "Effect"
        description = "AuditIfNotExists to report, DeployIfNotExists to fix, Disabled to switch off."
      }
      # Both effects, one definition. The audit stage and the deploy stage are
      # the same rule with the same existence condition — which is the reason
      # the audit stage is worth anything as a preview of the deploy stage.
      allowedValues = ["AuditIfNotExists", "DeployIfNotExists", "Disabled"]
      defaultValue  = "AuditIfNotExists"
    }
    logAnalyticsWorkspaceId = {
      type = "String"
      metadata = {
        displayName = "Log Analytics workspace"
        description = "Resource ID of the destination workspace."
        strongType  = "omsWorkspace"
      }
    }
    diagnosticSettingName = {
      type     = "String"
      metadata = { displayName = "Diagnostic setting name" }
    }
  })
}

# ═══════════════════════════════════════════════════════════════════════════
# Definition 2 — modify
#
# Copies a tag down from the resource group to any resource inside it that is
# missing it.
#
# Azure ships this as a built-in (ea3f2387-9b95-492a-a190-fcdc54f7b070), and
# this week writes it out instead for one reason: the built-in's
# roleDefinitionIds names Contributor. Assigning it means the remediation
# identity holds Contributor over every subscription under mg-lz-dev, in order
# to write a tag.
#
# The definition decides how much power the identity needs. This copy is
# identical except that it asks for Tag Contributor — write tags, nothing else.
# That is a smaller blast radius chosen at the definition, which is the only
# place it can be chosen: an assignment cannot grant less than the definition
# demands.
# ═══════════════════════════════════════════════════════════════════════════

resource "azurerm_policy_definition" "inherit_tag" {
  name                = "modify-inherit-tag-from-rg"
  display_name        = "Resources inherit the cost-center tag from their resource group"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = var.root_management_group_id

  # 512 characters, and Azure counts them. This description was 513 on the first
  # apply and failed with InvalidCreatePolicyDefinitionRequest naming the exact
  # length — a good error, but only after a minute and a half spent creating the
  # definition before it.
  description = <<-EOT
    Adds the named tag, with the resource group's value, to any resource in
    scope that does not already carry it.

    Azure tags do not inherit. A resource group's tags are metadata on the
    group, not a default for its contents, so every cost report grouped by tag
    is wrong by exactly the set of resources whose author forgot.

    Deliberately narrower than the built-in equivalent, which requires
    Contributor on the remediation identity to do the same job.
  EOT

  metadata = jsonencode({
    category = "Tags"
    version  = "1.0.0"
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        {
          # The resource is missing the tag...
          field  = "[concat('tags[', parameters('tagName'), ']')]"
          exists = "false"
        },
        {
          # ...and the resource group actually has a value to give it. Without
          # this second test the rule fires on every untagged resource in every
          # untagged group and writes an empty string, which is worse than a
          # missing tag because it looks answered.
          value     = "[resourceGroup().tags[parameters('tagName')]]"
          notEquals = ""
        },
      ]
    }
    then = {
      effect = "[parameters('effect')]"
      details = {
        roleDefinitionIds = [
          "/providers/Microsoft.Authorization/roleDefinitions/${local.roles.tag_contributor}",
        ]
        operations = [
          {
            operation = "add"
            field     = "[concat('tags[', parameters('tagName'), ']')]"
            value     = "[resourceGroup().tags[parameters('tagName')]]"
          },
        ]
      }
    }
  })

  parameters = jsonencode({
    effect = {
      type = "String"
      metadata = {
        displayName = "Effect"
        description = "Modify to write the tag, Disabled to switch off."
      }
      # No Audit option, and that is not an oversight. Modify has no audit
      # counterpart — its effects are Modify, Disabled and nothing else. The
      # audit stage of this week therefore runs this rule Disabled, and answers
      # "how many resources are missing the tag" from the compliance report of
      # the tag rule in week 01's baseline instead.
      allowedValues = ["Modify", "Disabled"]
      defaultValue  = "Disabled"
    }
    tagName = {
      type     = "String"
      metadata = { displayName = "Tag to inherit" }
    }
  })
}

# ═══════════════════════════════════════════════════════════════════════════
# The initiative
#
# Both rules assigned as one unit, so compliance is one number for one scope
# rather than two numbers that have to be reconciled by hand.
# ═══════════════════════════════════════════════════════════════════════════

resource "azurerm_management_group_policy_set_definition" "remediation" {
  name                = "initiative-lab-remediation"
  display_name        = "Lab remediation baseline"
  description         = "The rules that fix what they find, rather than blocking the next attempt."
  policy_type         = "Custom"
  management_group_id = var.root_management_group_id

  metadata = jsonencode({
    category = "Lab"
    version  = "1.0.0"
  })

  parameters = jsonencode({
    logAnalyticsWorkspaceId = {
      type     = "String"
      metadata = { displayName = "Log Analytics workspace", strongType = "omsWorkspace" }
    }
    diagnosticsEffect = {
      type          = "String"
      metadata      = { displayName = "Effect for the diagnostics rule" }
      allowedValues = ["AuditIfNotExists", "DeployIfNotExists", "Disabled"]
    }
    diagnosticSettingName = {
      type     = "String"
      metadata = { displayName = "Diagnostic setting name" }
    }
    tagName = {
      type     = "String"
      metadata = { displayName = "Tag to inherit" }
    }
    tagEffect = {
      type          = "String"
      metadata      = { displayName = "Effect for the tag rule" }
      allowedValues = ["Modify", "Disabled"]
    }
  })

  # reference_id is the handle everything downstream uses: a remediation task
  # names one, and a non-compliance message is attached to one. Renaming a
  # reference_id later breaks both silently — a task naming a reference the
  # initiative no longer has simply finds nothing to do.
  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.storage_diagnostics.id
    reference_id         = "storage-diagnostics"
    parameter_values = jsonencode({
      effect                  = { value = "[parameters('diagnosticsEffect')]" }
      logAnalyticsWorkspaceId = { value = "[parameters('logAnalyticsWorkspaceId')]" }
      diagnosticSettingName   = { value = "[parameters('diagnosticSettingName')]" }
    })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.inherit_tag.id
    reference_id         = "inherit-tag"
    parameter_values = jsonencode({
      effect  = { value = "[parameters('tagEffect')]" }
      tagName = { value = "[parameters('tagName')]" }
    })
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# The assignment
#
# At mg-lz-dev, never at the subscription.
#
# The identity is attached in EVERY stage, including the audit one, and that is
# not what this week originally assumed. The first apply attached it only when
# remediating and Azure refused the assignment outright:
#
#   ResourceIdentityRequired: Policy assignments must include a 'managed
#   identity' when assigning 'DeployIfNotExists' policy definitions or policy
#   definitions that contain a deployment in the effect details.
#
# Read that carefully — the requirement is on what the DEFINITION CAN DO, not on
# the effect the assignment selected. The initiative here contains a definition
# with a deployment in its details, so the assignment needs an identity even
# with every effect set to AuditIfNotExists and Disabled, where the identity
# cannot possibly act.
#
# Which relocates the whole question. The identity's presence is not what makes
# an assignment dangerous; its ROLE ASSIGNMENTS are. An attached identity with
# nothing granted to it is inert, and that is the real separation between the
# audit stage and the remediation stage below.
#
# The name is 22 characters. Policy assignment names are capped at 24 and the
# failure is at plan time with a message that names the limit, which is the
# good version of this mistake.
# ═══════════════════════════════════════════════════════════════════════════

resource "azurerm_management_group_policy_assignment" "dev" {
  name                 = "assign-remediation-dev"
  display_name         = "Lab remediation — dev landing zones"
  management_group_id  = var.lz_dev_management_group_id
  policy_definition_id = azurerm_management_group_policy_set_definition.remediation.id
  location             = var.location

  # Always enforcing. enforce = false (DoNotEnforce) would suppress the modify
  # and the deployment while still reporting compliance — a third stage this
  # week does not need, because the audit stage already gives the report-only
  # view using an effect that cannot act by definition.
  enforce = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.remediation.id]
  }

  parameters = jsonencode({
    logAnalyticsWorkspaceId = { value = azurerm_log_analytics_workspace.diagnostics.id }
    diagnosticSettingName   = { value = var.diagnostic_setting_name }
    tagName                 = { value = var.inherited_tag_name }
    diagnosticsEffect       = { value = var.enable_remediation ? "DeployIfNotExists" : "AuditIfNotExists" }
    tagEffect               = { value = var.enable_remediation ? "Modify" : "Disabled" }
  })

  non_compliance_message {
    policy_definition_reference_id = "storage-diagnostics"
    content                        = "This storage account sends no diagnostics to the lab workspace. The lab remediation baseline deploys one; nothing needs doing by hand."
  }

  non_compliance_message {
    policy_definition_reference_id = "inherit-tag"
    content                        = "This resource is missing the cost-center tag its resource group carries. The lab remediation baseline adds it."
  }

  # The grants must exist before the assignment does, in the remediation stage.
  # Terraform cannot infer this: the assignment references the identity, not
  # the role assignments, so without depends_on it is free to create the
  # assignment first — and Azure starts evaluating the moment it exists.
  depends_on = [azurerm_role_assignment.remediation]
}

# ═══════════════════════════════════════════════════════════════════════════
# What is NOT here: the remediation task
#
# azurerm_management_group_policy_remediation exists and would fit in this
# file. It is left out on purpose, and the reason is worth more than the
# convenience.
#
# A remediation task is a job, not a piece of desired state. It acts on the
# resources the LAST COMPLETED EVALUATION marked non-compliant — so a task
# created in the same apply as the assignment finds an empty list, because
# nothing has been evaluated yet, and reports success having done nothing. The
# resource goes green in state, and Terraform then has no reason to re-run it.
#
# The subscription-scoped resource has resource_discovery_mode =
# "ReEvaluateCompliance", which fixes exactly this. The management-group-scoped
# one does not have that argument at all — checked against the azurerm 5.x
# provider schema, not assumed — so at the scope this week assigns at, there is
# no way to express "evaluate first, then remediate" in Terraform.
#
# So the task is created in validate.sh, after a forced scan, where it can be
# polled and its result reported honestly.
# ═══════════════════════════════════════════════════════════════════════════
