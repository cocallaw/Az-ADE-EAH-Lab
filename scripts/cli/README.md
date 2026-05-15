# CLI Scripts – ADE to Encryption at Host Migration

These Bash scripts guide you through every step of migrating a VM from **Azure Disk Encryption (ADE)** to **Encryption at Host (EaH)** using the Azure CLI.

## Scripts

| Script | Purpose |
|--------|---------|
| [`01-register-eah-feature.sh`](01-register-eah-feature.sh) | One-time subscription prerequisite – registers the `EncryptionAtHost` feature |
| [`02-validate-ade.sh`](02-validate-ade.sh) | Confirms ADE is active before migration |
| [`03-migrate-ade-to-eah.sh`](03-migrate-ade-to-eah.sh) | Full migration: disables ADE, copies disks via Upload+azcopy, creates new VM with EaH |
| [`03b-migrate-linux-os-disk.sh`](03b-migrate-linux-os-disk.sh) | Linux OS disk path: creates fresh VM with EaH, migrates data disks only |
| [`04-validate-eah.sh`](04-validate-eah.sh) | Confirms EaH is active and ADE is fully removed after migration |
| [`05-enforce-eah-policy.sh`](05-enforce-eah-policy.sh) | Assigns Azure Policy to audit or deny VMs without Encryption at Host |

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

### Step 3b – Linux OS Disk Migration (alternative path)

If the migration script detects a Linux VM with an ADE-encrypted OS disk, it exits and directs you to use the alternative path. ADE cannot be disabled on a Linux OS disk, so a fresh VM must be created:

```bash
bash 03b-migrate-linux-os-disk.sh ade-lab-rg adelab-lnx-vm ~/.ssh/id_rsa.pub
```

This script:
1. Creates a **new** Linux VM from a marketplace image with Encryption at Host enabled
2. Copies data disks via Upload+AzCopy (stripping UDE metadata)
3. Attaches copied data disks to the new VM
4. Provides a post-migration checklist for OS reconfiguration

To specify a custom image or new VM name:

```bash
bash 03b-migrate-linux-os-disk.sh ade-lab-rg adelab-lnx-vm ~/.ssh/id_rsa.pub "my-new-vm" "Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest"
```

> ⚠️ **Important:** The new VM has a fresh OS. Application packages, configs, cron jobs, and systemd units must be reinstalled/restored manually. The script provides a detailed checklist at the end.

---

### Step 4 – Validate Encryption at Host is active

```bash
bash 04-validate-eah.sh ade-lab-rg adelab-win-vm
```

Expected output: `PASSED: VM is fully migrated to Encryption at Host.`

---

### Step 5 – Enforce Encryption at Host via Azure Policy

After migration, assign the built-in Azure Policy to audit (and eventually deny) VMs that don't have Encryption at Host enabled:

```bash
bash 05-enforce-eah-policy.sh
```

By default the policy is assigned in **Audit** mode. Non-compliant VMs are flagged but not blocked. The script triggers a compliance scan and lists any non-compliant resources.

To switch to **Deny** mode (blocks creation of VMs without EaH):

```bash
POLICY_EFFECT=Deny bash 05-enforce-eah-policy.sh
```

To scope the policy to a specific resource group:

```bash
SCOPE="/subscriptions/<sub-id>/resourceGroups/ade-lab-rg" bash 05-enforce-eah-policy.sh
```

To skip waiting for the compliance scan:

```bash
SKIP_SCAN=1 bash 05-enforce-eah-policy.sh
```

To re-check compliance at any time:

```bash
az policy state list \
  --policy-assignment 'enforce-eah-audit' \
  --filter 'isCompliant eq false' \
  --query '[].{VM:resourceId, State:complianceState}'
```

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
