output "id" {
  description = "Resource ID of the storage account."
  value       = module.storage_account.resource_id
}

output "name" {
  description = "Name of the storage account, as generated from the workload word."
  value       = module.storage_account.name
}

output "blob_endpoint" {
  description = "Primary blob endpoint."
  value       = module.storage_account.fqdn.blob
}

output "container_name" {
  description = "The container created in the account."
  value       = var.container_name
}

# Deliberately not re-exported: the whole `resource` object from the AVM
# module. It is the raw azapi resource, and passing it through would make this
# module's interface a copy of AVM's — every field AVM adds or renames would
# become a change in this module's output, which is the coupling that wrapping
# was supposed to remove. A consumer who genuinely needs the raw body should
# call AVM directly and own that decision.
