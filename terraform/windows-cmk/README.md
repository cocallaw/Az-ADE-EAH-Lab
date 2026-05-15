# Terraform – Windows VM with Encryption at Host + CMK

This Terraform module deploys the **advanced lab end-state**: a Windows Server 2022 VM with **Encryption at Host (EaH)** enabled and disks encrypted via a **Disk Encryption Set (DES)** backed by a customer-managed key (CMK) in Key Vault.

> **Prerequisite:** The `EncryptionAtHost` feature must be registered on the subscription. See [Step 1 in the Lab Walkthrough](../../LAB_WALKTHROUGH.md#step-1--register-the-encryptionathost-feature).

## Resources deployed

| Resource | Name pattern |
|----------|-------------|
| Resource Group | `var.resource_group_name` |
| Key Vault | `<prefix>-kv-<random>` |
| Key Vault Key (CMK) | `<prefix>-des-key` |
| Disk Encryption Set | `<prefix>-des` |
| Virtual Network | `<prefix>-vnet` |
| Subnet | `default` (10.0.0.0/24) |
| Network Security Group | `<prefix>-nsg` |
| Public IP | `<prefix>-pip` |
| Network Interface | `<prefix>-nic` |
| Windows Virtual Machine | `<prefix>-win-vm` |

## Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `resource_group_name` | **Yes** | — | Resource group to create |
| `location` | No | `eastus` | Azure region |
| `prefix` | No | `cmklab` | Resource name prefix (2–10 chars) |
| `admin_username` | **Yes** | — | VM administrator username |
| `admin_password` | **Yes** | — | VM administrator password (min 12 chars, sensitive) |
| `vm_size` | No | `Standard_D2s_v5` | VM SKU |
| `key_vault_admin_object_id` | **Yes** | — | AAD object ID for Key Vault access |
| `allowed_rdp_source_address` | No | `Deny` | Source IP/CIDR for RDP, or `Deny` |
| `tags` | No | Lab defaults | Tags applied to all resources |

## Quickstart

```bash
# 1. Clone and enter the directory
cd terraform/windows-cmk

# 2. Copy the example vars file
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars – fill in key_vault_admin_object_id at minimum

# 3. Initialise, plan and apply
terraform init
terraform plan -var="admin_password=<SECURE-PASSWORD>"
terraform apply -var="admin_password=<SECURE-PASSWORD>"
```

## Validate EaH + CMK

```bash
# From the Terraform outputs
RG=$(terraform output -raw resource_group_name)
VM=$(terraform output -raw vm_name)

# Verify Encryption at Host
az vm show \
  --resource-group "$RG" \
  --name "$VM" \
  --query "securityProfile.encryptionAtHost"

# Verify DES association on OS disk
az vm show \
  --resource-group "$RG" \
  --name "$VM" \
  --query "storageProfile.osDisk.managedDisk.diskEncryptionSet.id"
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
| `des_key_id` | Versioned URI of the CMK |
| `disk_encryption_set_id` | Resource ID of the Disk Encryption Set |
| `disk_encryption_set_name` | Name of the Disk Encryption Set |

## Key concepts

- **Same Key Vault** can host both ADE KEK and CMK for DES
- **DES managed identity** receives `Get`, `WrapKey`, `UnwrapKey` permissions via a separate access policy
- **Auto-key-rotation** updates all associated disks within ~1 hour without VM reboot
- **CMK encrypts** disk data and caches; the temp disk still uses platform-managed keys

## Next steps

See the [Advanced CMK documentation](../../docs/ADVANCED_CMK.md) for a full explanation of the CMK/DES architecture and how it fits into the ADE → EaH migration story.
