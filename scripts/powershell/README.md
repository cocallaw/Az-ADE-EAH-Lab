# PowerShell Scripts – ADE to Encryption at Host Migration

These scripts guide you through every step of migrating a VM from **Azure Disk Encryption (ADE)** to **Encryption at Host (EaH)**.

## Scripts

| Script | Purpose |
|--------|---------|
| [`01-Register-EAH-Feature.ps1`](01-Register-EAH-Feature.ps1) | One-time subscription prerequisite – registers the `EncryptionAtHost` feature |
| [`02-Validate-ADE.ps1`](02-Validate-ADE.ps1) | Confirms ADE is active before migration |
| [`03-Migrate-ADE-to-EAH.ps1`](03-Migrate-ADE-to-EAH.ps1) | Full migration: disables ADE, copies disks via Upload+AzCopy, creates new VM with EaH |
| [`04-Validate-EAH.ps1`](04-Validate-EAH.ps1) | Confirms EaH is active and ADE is fully removed after migration |

## Prerequisites

```powershell
# Install / update the Az module if needed
Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force

# Sign in
Connect-AzAccount

# (Optional) Select subscription
Set-AzContext -SubscriptionId "<YOUR-SUBSCRIPTION-ID>"
```

## Step-by-step walkthrough

### Step 1 – Register the EncryptionAtHost feature (once per subscription)

```powershell
.\01-Register-EAH-Feature.ps1
```

Wait for output: `EncryptionAtHost feature is now Registered.`

To target a specific subscription:

```powershell
.\01-Register-EAH-Feature.ps1 -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

---

### Step 2 – Validate ADE is enabled on the lab VM

```powershell
.\02-Validate-ADE.ps1 -ResourceGroupName "ade-lab-rg" -VMName "adelab-win-vm"
```

Expected output: `RESULT: ADE is active and all disks are encrypted.`

---

### Step 3 – Migrate from ADE to Encryption at Host

```powershell
.\03-Migrate-ADE-to-EAH.ps1 -ResourceGroupName "ade-lab-rg" -VMName "adelab-win-vm"
```

To preview changes without applying them:

```powershell
.\03-Migrate-ADE-to-EAH.ps1 -ResourceGroupName "ade-lab-rg" -VMName "adelab-win-vm" -WhatIf
```

The script will:
1. Verify the `EncryptionAtHost` feature is `Registered`
2. Verify `azcopy` v10+ is installed and in `PATH`
3. Confirm ADE encryption status and capture VM configuration
4. Disable ADE (`Disable-AzVMDiskEncryption`) and wait for OS-level decryption to complete
5. Deallocate the VM
6. Create **new** managed disks via Upload + AzCopy (strips the UDE metadata flag)
7. Delete the original VM resource to release NICs (disks are preserved)
8. Create a **new** VM (`<VMName>-eah`) with Encryption at Host, attaching the new disks and original NICs
9. Start the new VM and verify Encryption at Host is enabled

> ⏱️ The full migration typically takes **30–60 minutes**, most of which is the disk copy and ADE decryption steps.
>
> **Note:** The original VM is removed and a new VM is created. Original disks are preserved as unattached managed disks until you manually clean them up.

---

### Step 4 – Validate Encryption at Host is active

```powershell
.\04-Validate-EAH.ps1 -ResourceGroupName "ade-lab-rg" -VMName "adelab-win-vm"
```

Expected output: `PASSED: VM is fully migrated to Encryption at Host.`

---

## Linux VMs

The same scripts work for Linux VMs. Replace the VM name accordingly:

```powershell
.\02-Validate-ADE.ps1    -ResourceGroupName "ade-lab-rg" -VMName "adelab-lnx-vm"
.\03-Migrate-ADE-to-EAH.ps1 -ResourceGroupName "ade-lab-rg" -VMName "adelab-lnx-vm"
.\04-Validate-EAH.ps1    -ResourceGroupName "ade-lab-rg" -VMName "adelab-lnx-vm"
```

---

## References

- [Migrate from ADE to Encryption at Host](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate)
- [Disable-AzVMDiskEncryption](https://learn.microsoft.com/en-us/powershell/module/az.compute/disable-azvmdiskencryption)
- [New-AzVM](https://learn.microsoft.com/en-us/powershell/module/az.compute/new-azvm)
- [AzCopy v10](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10)
