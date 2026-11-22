# Four deny policies. Each refuses at the API, before anything is created.
# Discipline has failed twice in this lab -- a $6 meter dropped as uncertain in
# week 11, and a reservation total misread as an hourly rate in week 14. These
# do not depend on anyone reading a number correctly.

locals { mg = "/providers/Microsoft.Management/managementGroups/${var.management_group}" }

resource "azurerm_policy_definition" "vm_size" {
  name                = "lab-deny-large-vm-sizes"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Lab guardrail: only small VM sizes"
  management_group_id = local.mg

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Compute/virtualMachines" },
        { not = { field = "Microsoft.Compute/virtualMachines/sku.name", in = "[parameters('allowed')]" } }
      ]
    }
    then = { effect = "deny" }
  })

  parameters = jsonencode({
    allowed = { type = "Array", metadata = { displayName = "Allowed VM sizes" } }
  })
}

resource "azurerm_policy_definition" "postgres_sku" {
  name                = "lab-deny-large-postgres"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Lab guardrail: only small PostgreSQL SKUs"
  management_group_id = local.mg

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.DBforPostgreSQL/flexibleServers" },
        { not = { field = "Microsoft.DBforPostgreSQL/flexibleServers/sku.name", in = "[parameters('allowed')]" } }
      ]
    }
    then = { effect = "deny" }
  })

  parameters = jsonencode({
    allowed = { type = "Array", metadata = { displayName = "Allowed PostgreSQL SKUs" } }
  })
}

# Resource types this lab has never needed and whose entry price is high enough
# that an accident is expensive. Managed HSM is ~$3/hour; Dedicated HSM ~$4.85.
resource "azurerm_policy_definition" "banned_types" {
  name                = "lab-deny-expensive-types"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Lab guardrail: resource types the lab never uses"
  management_group_id = local.mg

  policy_rule = jsonencode({
    if = {
      field = "type"
      in = [
        "Microsoft.KeyVault/managedHSMs",
        "Microsoft.HardwareSecurityModules/dedicatedHSMs",
        "Microsoft.ApiManagement/service",
        "Microsoft.Network/expressRouteCircuits",
        "Microsoft.Network/expressRoutePorts",
        "Microsoft.AVS/privateClouds",
        "Microsoft.Sql/managedInstances",
      ]
    }
    then = { effect = "deny" }
  })
}

# A commitment tier is a daily flat charge starting at 100 GB/day. The dearest
# Sentinel tier is $117,990/day -- a real consumption rate, verified, not a
# reservation total.
resource "azurerm_policy_definition" "workspace_sku" {
  name                = "lab-deny-commitment-tiers"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Lab guardrail: Log Analytics stays pay-as-you-go"
  management_group_id = local.mg

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.OperationalInsights/workspaces" },
        { not = { field = "Microsoft.OperationalInsights/workspaces/sku.name", in = ["PerGB2018", "Free", "Standalone"] } }
      ]
    }
    then = { effect = "deny" }
  })
}

# azurerm 5.x cannot create a custom policy SET at management-group scope --
# the resource has no management_group argument. Four separate assignments do
# the same job.

resource "azurerm_management_group_policy_assignment" "vm_size" {
  name                 = "lab-deny-large-vms"
  display_name         = "Lab guardrail: only small VM sizes"
  management_group_id  = local.mg
  policy_definition_id = azurerm_policy_definition.vm_size.id
  parameters           = jsonencode({ allowed = { value = var.allowed_vm_sizes } })
}

resource "azurerm_management_group_policy_assignment" "postgres_sku" {
  name                 = "lab-deny-large-postgres"
  display_name         = "Lab guardrail: only small PostgreSQL SKUs"
  management_group_id  = local.mg
  policy_definition_id = azurerm_policy_definition.postgres_sku.id
  parameters           = jsonencode({ allowed = { value = var.allowed_postgres_skus } })
}

resource "azurerm_management_group_policy_assignment" "banned_types" {
  name                 = "lab-deny-expensive-types"
  display_name         = "Lab guardrail: resource types the lab never uses"
  management_group_id  = local.mg
  policy_definition_id = azurerm_policy_definition.banned_types.id
}

resource "azurerm_management_group_policy_assignment" "workspace_sku" {
  name                 = "lab-deny-commit-tiers"
  display_name         = "Lab guardrail: Log Analytics stays pay-as-you-go"
  management_group_id  = local.mg
  policy_definition_id = azurerm_policy_definition.workspace_sku.id
}
