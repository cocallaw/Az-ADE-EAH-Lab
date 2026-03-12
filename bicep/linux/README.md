# Bicep – Linux VM with ADE

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fcocallaw%2FAz-ADE-EAH-Lab%2Frefs%2Fheads%2Fmain%2Fbicep%2Flinux%2Fazuredeploy.json)

This Bicep template deploys the **lab starting state**: an Ubuntu 22.04 LTS VM with **Azure Disk Encryption (ADE)** enabled. Use it as the baseline before running the migration scripts.

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
| Virtual Machine | `<prefix>-lnx-vm` |
| ADE Extension | `AzureDiskEncryptionForLinux` |

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `location` | No | RG location | Azure region |
| `prefix` | No | `adelab` | Name prefix (2–10 chars) |
| `adminUsername` | **Yes** | — | VM admin user |
| `adminSshPublicKey` | **Yes** | — | SSH public key (content of `~/.ssh/id_rsa.pub`) |
| `vmSize` | No | `Standard_D2s_v5` | VM SKU |
| `keyVaultAdminObjectId` | **Yes** | — | AAD object ID for Key Vault access |
| `allowedSshSourceAddress` | No | `Deny` | Source IP/CIDR allowed for SSH, or `Deny` |
| `deploymentTimestamp` | No | `utcNow()` | Auto-generated; ensures a unique Key Vault name per deployment |

## Deployment

### Azure CLI

```bash
# 1. Create a resource group
az group create --name ade-lab-rg --location eastus

# 2. Obtain your current object ID
OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

# 3. Deploy
az deployment group create \
  --resource-group ade-lab-rg \
  --template-file main.bicep \
  --parameters prefix=adelab \
               adminUsername=labadmin \
               adminSshPublicKey="$(cat ~/.ssh/id_rsa.pub)" \
               keyVaultAdminObjectId="$OBJECT_ID" \
               allowedSshSourceAddress="$(curl -s ifconfig.me)/32"
```

### PowerShell

```powershell
$rg = 'ade-lab-rg'
New-AzResourceGroup -Name $rg -Location 'eastus'

$objectId = (Get-AzADUser -SignedIn).Id
$sshKey   = Get-Content ~/.ssh/id_rsa.pub -Raw

New-AzResourceGroupDeployment `
  -ResourceGroupName $rg `
  -TemplateFile ./main.bicep `
  -prefix 'adelab' `
  -adminUsername 'labadmin' `
  -adminSshPublicKey $sshKey `
  -keyVaultAdminObjectId $objectId `
  -allowedSshSourceAddress "$(Invoke-RestMethod ifconfig.me)/32"
```

## Validate ADE is enabled

```bash
az vm encryption show \
  --resource-group ade-lab-rg \
  --name adelab-lnx-vm \
  --query "disks[*].{name:name,encryptionState:encryptionState}"
```

## Next steps

Once the VM is deployed and ADE is confirmed active, proceed to the migration scripts:

- **PowerShell**: [`/scripts/powershell/03-Migrate-ADE-to-EAH.ps1`](../../scripts/powershell/03-Migrate-ADE-to-EAH.ps1)
- **CLI**: [`/scripts/cli/03-migrate-ade-to-eah.sh`](../../scripts/cli/03-migrate-ade-to-eah.sh)
