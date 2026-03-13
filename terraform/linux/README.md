# Terraform – Linux VM with ADE

This Terraform module deploys the **lab starting state**: an Ubuntu 22.04 LTS VM with **Azure Disk Encryption (ADE)** enabled using the `AzureDiskEncryptionForLinux` extension (publisher `Microsoft.Azure.Security`, typeHandlerVersion `1.1`). The Key Encryption Key (KEK) is stored in an Azure Key Vault that is created alongside the VM.

## Resources deployed

| Resource | Name pattern |
|----------|-------------|
| Resource Group | `var.resource_group_name` |
| Key Vault | `<prefix>-kv-<random>` |
| Key Vault Key (KEK) | `<prefix>-ade-key` |
| Virtual Network | `<prefix>-vnet` |
| Subnet | `default` (10.0.0.0/24) |
| Network Security Group | `<prefix>-nsg` |
| Public IP | `<prefix>-pip` |
| Network Interface | `<prefix>-nic` |
| Linux Virtual Machine | `<prefix>-lnx-vm` |
| ADE VM Extension | `AzureDiskEncryptionForLinux` |

## Extension details

| Property | Value |
|----------|-------|
| Publisher | `Microsoft.Azure.Security` |
| Type | `AzureDiskEncryptionForLinux` |
| typeHandlerVersion | `1.1` (no Microsoft Entra ID properties required) |
| KeyEncryptionAlgorithm | `RSA-OAEP` |
| VolumeType | `All` (OS disk) |

> **Note:** `VolumeType: All` encrypts all volumes. OS-disk encryption on Linux requires the swap file to be disabled before enabling ADE.

The `KeyEncryptionKeyURL` setting is set to the **versioned** key URI (`azurerm_key_vault_key.ade_key.id`) as required by the ADE extension schema.

## Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `resource_group_name` | **Yes** | — | Resource group to create |
| `location` | No | `eastus` | Azure region |
| `prefix` | No | `adelab` | Resource name prefix (2–10 chars) |
| `admin_username` | **Yes** | — | VM administrator username |
| `admin_ssh_public_key` | **Yes** | — | SSH public key content (contents of `~/.ssh/id_rsa.pub`) |
| `vm_size` | No | `Standard_D2s_v5` | VM SKU |
| `key_vault_admin_object_id` | **Yes** | — | AAD object ID for Key Vault access |
| `allowed_ssh_source_address` | No | `Deny` | Source IP/CIDR for SSH, or `Deny` |
| `tags` | No | Lab defaults | Tags applied to all resources |

## Quickstart

```bash
# 1. Clone and enter the directory
cd terraform/linux

# 2. Copy the example vars file
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars – fill in key_vault_admin_object_id at minimum

# 3. Initialise, plan and apply
terraform init
terraform plan -var="admin_ssh_public_key=$(cat ~/.ssh/id_rsa.pub)"
terraform apply -var="admin_ssh_public_key=$(cat ~/.ssh/id_rsa.pub)"
```

## Validate ADE is enabled

```bash
# From the Terraform outputs
RG=$(terraform output -raw resource_group_name)
VM=$(terraform output -raw vm_name)

az vm encryption show \
  --resource-group "$RG" \
  --name "$VM" \
  --query "disks[*].{name:name,state:encryptionState}"
```

## Outputs

| Output | Description |
|--------|-------------|
| `vm_id` | Resource ID of the VM |
| `vm_name` | Name of the VM |
| `public_ip_address` | Public IP of the VM |
| `resource_group_name` | Resource group name |
| `key_vault_id` | Resource ID of the Key Vault |
| `key_vault_name` | Name of the Key Vault |
| `key_vault_uri` | Vault URI |
| `ade_key_id` | Versioned URI of the KEK |

## Next steps

Once deployment is complete and ADE is confirmed, use the migration scripts:

- **PowerShell**: [`/scripts/powershell/03-Migrate-ADE-to-EAH.ps1`](../../scripts/powershell/03-Migrate-ADE-to-EAH.ps1)
- **CLI**: [`/scripts/cli/03-migrate-ade-to-eah.sh`](../../scripts/cli/03-migrate-ade-to-eah.sh)
