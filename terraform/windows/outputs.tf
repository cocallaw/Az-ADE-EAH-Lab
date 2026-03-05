output "vm_id" {
  description = "Resource ID of the deployed Windows VM."
  value       = azurerm_windows_virtual_machine.vm.id
}

output "vm_name" {
  description = "Name of the deployed Windows VM."
  value       = azurerm_windows_virtual_machine.vm.name
}

output "public_ip_address" {
  description = "Public IP address of the VM."
  value       = azurerm_public_ip.pip.ip_address
}

output "resource_group_name" {
  description = "Name of the resource group."
  value       = azurerm_resource_group.rg.name
}

output "key_vault_id" {
  description = "Resource ID of the Key Vault."
  value       = azurerm_key_vault.kv.id
}

output "key_vault_name" {
  description = "Name of the Key Vault."
  value       = azurerm_key_vault.kv.name
}

output "key_vault_uri" {
  description = "Vault URI of the Key Vault."
  value       = azurerm_key_vault.kv.vault_uri
}

output "ade_key_id" {
  description = "Versioned URI of the Key Encryption Key used for ADE."
  value       = azurerm_key_vault_key.ade_key.id
}
