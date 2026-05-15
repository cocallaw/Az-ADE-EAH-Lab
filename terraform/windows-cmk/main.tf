terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"
      # NOTE: AzureRM 4.x is the current major version but has breaking changes.
      # See https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/4.0-upgrade-guide
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    virtual_machine {
      delete_os_disk_on_deletion     = true
      graceful_shutdown              = false
      skip_shutdown_and_force_delete = false
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Data sources
# ─────────────────────────────────────────────────────────────────────────────

data "azurerm_client_config" "current" {}

# ─────────────────────────────────────────────────────────────────────────────
# Resource Group
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Key Vault
# ─────────────────────────────────────────────────────────────────────────────

resource "random_string" "kv_suffix" {
  length  = 6
  upper   = false
  special = false

  keepers = {
    rg_name = var.resource_group_name
  }
}

resource "azurerm_key_vault" "kv" {
  name                        = "${var.prefix}-kv-${random_string.kv_suffix.result}"
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  enabled_for_disk_encryption = true
  enabled_for_deployment      = true
  purge_protection_enabled    = true
  soft_delete_retention_days  = 7
  tags                        = var.tags

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = var.key_vault_admin_object_id

    key_permissions = [
      "Create", "Delete", "Get", "List", "WrapKey", "UnwrapKey",
    ]
    secret_permissions = [
      "Get", "List", "Set",
    ]
  }
}

resource "azurerm_key_vault_key" "des_key" {
  name         = "${var.prefix}-des-key"
  key_vault_id = azurerm_key_vault.kv.id
  key_type     = "RSA"
  key_size     = 3072

  key_opts = [
    "decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey",
  ]

  depends_on = [azurerm_key_vault.kv]
}

# ─────────────────────────────────────────────────────────────────────────────
# Disk Encryption Set
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_disk_encryption_set" "des" {
  name                      = "${var.prefix}-des"
  location                  = azurerm_resource_group.rg.location
  resource_group_name       = azurerm_resource_group.rg.name
  key_vault_key_id          = azurerm_key_vault_key.des_key.id
  auto_key_rotation_enabled = true
  encryption_type           = "EncryptionAtRestWithCustomerKey"
  tags                      = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# Grant the DES managed identity access to the Key Vault key.
# This is a separate resource to avoid a circular dependency:
# DES needs a KV key → DES identity needs KV access → KV access needs DES identity.
resource "azurerm_key_vault_access_policy" "des" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_disk_encryption_set.des.identity[0].principal_id

  key_permissions = [
    "Get", "WrapKey", "UnwrapKey",
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Networking
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_network_security_group" "nsg" {
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags

  security_rule {
    name                       = "Allow-RDP"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = var.allowed_rdp_source_address == "Deny" ? "Deny" : "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = var.allowed_rdp_source_address == "Deny" ? "*" : var.allowed_rdp_source_address
    destination_address_prefix = "*"
  }
}

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "default" {
  name                 = "default"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.0.0/24"]
}

resource "azurerm_subnet_network_security_group_association" "nsg_assoc" {
  subnet_id                 = azurerm_subnet.default.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_public_ip" "pip" {
  name                = "${var.prefix}-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "nic" {
  name                = "${var.prefix}-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.default.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Virtual Machine — Encryption at Host + CMK via Disk Encryption Set
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_windows_virtual_machine" "vm" {
  name                = "${var.prefix}-win-vm"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  size                = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  tags                = var.tags

  network_interface_ids = [azurerm_network_interface.nic.id]

  os_disk {
    name                   = "${var.prefix}-osdisk"
    caching                = "ReadWrite"
    storage_account_type   = "Premium_LRS"
    disk_encryption_set_id = azurerm_disk_encryption_set.des.id
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }

  encryption_at_host_enabled = true

  boot_diagnostics {}

  depends_on = [azurerm_key_vault_access_policy.des]
}
