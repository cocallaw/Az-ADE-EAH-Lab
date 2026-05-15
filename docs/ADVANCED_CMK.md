# Advanced Exercise: Customer-Managed Keys with Disk Encryption Sets

> **Optional lab extension** — This exercise builds on the main ADE → EaH migration by showing how to maintain full customer key ownership using a **Disk Encryption Set (DES)** with Customer-Managed Keys (CMK).

---

## Background

The main lab migrates from Azure Disk Encryption (ADE) to Encryption at Host (EaH). By default, EaH uses **Platform-Managed Keys (PMK)** — Microsoft manages the encryption keys automatically. This is sufficient for many workloads.

However, enterprise customers who used ADE with a **Key Encryption Key (KEK)** often require continued customer key ownership. Azure supports this through **Disk Encryption Sets (DES)**: a resource that binds managed disks to a customer-managed key in Key Vault.

### Encryption Comparison

| | ADE (before) | EaH + PMK (default) | EaH + CMK via DES (this exercise) |
|---|---|---|---|
| **Key ownership** | Customer (KEK in Key Vault) | Microsoft (platform) | Customer (CMK in Key Vault) |
| **Encryption scope** | OS + data volumes (guest-level) | All disk I/O at the host level | All disk I/O at the host + CMK for at-rest |
| **VM extension required** | Yes (`AzureDiskEncryption`) | No | No |
| **Key rotation** | Manual re-encrypt | N/A | Auto-rotation (~1 hour, no reboot) |
| **Temp disk encrypted** | Configurable | Yes (PMK) | Yes (PMK) |

---

## Key Concepts

### Same Key Vault, Different Keys

A single Key Vault can host both the ADE KEK and the new CMK for the Disk Encryption Set. In production, you may use the same vault or a dedicated one — the choice depends on your key management policy. The templates in this exercise create a dedicated CMK key (`<prefix>-des-key`) in the same vault.

### DES Managed Identity Permissions

The Disk Encryption Set uses a **System-Assigned Managed Identity** to access the Key Vault key. This identity needs the following key permissions:

- `Get` — read key metadata
- `WrapKey` — encrypt the disk encryption key (DEK)
- `UnwrapKey` — decrypt the DEK when reading disk data

The templates automatically grant these permissions via an additional Key Vault access policy.

### Auto-Key-Rotation

When `rotationToLatestKeyVersionEnabled` (Bicep) or `auto_key_rotation_enabled` (Terraform) is set to `true`, Azure automatically re-wraps all disk encryption keys with the latest key version within approximately **1 hour** — no VM reboot required.

To rotate the key, simply create a new version in Key Vault:

```bash
# Create a new key version (auto-rotation picks it up within ~1 hour)
az keyvault key create --vault-name <KV-NAME> --name <prefix>-des-key --kty RSA --size 3072
```

### What CMK Encrypts

- ✅ OS disk data at rest
- ✅ Data disk data at rest
- ✅ Disk caches (when combined with EaH)
- ❌ Temp disk — always encrypted with platform-managed keys

---

## Templates

Two template variants are provided, following the same structure as the main lab:

| IaC Tool | Directory | Key File |
|----------|-----------|----------|
| **Bicep** | [`bicep/windows-cmk/`](../bicep/windows-cmk/) | [`main.bicep`](../bicep/windows-cmk/main.bicep) |
| **Terraform** | [`terraform/windows-cmk/`](../terraform/windows-cmk/) | [`main.tf`](../terraform/windows-cmk/main.tf) |

Both templates deploy a Windows Server 2022 VM with:
- Encryption at Host enabled (`encryptionAtHost: true`)
- OS disk associated with a Disk Encryption Set
- Auto-key-rotation enabled on the DES
- No ADE extension (this is the post-migration end-state)

### Deploy with Bicep

```bash
az group create --name cmk-lab-rg --location eastus

OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

az deployment group create \
  --resource-group cmk-lab-rg \
  --template-file bicep/windows-cmk/main.bicep \
  --parameters prefix=cmklab \
               adminUsername=labadmin \
               adminPassword='<SECURE-PASSWORD>' \
               keyVaultAdminObjectId="$OBJECT_ID"
```

### Deploy with Terraform

```bash
cd terraform/windows-cmk
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — fill in key_vault_admin_object_id

terraform init
terraform apply -var="admin_password=<SECURE-PASSWORD>"
```

---

## Validate

After deployment, verify that both EaH and the DES are active:

```bash
# Check Encryption at Host
az vm show \
  --resource-group cmk-lab-rg \
  --name cmklab-win-vm \
  --query "securityProfile.encryptionAtHost"
# Expected: true

# Check DES on OS disk
az vm show \
  --resource-group cmk-lab-rg \
  --name cmklab-win-vm \
  --query "storageProfile.osDisk.managedDisk.diskEncryptionSet.id"
# Expected: /subscriptions/.../diskEncryptionSets/cmklab-des

# Check DES details
az disk-encryption-set show \
  --resource-group cmk-lab-rg \
  --name cmklab-des \
  --query "{name:name, encryptionType:encryptionType, autoRotation:rotationToLatestKeyVersionEnabled}" \
  -o table
# Expected: EncryptionAtRestWithCustomerKey, true
```

---

## Cleanup

### Bicep deployment

```bash
az group delete --name cmk-lab-rg --yes --no-wait
```

### Terraform deployment

```bash
cd terraform/windows-cmk
terraform destroy -var="admin_password=<SECURE-PASSWORD>"
```

> **Note:** Always prefer `terraform destroy` over `az group delete` when using Terraform — deleting the resource group directly leaves Terraform state pointing at deleted resources and can block re-deployments if the same Key Vault name is reused (purge protection prevents immediate re-creation).

> **Key Vault purge protection:** The Key Vault has purge protection enabled (required by DES). After destruction, the vault enters a soft-deleted state and is automatically purged after the retention period (7 days). If you need to redeploy sooner, change the `prefix` variable to generate a new Key Vault name.

---

## References

- [Disk Encryption Sets overview](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption)
- [Enable Encryption at Host with CMK (Portal)](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-enable-host-based-encryption-portal)
- [DES auto-rotation](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption#full-control-of-your-keys)
- [Encryption at Host overview](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption#encryption-at-host---end-to-end-encryption-for-your-vm-data)
