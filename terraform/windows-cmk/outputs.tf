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

output "des_key_id" {
  description = "Versioned URI of the Customer-Managed Key used by the DES."
  value       = azurerm_key_vault_key.des_key.id
}

output "disk_encryption_set_id" {
  description = "Resource ID of the Disk Encryption Set."
  value       = azurerm_disk_encryption_set.des.id
}

output "disk_encryption_set_name" {
  description = "Name of the Disk Encryption Set."
  value       = azurerm_disk_encryption_set.des.name
}

output "os_disk_name" {
  description = "Name of the OS managed disk."
  value       = azurerm_windows_virtual_machine.vm.os_disk[0].name
}

output "nic_id" {
  description = "Resource ID of the network interface."
  value       = azurerm_network_interface.nic.id
}

output "subnet_id" {
  description = "Resource ID of the subnet."
  value       = azurerm_subnet.default.id
}

output "vm_size" {
  description = "VM size SKU."
  value       = azurerm_windows_virtual_machine.vm.size
}
