# Copilot Instructions

## Project Overview

This is a hands-on lab for migrating Azure VMs from **Azure Disk Encryption (ADE)** to **Encryption at Host (EaH)**. It provides IaC templates (Bicep and Terraform) to deploy lab VMs with ADE enabled, plus migration scripts (PowerShell and Azure CLI/Bash) that perform the full ADE→EaH migration.

The migration creates a **new VM** — it copies disks via Upload+AzCopy (stripping the UDE flag that prevents enabling EaH on ADE-encrypted disks) and builds a new VM with Encryption at Host enabled.

## Architecture

The repo is organized around a 2×2 matrix: **IaC tool** (Bicep or Terraform) × **scripting tool** (PowerShell or CLI). All four paths deploy the same resource stack and follow the same 4-step lifecycle:

1. Register the EncryptionAtHost feature (`01-*`)
2. Validate ADE is enabled (`02-*`)
3. Migrate ADE → EaH (`03-*`)
4. Validate EaH is active (`04-*`)

Each IaC template deploys: Resource Group → Key Vault + KEK key → NSG → VNet/Subnet → Public IP → NIC → VM → ADE extension. Windows and Linux variants are separate directories with parallel structure.

## Build & Validation

### Bicep

```bash
# Lint both templates
az bicep lint --file bicep/windows/main.bicep
az bicep lint --file bicep/linux/main.bicep

# Compile to ARM JSON
az bicep build --file bicep/windows/main.bicep --outfile bicep/windows/azuredeploy.json
az bicep build --file bicep/linux/main.bicep --outfile bicep/linux/azuredeploy.json
```

The `validate-bicep.yml` workflow runs lint + build on push/PR to `main` for `bicep/**/*.bicep` changes. The `generate-arm-templates.yml` workflow auto-compiles Bicep → `azuredeploy.json` and opens a PR.

### Terraform

```bash
cd terraform/windows  # or terraform/linux
terraform init
terraform validate
terraform plan -var-file="terraform.tfvars"
```

No CI workflow exists for Terraform validation.

## Conventions

### Bicep

- Single `main.bicep` per variant (no modules) — flat structure
- Parameters and variables use **camelCase**: `adminUsername`, `kvName`, `vmName`
- Resource symbolic names are short camelCase: `keyVault`, `adeKey`, `nsg`, `vnet`, `publicIp`, `nic`, `vm`, `adeExtension`
- Outputs use camelCase: `vmId`, `vmName`, `keyVaultUri`, `publicIpAddress`
- `parameters.json` uses Key Vault reference for secrets (Windows `adminPassword`)
- Compiled `azuredeploy.json` is committed and kept in sync via CI — do not edit by hand

### Terraform

- Flat root modules (no child modules): `main.tf`, `variables.tf`, `outputs.tf`
- Variables and outputs use **snake_case**: `resource_group_name`, `admin_username`
- Resource labels are short lowercase: `rg`, `kv`, `ade_key`, `nsg`, `vnet`, `pip`, `nic`, `vm`, `ade`
- Provider `azurerm ~> 3.90` with OIDC-compatible config
- `terraform.tfvars.example` documents required values — users copy to `terraform.tfvars`

### PowerShell Scripts (`scripts/powershell/`)

- **PascalCase** with numbered prefix: `01-Register-EAH-Feature.ps1`
- Use `[CmdletBinding()]` with `Mandatory` parameters and `ValidateRange`
- Migration script supports `-WhatIf` via `SupportsShouldProcess`
- Error handling: `Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'`
- Helper functions in migration script: `Write-Step`, `Format-Elapsed`, `Copy-DiskViaUpload`

### CLI/Bash Scripts (`scripts/cli/`)

- **kebab-case** with numbered prefix: `01-register-eah-feature.sh`
- Positional arguments for required params; environment variables for optional config (`DRY_RUN`, `SAS_EXPIRY_HOURS`)
- Error handling: `set -euo pipefail`
- Helper functions in migration script: `step`, `run`, `format_elapsed`, `copy_disk_via_upload`

### Windows vs Linux Differences

- Windows: RDP (port 3389), `adminPassword`, `AzureDiskEncryption` extension, `VolumeType: 'All'`
- Linux: SSH (port 22), `adminSshPublicKey`, `AzureDiskEncryptionForLinux` extension
- Linux OS disk encryption cannot be disabled by ADE — the migration script detects this and exits with guidance

### GitHub Actions

- All deploy workflows are `workflow_dispatch` (manual trigger)
- OIDC authentication via `azure/login@v2` — no stored credentials
- Bicep deploys use `azure/arm-deploy@v2`; Terraform uses `hashicorp/setup-terraform@v3` with `ARM_USE_OIDC=true`
- Required secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `VM_ADMIN_PASSWORD` (Windows), `VM_SSH_PUBLIC_KEY` (Linux)
