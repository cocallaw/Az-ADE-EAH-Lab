# Az-ADE-EAH-Lab

> **📘 [Start the Lab Walkthrough →](LAB_WALKTHROUGH.md)** — a single-page, step-by-step guide covering every path (Bicep / Terraform × PowerShell / CLI).

A hands-on lab for walking customers through the process of migrating virtual machines from **Azure Disk Encryption (ADE)** to **Encryption at Host (EaH)**. This lab provides repeatable, on-demand templates and scripts so teams can validate their migration process before applying it to production workloads.

> **Why migrate?**  
> Azure Disk Encryption (ADE) is being retired. Microsoft recommends transitioning to [Encryption at Host](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-overview) as the replacement. For official migration guidance see [Migrate from Azure Disk Encryption to Encryption at Host](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate).

## Deploy to Azure

| Template | Deploy |
|----------|--------|
| Bicep – Windows Server 2022 with ADE | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fcocallaw%2FAz-ADE-EAH-Lab%2Frefs%2Fheads%2Fmain%2Fbicep%2Fwindows%2Fazuredeploy.json) |
| Bicep – Ubuntu 22.04 LTS with ADE | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fcocallaw%2FAz-ADE-EAH-Lab%2Frefs%2Fheads%2Fmain%2Fbicep%2Flinux%2Fazuredeploy.json) |

> **Note:** Deploy to Azure buttons use the compiled ARM JSON templates (`azuredeploy.json`). For Terraform deployments, use the [GitHub Actions workflows](#github-actions-workflows) or deploy locally.

---

## Lab Overview

```
Az-ADE-EAH-Lab/
├── bicep/                  # Bicep IaC templates
│   ├── windows/            #   Windows VM with ADE enabled
│   └── linux/              #   Linux VM with ADE enabled
├── terraform/              # Terraform IaC templates
│   ├── windows/            #   Windows VM with ADE enabled
│   └── linux/              #   Linux VM with ADE enabled
└── scripts/                # Migration scripts
    ├── powershell/         #   Azure PowerShell scripts
    └── cli/                #   Azure CLI (Bash) scripts
```

---

## Migration Flow

```
┌─────────────────────────────────────────────┐
│  STEP 1 – Deploy lab VM (pick one path)     │
│   • Bicep  → bicep/windows  or bicep/linux  │
│   • Terraform → terraform/windows or linux  │
└───────────────────┬─────────────────────────┘
                    │
┌───────────────────▼─────────────────────────┐
│  STEP 2 – Validate ADE is enabled           │
│   • PowerShell: scripts/powershell/         │
│   • CLI:        scripts/cli/                │
└───────────────────┬─────────────────────────┘
                    │
┌───────────────────▼─────────────────────────┐
│  STEP 3 – Migrate from ADE to EaH          │
│   • PowerShell: scripts/powershell/         │
│   • CLI:        scripts/cli/                │
└───────────────────┬─────────────────────────┘
                    │
┌───────────────────▼─────────────────────────┐
│  STEP 4 – Validate EaH is active           │
│   • PowerShell: scripts/powershell/         │
│   • CLI:        scripts/cli/                │
└─────────────────────────────────────────────┘
```

---

## Prerequisites

| Tool | Minimum Version | Notes |
|------|-----------------|-------|
| Azure CLI | 2.50+ | `az --version` |
| Azure PowerShell (Az module) | 10.0+ | `Get-Module Az -ListAvailable` |
| Bicep CLI | 0.20+ | `bicep --version` |
| Terraform | 1.5+ | Only needed for the Terraform path |
| Azure Subscription | — | Owner or Contributor + Key Vault access |

### Required Azure permissions

- **Contributor** on the target Resource Group
- **Key Vault Administrator** (or Key Vault Crypto Officer + Key Vault Secrets Officer) on the Key Vault used for ADE keys
- **Microsoft.Compute/virtualMachines/write** to enable Encryption at Host

### Register the EncryptionAtHost feature (one-time, per subscription)

**PowerShell**
```powershell
Register-AzProviderFeature -FeatureName "EncryptionAtHost" -ProviderNamespace "Microsoft.Compute"
# Wait until ProviderFeature.RegistrationState -eq 'Registered'
Get-AzProviderFeature -FeatureName "EncryptionAtHost" -ProviderNamespace "Microsoft.Compute"
```

**Azure CLI**
```bash
az feature register --name EncryptionAtHost --namespace Microsoft.Compute
# Poll until state == "Registered"
az feature show --name EncryptionAtHost --namespace Microsoft.Compute --query "properties.state"
# Propagate the registration
az provider register --namespace Microsoft.Compute
```

---

## Quick Start

### Option A – Bicep + PowerShell

```powershell
# 1. Deploy a Windows VM with ADE
cd bicep/windows
az deployment group create `
  --resource-group <YOUR-RG> `
  --template-file main.bicep `
  --parameters @parameters.json

# 2. Migrate from ADE to Encryption at Host
cd ../../scripts/powershell
./03-Migrate-ADE-to-EAH.ps1 `
  -ResourceGroupName <YOUR-RG> `
  -VMName <VM-NAME>
```

### Option B – Terraform + CLI

```bash
# 1. Deploy a Linux VM with ADE
cd terraform/linux
terraform init
terraform apply -var-file="terraform.tfvars"

# 2. Migrate from ADE to Encryption at Host
cd ../../scripts/cli
bash 03-migrate-ade-to-eah.sh <RESOURCE-GROUP> <VM-NAME>
```

---

## Contents

| Folder | Description |
|--------|-------------|
| [`bicep/windows`](bicep/windows/README.md) | Bicep template – Windows Server 2022 VM with ADE |
| [`bicep/linux`](bicep/linux/README.md) | Bicep template – Ubuntu 22.04 LTS VM with ADE |
| [`terraform/windows`](terraform/windows/README.md) | Terraform template – Windows Server 2022 VM with ADE |
| [`terraform/linux`](terraform/linux/README.md) | Terraform template – Ubuntu 22.04 LTS VM with ADE |
| [`scripts/powershell`](scripts/powershell/README.md) | PowerShell scripts for ADE setup and EaH migration |
| [`scripts/cli`](scripts/cli/README.md) | Azure CLI (Bash) scripts for ADE setup and EaH migration |

---

## GitHub Actions Workflows

This repository includes four example workflows that deploy the lab VMs via GitHub Actions. Each workflow uses `workflow_dispatch` so you can trigger deployments manually from the **Actions** tab.

| Workflow | Description | Trigger |
|----------|-------------|---------|
| [Validate Bicep](.github/workflows/validate-bicep.yml) | Lint & build both Bicep templates | Push / PR to `main` (bicep changes) |
| [Generate ARM Templates](.github/workflows/generate-arm-templates.yml) | Compile Bicep → `azuredeploy.json` and auto-commit | Push to `main` (bicep changes) |
| [Deploy Bicep – Windows](.github/workflows/deploy-bicep-windows.yml) | Deploy Windows VM with ADE via Bicep | Manual |
| [Deploy Bicep – Linux](.github/workflows/deploy-bicep-linux.yml) | Deploy Linux VM with ADE via Bicep | Manual |
| [Deploy Terraform – Windows](.github/workflows/deploy-terraform-windows.yml) | Deploy Windows VM with ADE via Terraform | Manual |
| [Deploy Terraform – Linux](.github/workflows/deploy-terraform-linux.yml) | Deploy Linux VM with ADE via Terraform | Manual |

### Required secrets

Configure these [repository secrets](https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions) before running any workflow:

| Secret | Description |
|--------|-------------|
| `AZURE_CLIENT_ID` | App registration (service principal) client ID |
| `AZURE_TENANT_ID` | Microsoft Entra ID tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target Azure subscription ID |
| `VM_ADMIN_PASSWORD` | Windows VM admin password (Bicep & Terraform Windows workflows) |
| `VM_SSH_PUBLIC_KEY` | SSH public key content (Bicep & Terraform Linux workflows) |

> **Authentication:** All workflows use [OpenID Connect (OIDC)](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust) for passwordless Azure login. Configure a federated credential on your app registration pointing to this repository.

---

## Cleanup

After completing the lab, delete the resource group to avoid ongoing charges:

```bash
az group delete --name <YOUR-RG> --yes --no-wait
```

---

## References

- [Migrate from Azure Disk Encryption to Encryption at Host](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate)
- [Encryption at Host – End-to-end encryption for VM disks](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption#encryption-at-host---end-to-end-encryption-for-your-vm-data)
- [Azure Disk Encryption overview](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-overview)
- [Key Vault for Azure Disk Encryption](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-key-vault)
