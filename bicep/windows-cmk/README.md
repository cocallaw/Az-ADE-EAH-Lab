# Bicep – Windows VM with Encryption at Host + CMK

This Bicep template deploys the **advanced lab end-state**: a Windows Server 2022 VM with **Encryption at Host (EaH)** enabled and disks encrypted via a **Disk Encryption Set (DES)** backed by a customer-managed key (CMK) in Key Vault.

> **Prerequisite:** The `EncryptionAtHost` feature must be registered on the subscription. See [Step 1 in the Lab Walkthrough](../../LAB_WALKTHROUGH.md#step-1--register-the-encryptionathost-feature).

## Resources deployed

| Resource | Name pattern |
|----------|-------------|
| Key Vault | `<prefix>-kv-<unique>` |
| Key Vault Key (CMK) | `<prefix>-des-key` |
| Disk Encryption Set | `<prefix>-des` |
| Virtual Network | `<prefix>-vnet` |
| Subnet | `default` (10.0.0.0/24) |
| Network Security Group | `<prefix>-nsg` |
| Public IP | `<prefix>-pip` |
| Network Interface | `<prefix>-nic` |
| Virtual Machine | `<prefix>-win-vm` |

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `location` | No | RG location | Azure region |
| `prefix` | No | `cmklab` | Name prefix (2–10 chars) |
| `adminUsername` | **Yes** | — | VM admin user |
| `adminPassword` | **Yes** | — | VM admin password (min 12 chars, stored as secure string) |
| `vmSize` | No | `Standard_D2s_v5` | VM SKU |
| `keyVaultAdminObjectId` | **Yes** | — | AAD object ID for Key Vault access |
| `allowedRdpSourceAddress` | No | `Deny` | Source IP/CIDR allowed for RDP, or `Deny` |
| `deploymentTimestamp` | No | `utcNow()` | Auto-generated; ensures a unique Key Vault name per deployment |

## Deployment

### Azure CLI

```bash
# 1. Create a resource group
az group create --name cmk-lab-rg --location eastus

# 2. (Optional) Obtain your current object ID
OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

# 3. Deploy
az deployment group create \
  --resource-group cmk-lab-rg \
  --template-file main.bicep \
  --parameters prefix=cmklab \
               adminUsername=labadmin \
               adminPassword='<SECURE-PASSWORD>' \
               keyVaultAdminObjectId="$OBJECT_ID" \
               allowedRdpSourceAddress="$(curl -s ifconfig.me)/32"
```

### PowerShell

```powershell
$rg = 'cmk-lab-rg'
New-AzResourceGroup -Name $rg -Location 'eastus'

$objectId = (Get-AzADUser -SignedIn).Id

New-AzResourceGroupDeployment `
  -ResourceGroupName $rg `
  -TemplateFile ./main.bicep `
  -prefix 'cmklab' `
  -adminUsername 'labadmin' `
  -adminPassword (ConvertTo-SecureString '<SECURE-PASSWORD>' -AsPlainText -Force) `
  -keyVaultAdminObjectId $objectId `
  -allowedRdpSourceAddress "$(Invoke-RestMethod ifconfig.me)/32"
```

## Validate EaH + CMK

```bash
# Verify Encryption at Host is enabled
az vm show \
  --resource-group cmk-lab-rg \
  --name cmklab-win-vm \
  --query "securityProfile.encryptionAtHost"

# Verify the OS disk uses the Disk Encryption Set
az vm show \
  --resource-group cmk-lab-rg \
  --name cmklab-win-vm \
  --query "storageProfile.osDisk.managedDisk.diskEncryptionSet.id"
```

## Key concepts

- **Same Key Vault** can host both ADE KEK and CMK for DES
- **DES managed identity** receives `get`, `wrapKey`, `unwrapKey` permissions automatically
- **Auto-key-rotation** updates all associated disks within ~1 hour without VM reboot
- **CMK encrypts** disk data and caches; the temp disk still uses platform-managed keys

## Next steps

See the [Advanced CMK documentation](../../docs/ADVANCED_CMK.md) for a full explanation of the CMK/DES architecture and how it fits into the ADE → EaH migration story.
