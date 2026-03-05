# Bicep – Windows VM with ADE

This Bicep template deploys the **lab starting state**: a Windows Server 2022 VM with **Azure Disk Encryption (ADE)** enabled. Use it as the baseline before running the migration scripts.

## Resources deployed

| Resource | Name pattern |
|----------|-------------|
| Key Vault | `<prefix>-kv-<unique>` |
| Key Vault Key (KEK) | `<prefix>-ade-key` |
| Virtual Network | `<prefix>-vnet` |
| Subnet | `default` (10.0.0.0/24) |
| Network Security Group | `<prefix>-nsg` |
| Public IP | `<prefix>-pip` |
| Network Interface | `<prefix>-nic` |
| Virtual Machine | `<prefix>-win-vm` |
| ADE Extension | `AzureDiskEncryption` |

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `location` | No | RG location | Azure region |
| `prefix` | No | `adelab` | Name prefix (2–10 chars) |
| `adminUsername` | **Yes** | — | VM admin user |
| `adminPassword` | **Yes** | — | VM admin password (min 12 chars, stored as secure string) |
| `vmSize` | No | `Standard_D2s_v5` | VM SKU |
| `keyVaultAdminObjectId` | **Yes** | — | AAD object ID for Key Vault access |
| `allowedRdpSourceAddress` | No | `Deny` | Source IP/CIDR allowed for RDP, or `Deny` |

## Deployment

### Azure CLI

```bash
# 1. Create a resource group
az group create --name ade-lab-rg --location eastus

# 2. (Optional) Obtain your current object ID
OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

# 3. Deploy
az deployment group create \
  --resource-group ade-lab-rg \
  --template-file main.bicep \
  --parameters prefix=adelab \
               adminUsername=labadmin \
               adminPassword='<SECURE-PASSWORD>' \
               keyVaultAdminObjectId="$OBJECT_ID" \
               allowedRdpSourceAddress="$(curl -s ifconfig.me)/32"
```

### PowerShell

```powershell
$rg = 'ade-lab-rg'
New-AzResourceGroup -Name $rg -Location 'eastus'

$objectId = (Get-AzADUser -SignedIn).Id

New-AzResourceGroupDeployment `
  -ResourceGroupName $rg `
  -TemplateFile ./main.bicep `
  -prefix 'adelab' `
  -adminUsername 'labadmin' `
  -adminPassword (ConvertTo-SecureString '<SECURE-PASSWORD>' -AsPlainText -Force) `
  -keyVaultAdminObjectId $objectId `
  -allowedRdpSourceAddress "$(Invoke-RestMethod ifconfig.me)/32"
```

## Validate ADE is enabled

```powershell
Get-AzVMDiskEncryptionStatus -ResourceGroupName ade-lab-rg -VMName adelab-win-vm
```

```bash
az vm encryption show \
  --resource-group ade-lab-rg \
  --name adelab-win-vm \
  --query "disks[*].{name:name,encryptionState:encryptionState}"
```

## Next steps

Once the VM is deployed and ADE is confirmed active, proceed to the migration scripts:

- **PowerShell**: [`/scripts/powershell/03-Migrate-ADE-to-EAH.ps1`](../../scripts/powershell/03-Migrate-ADE-to-EAH.ps1)
- **CLI**: [`/scripts/cli/03-migrate-ade-to-eah.sh`](../../scripts/cli/03-migrate-ade-to-eah.sh)
