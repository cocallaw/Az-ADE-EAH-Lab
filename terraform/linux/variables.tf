variable "resource_group_name" {
  description = "Name of the resource group to create."
  type        = string
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus"
}

variable "prefix" {
  description = "Short prefix applied to every resource name (2-10 characters)."
  type        = string
  default     = "adelab"

  validation {
    condition     = length(var.prefix) >= 2 && length(var.prefix) <= 10
    error_message = "prefix must be between 2 and 10 characters."
  }
}

variable "admin_username" {
  description = "Admin username for the Linux VM."
  type        = string

  validation {
    condition     = length(var.admin_username) >= 1 && length(var.admin_username) <= 64
    error_message = "admin_username must be 1-64 characters."
  }
}

variable "admin_ssh_public_key" {
  description = "SSH public key content for the VM admin account."
  type        = string
}

variable "vm_size" {
  description = "VM SKU size."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "key_vault_admin_object_id" {
  description = "AAD object ID that will receive Key Vault access policies."
  type        = string
}

variable "allowed_ssh_source_address" {
  description = "Source IP/CIDR allowed for SSH inbound. Use 'Deny' to block all SSH."
  type        = string
  default     = "Deny"
}

variable "tags" {
  description = "Tags to apply to all resources."
  type        = map(string)
  default = {
    Environment = "Lab"
    Purpose     = "ADE-to-EaH-Migration"
  }
}
