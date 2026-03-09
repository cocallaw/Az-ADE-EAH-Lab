# Lab Walkthrough – Migrate from ADE to Encryption at Host

This guide walks you through deploying a lab VM with **Azure Disk Encryption (ADE)** enabled, then migrating it to **Encryption at Host (EaH)**. Pick the toolchain that matches your environment and follow the steps in order.

> **Reference:** [Migrate from Azure Disk Encryption to Encryption at Host](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate)

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **Azure CLI** 2.50+ *or* **Azure PowerShell** (Az module) 10.0+ | [Install Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) · [Install Az PowerShell](https://learn.microsoft.com/en-us/powershell/azure/install-azure-powershell) |
| **AzCopy v10+** | Required by the migration script to copy disk data. [Download AzCopy](https://aka.ms/downloadazcopy) and ensure it is in `PATH`. |
| **Bicep CLI** 0.20+ *(Bicep path only)* | Bundled with Azure CLI, or `az bicep install` |
| **Terraform** 1.5+ *(Terraform path only)* | [Install Terraform](https://developer.hashicorp.com/terraform/install) |
| **Azure subscription** | Contributor + Key Vault Administrator permissions |
| **EncryptionAtHost feature** | Must be registered on the target subscription (see Step 1) |

---

## Choose Your Path

This lab supports four deployment combinations. Pick **one IaC tool** and **one scripting tool**, then follow every step below using the links for your chosen path.

| | **Bicep** | **Terraform** |
|---|-----------|---------------|
| **PowerShell** | Bicep + PowerShell | Terraform + PowerShell |
| **Azure CLI (Bash)** | Bicep + CLI | Terraform + CLI |

---

## Step 1 – Register the EncryptionAtHost Feature

> This is a **one-time, per-subscription** operation. If you have already registered the feature, skip to Step 2.

<details>
<summary><strong>PowerShell</strong></summary>

Run the registration script:

```powershell
./scripts/powershell/01-Register-EAH-Feature.ps1
```

Or register manually:

```powershell
Register-AzProviderFeature -FeatureName "EncryptionAtHost" -ProviderNamespace "Microsoft.Compute"
# Poll until Registered
Get-AzProviderFeature -FeatureName "EncryptionAtHost" -ProviderNamespace "Microsoft.Compute"
```

📄 [01-Register-EAH-Feature.ps1](scripts/powershell/01-Register-EAH-Feature.ps1)

</details>

<details>
<summary><strong>Azure CLI (Bash)</strong></summary>

Run the registration script:

```bash
bash scripts/cli/01-register-eah-feature.sh
```

Or register manually:

```bash
az feature register --name EncryptionAtHost --namespace Microsoft.Compute
# Poll until state == "Registered"
az feature show --name EncryptionAtHost --namespace Microsoft.Compute --query "properties.state"
# Propagate registration
az provider register --namespace Microsoft.Compute
```

📄 [01-register-eah-feature.sh](scripts/cli/01-register-eah-feature.sh)

</details>

---

## Step 2 – Deploy a Lab VM with ADE Enabled

Deploy a VM that has Azure Disk Encryption already configured. This gives you a realistic starting point for the migration.

### Option A – Deploy with Bicep

**Windows Server 2022:**

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fcocallaw%2FAz-ADE-EAH-Lab%2Frefs%2Fheads%2Fmain%2Fbicep%2Fwindows%2Fazuredeploy.json)

**Ubuntu 22.04 LTS:**

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fcocallaw%2FAz-ADE-EAH-Lab%2Frefs%2Fheads%2Fmain%2Fbicep%2Flinux%2Fazuredeploy.json)

<details>
<summary><strong>Or deploy from the command line</strong></summary>

**Windows (Azure CLI):**

```bash
az group create --name ade-lab-rg --location eastus

OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

az deployment group create \
  --resource-group ade-lab-rg \
  --template-file bicep/windows/main.bicep \
  --parameters prefix=adelab \
               adminUsername=labadmin \
               adminPassword='<SECURE-PASSWORD>' \
               keyVaultAdminObjectId="$OBJECT_ID"
```

**Linux (Azure CLI):**

```bash
az group create --name ade-lab-rg --location eastus

OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

az deployment group create \
  --resource-group ade-lab-rg \
  --template-file bicep/linux/main.bicep \
  --parameters prefix=adelab \
               adminUsername=labadmin \
               adminSshPublicKey="$(cat ~/.ssh/id_rsa.pub)" \
               keyVaultAdminObjectId="$OBJECT_ID"
```

📄 [bicep/windows/](bicep/windows/) · 📄 [bicep/linux/](bicep/linux/)

</details>

### Option B – Deploy with Terraform

<details>
<summary><strong>Windows</strong></summary>

```bash
cd terraform/windows
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform apply
```

📄 [terraform/windows/](terraform/windows/)

</details>

<details>
<summary><strong>Linux</strong></summary>

```bash
cd terraform/linux
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform apply
```

📄 [terraform/linux/](terraform/linux/)

</details>

---

## Step 3 – Validate ADE is Enabled

Before migrating, confirm that Azure Disk Encryption is active on the VM.

<details>
<summary><strong>PowerShell</strong></summary>

```powershell
./scripts/powershell/02-Validate-ADE.ps1 -ResourceGroupName "ade-lab-rg" -VMName "<VM-NAME>"
```

📄 [02-Validate-ADE.ps1](scripts/powershell/02-Validate-ADE.ps1)

</details>

<details>
<summary><strong>Azure CLI (Bash)</strong></summary>

```bash
bash scripts/cli/02-validate-ade.sh ade-lab-rg <VM-NAME>
```

📄 [02-validate-ade.sh](scripts/cli/02-validate-ade.sh)

</details>

**Expected output:** OS disk and data disks should show **Encrypted**.

> **Default VM names:** `adelab-win-vm` (Windows) or `adelab-lnx-vm` (Linux) when using the default `adelab` prefix.

---

## Step 4 – Migrate from ADE to Encryption at Host

> **Important:** Azure does not allow enabling Encryption at Host on a VM whose disks carry the UDE (Unified Data Encryption) flag set by ADE — even after ADE has been disabled. The migration scripts therefore create new managed disks via the Upload+AzCopy method (which produces clean disk objects with no ADE metadata) and build a new VM from those disks with Encryption at Host enabled. **AzCopy v10+ must be installed and in `PATH` before running the script.**

The script performs the following steps:

1. ✅ Verify the EncryptionAtHost feature is registered
2. ✅ Verify AzCopy is available in `PATH`
3. ✅ Confirm ADE status and capture the full VM configuration (size, location, NICs, disks, HyperV generation)
4. ✅ Disable ADE (Windows: all volumes; Linux: data volumes only), then pause to confirm OS-level decryption is complete
5. ✅ Deallocate the original VM
6. ✅ Copy all disks (OS + data) to new managed disks via Upload+AzCopy — strips the UDE flag
7. ✅ Create a new VM from the new disks with Encryption at Host enabled
8. ✅ Start the new VM
9. ✅ Verify Encryption at Host is active on the new VM
10. 🖨 Print ready-to-run cleanup commands for the original VM, disks, and Key Vault

> **Linux VMs with an ADE-encrypted OS disk:** Disabling ADE on a Linux OS disk is not supported. The script detects this case early and exits with remediation guidance. A new VM with a fresh OS disk must be created manually.

Each step is timed and a full timing summary is printed at the end of the run.

<details>
<summary><strong>PowerShell</strong></summary>

```powershell
./scripts/powershell/03-Migrate-ADE-to-EAH.ps1 `
  -ResourceGroupName "ade-lab-rg" `
  -VMName "<VM-NAME>"
```

The new VM is named `<VM-NAME>-eah` by default. Override with `-NewVMName`:

```powershell
./scripts/powershell/03-Migrate-ADE-to-EAH.ps1 `
  -ResourceGroupName "ade-lab-rg" `
  -VMName "<VM-NAME>" `
  -NewVMName "<NEW-VM-NAME>"
```

**Dry-run** (no changes):

```powershell
./scripts/powershell/03-Migrate-ADE-to-EAH.ps1 `
  -ResourceGroupName "ade-lab-rg" `
  -VMName "<VM-NAME>" `
  -WhatIf
```

📄 [03-Migrate-ADE-to-EAH.ps1](scripts/powershell/03-Migrate-ADE-to-EAH.ps1)

</details>

<details>
<summary><strong>Azure CLI (Bash)</strong></summary>

```bash
bash scripts/cli/03-migrate-ade-to-eah.sh ade-lab-rg <VM-NAME>
```

The new VM is named `<VM-NAME>-eah` by default. Override with a third argument:

```bash
bash scripts/cli/03-migrate-ade-to-eah.sh ade-lab-rg <VM-NAME> <NEW-VM-NAME>
```

**Dry-run** (no changes):

```bash
DRY_RUN=1 bash scripts/cli/03-migrate-ade-to-eah.sh ade-lab-rg <VM-NAME>
```

📄 [03-migrate-ade-to-eah.sh](scripts/cli/03-migrate-ade-to-eah.sh)

</details>

> **⏱ Typical duration:** 30–60 minutes. The disk copy via AzCopy (Step 6) is the longest step and scales with disk size. A timing summary is printed at the end of the run.

> **After the script completes:** The original VM is left deallocated, not deleted. Verify the new VM works correctly before running the cleanup commands printed by the script.

---

## Step 5 – Validate Encryption at Host is Active

After migration, confirm that EaH is enabled on the **new VM** and that ADE is no longer present.

<details>
<summary><strong>PowerShell</strong></summary>

```powershell
./scripts/powershell/04-Validate-EAH.ps1 -ResourceGroupName "ade-lab-rg" -VMName "<NEW-VM-NAME>"
```

📄 [04-Validate-EAH.ps1](scripts/powershell/04-Validate-EAH.ps1)

</details>

<details>
<summary><strong>Azure CLI (Bash)</strong></summary>

```bash
bash scripts/cli/04-validate-eah.sh ade-lab-rg <NEW-VM-NAME>
```

📄 [04-validate-eah.sh](scripts/cli/04-validate-eah.sh)

</details>

**Expected results:**

| Check | Expected |
|-------|----------|
| `securityProfile.encryptionAtHost` | `true` |
| ADE extension | Absent or disabled |
| OS / data disk encryption state | Platform-managed (EaH) |

---

## Cleanup

The migration script prints ready-to-run commands at the end of its output for removing the original VM and its disks. Run those first, then delete the resource group to stop all remaining charges:

```bash
az group delete --name ade-lab-rg --yes --no-wait
```

---

## Troubleshooting

| Issue | Resolution |
|-------|-----------|
| `EncryptionAtHost is not Registered` | Run the Step 1 registration script and wait until the state is `Registered` (can take up to 15 minutes). |
| `azcopy` / `azcopy not found` | Install AzCopy v10+ from [aka.ms/downloadazcopy](https://aka.ms/downloadazcopy) and ensure it is available in `PATH` before re-running the script. |
| `KEK_FAILED / RSA 3072 or larger` | Windows Server 2022+ requires a Key Vault key of RSA 3072 or larger. Re-deploy with the latest templates which use RSA 3072. |
| ADE disable takes a long time | Disk decryption is I/O-intensive. Allow up to 30 minutes for large disks. The script pauses and asks you to confirm decryption is complete before continuing. |
| Linux VM with encrypted OS disk | ADE cannot be disabled on a Linux OS disk. The script exits with instructions: create a new Linux VM with EaH enabled, then migrate application data using SCP, rsync, or backup tools. |
| AzCopy fails during disk copy | Check that the SAS URIs haven't expired (`SAS_EXPIRY_HOURS` / `-SasExpiryHours`, default 24 h) and that the source disk is not attached to a running VM. Re-run the script; it will create new SAS URIs. |
| New VM not visible / NIC conflict | The script detaches NICs from the original VM before creating the new one. If the script fails mid-way, manually detach the NIC from the original VM in the portal before re-running. |
| Key Vault soft-delete conflict | If re-deploying to the same resource group, purge or recover the soft-deleted Key Vault first: `az keyvault purge --name <KV-NAME>`. |

---

## Additional Resources

- [Migrate from ADE to Encryption at Host – Microsoft Learn](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate)
- [Encryption at Host overview](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption#encryption-at-host---end-to-end-encryption-for-your-vm-data)
- [Azure Disk Encryption overview](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-overview)
- [Key Vault for Azure Disk Encryption](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-key-vault)
