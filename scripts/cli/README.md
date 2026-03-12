# CLI Scripts – ADE to Encryption at Host Migration

These Bash scripts guide you through every step of migrating a VM from **Azure Disk Encryption (ADE)** to **Encryption at Host (EaH)** using the Azure CLI.

## Scripts

| Script | Purpose |
|--------|---------|
| [`01-register-eah-feature.sh`](01-register-eah-feature.sh) | One-time subscription prerequisite – registers the `EncryptionAtHost` feature |
| [`02-validate-ade.sh`](02-validate-ade.sh) | Confirms ADE is active before migration |
| [`03-migrate-ade-to-eah.sh`](03-migrate-ade-to-eah.sh) | Full migration: disables ADE, copies disks via Upload+azcopy, creates new VM with EaH |
| [`04-validate-eah.sh`](04-validate-eah.sh) | Confirms EaH is active and ADE is fully removed after migration |

## Prerequisites

```bash
# Install Azure CLI (if not already installed)
# https://learn.microsoft.com/en-us/cli/azure/install-azure-cli

# jq is required (used for JSON parsing in the migration scripts)
# Install: https://jqlang.github.io/jq/download/
jq --version

# Sign in
az login

# (Optional) Select subscription
az account set --subscription "<YOUR-SUBSCRIPTION-ID>"

# Make scripts executable
chmod +x scripts/cli/*.sh
```

## Step-by-step walkthrough

### Step 1 – Register the EncryptionAtHost feature (once per subscription)

```bash
bash 01-register-eah-feature.sh
```

To target a specific subscription:

```bash
bash 01-register-eah-feature.sh "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

Wait for output: `EncryptionAtHost feature is now Registered.`

---

### Step 2 – Validate ADE is enabled on the lab VM

```bash
bash 02-validate-ade.sh ade-lab-rg adelab-win-vm
# or for Linux:
bash 02-validate-ade.sh ade-lab-rg adelab-lnx-vm
```

Expected output: `RESULT: ADE is active and all disks are encrypted.`

---

### Step 3 – Migrate from ADE to Encryption at Host

```bash
bash 03-migrate-ade-to-eah.sh ade-lab-rg adelab-win-vm
```

To preview without applying any changes (dry-run):

```bash
DRY_RUN=1 bash 03-migrate-ade-to-eah.sh ade-lab-rg adelab-win-vm
```

The script will:
1. Verify the `EncryptionAtHost` feature is `Registered`
2. Verify `azcopy` v10+ is installed and in `PATH`
3. Confirm ADE encryption status and capture VM configuration
4. Disable ADE (`az vm encryption disable`) and wait for OS-level decryption to complete
5. Deallocate the VM (`az vm deallocate`)
6. Create **new** managed disks via Upload + azcopy (strips the UDE metadata flag)
7. Delete the original VM resource to release NICs (disks are preserved)
8. Create a **new** VM (`<VM-NAME>-eah`) with Encryption at Host (`--encryption-at-host true`), attaching the new disks and original NICs
9. Start the new VM and verify Encryption at Host is enabled

> ⏱️ The full migration typically takes **30–60 minutes**, most of which is the disk copy and ADE decryption steps.
>
> **Note:** The original VM is removed and a new VM is created. Original disks are preserved as unattached managed disks until you manually clean them up.

---

### Step 4 – Validate Encryption at Host is active

```bash
bash 04-validate-eah.sh ade-lab-rg adelab-win-vm
```

Expected output: `PASSED: VM is fully migrated to Encryption at Host.`

---

## Optional subscription parameter

All scripts accept an optional third argument for the subscription ID:

```bash
bash 03-migrate-ade-to-eah.sh ade-lab-rg adelab-win-vm "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

---

## References

- [Migrate from ADE to Encryption at Host](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate)
- [az vm encryption disable](https://learn.microsoft.com/en-us/cli/azure/vm/encryption#az-vm-encryption-disable)
- [az vm create](https://learn.microsoft.com/en-us/cli/azure/vm#az-vm-create)
- [AzCopy v10](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10)
