<#
.SYNOPSIS
    Migrates a VM from Azure Disk Encryption (ADE) to Encryption at Host (EaH).

.DESCRIPTION
    Performs the full migration sequence documented at:
    https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate

    Steps executed:
      1. Verify the EncryptionAtHost subscription feature is Registered.
      2. Confirm ADE is currently active on the VM.
      3. Disable ADE (remove the ADE extension and decrypt all disks).
      4. Deallocate the VM.
      5. Enable Encryption at Host on the VM.
      6. Start the VM.

    The script is idempotent: if a step is already complete it is skipped.

.PARAMETER ResourceGroupName
    Name of the resource group containing the VM.

.PARAMETER VMName
    Name of the virtual machine to migrate.

.PARAMETER SubscriptionId
    (Optional) Target subscription. Defaults to the current Az context.

.PARAMETER WhatIf
    Dry-run mode – shows what would happen without making any changes.

.EXAMPLE
    .\03-Migrate-ADE-to-EAH.ps1 -ResourceGroupName "ade-lab-rg" -VMName "adelab-win-vm"

.EXAMPLE
    .\03-Migrate-ADE-to-EAH.ps1 -ResourceGroupName "ade-lab-rg" -VMName "adelab-lnx-vm" -WhatIf

.NOTES
    Requires: Az.Accounts, Az.Compute
    Reference: https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "──────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "──────────────────────────────────────────" -ForegroundColor DarkGray
}

# ── Context ──────────────────────────────────────────────────────────────────

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$ctx = Get-AzContext
Write-Host "Active subscription : $($ctx.Subscription.Name) [$($ctx.Subscription.Id)]" -ForegroundColor Cyan
Write-Host "Resource Group      : $ResourceGroupName"
Write-Host "VM Name             : $VMName"

# ── Step 1: Verify EncryptionAtHost feature ───────────────────────────────────

Write-Step "Step 1 – Verify EncryptionAtHost feature registration"

$feature = Get-AzProviderFeature -FeatureName 'EncryptionAtHost' -ProviderNamespace 'Microsoft.Compute'
if ($feature.RegistrationState -ne 'Registered') {
    Write-Error ("EncryptionAtHost is not Registered on subscription '$($ctx.Subscription.Id)'. " +
        "Run 01-Register-EAH-Feature.ps1 first and wait for registration to complete.")
    exit 1
}
Write-Host "EncryptionAtHost feature: Registered" -ForegroundColor Green

# ── Step 2: Confirm ADE is active ────────────────────────────────────────────

Write-Step "Step 2 – Confirm ADE is currently active"

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
$osType = $vm.StorageProfile.OsDisk.OsType
$extName = if ($osType -eq 'Windows') { 'AzureDiskEncryption' } else { 'AzureDiskEncryptionForLinux' }

$adeStatus = Get-AzVMDiskEncryptionStatus -ResourceGroupName $ResourceGroupName -VMName $VMName
$adeActive = ($adeStatus.OsVolumeEncrypted -eq 'Encrypted') -or ($adeStatus.DataVolumesEncrypted -eq 'Encrypted')

if (-not $adeActive) {
    Write-Warning "ADE does not appear to be active on $VMName (OS: $($adeStatus.OsVolumeEncrypted), Data: $($adeStatus.DataVolumesEncrypted))."
    Write-Warning "Proceeding anyway – the VM may already be partially migrated."
} else {
    Write-Host "ADE is active. OS: $($adeStatus.OsVolumeEncrypted) | Data: $($adeStatus.DataVolumesEncrypted)" -ForegroundColor Green
}

# ── Step 3: Disable ADE ───────────────────────────────────────────────────────

Write-Step "Step 3 – Disable ADE (decrypt all disks)"

if ($adeActive) {
    if ($PSCmdlet.ShouldProcess("$VMName", "Disable-AzVMDiskEncryption -VolumeType All")) {
        Write-Host "Disabling ADE on $VMName (VolumeType: All). This may take several minutes..."
        Disable-AzVMDiskEncryption -ResourceGroupName $ResourceGroupName -VMName $VMName -VolumeType 'All' -Force | Out-Null
        Write-Host "ADE disabled." -ForegroundColor Green
    }
} else {
    Write-Host "Skipping – ADE is not active." -ForegroundColor Yellow
}

# ── Step 4: Deallocate the VM ─────────────────────────────────────────────────

Write-Step "Step 4 – Deallocate the VM"

$vmStatus = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status).Statuses |
    Where-Object { $_.Code -like 'PowerState/*' }

if ($vmStatus.Code -ne 'PowerState/deallocated') {
    if ($PSCmdlet.ShouldProcess("$VMName", "Stop-AzVM (deallocate)")) {
        Write-Host "Stopping and deallocating $VMName..."
        Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force | Out-Null
        Write-Host "VM deallocated." -ForegroundColor Green
    }
} else {
    Write-Host "VM is already deallocated." -ForegroundColor Yellow
}

# ── Step 5: Enable Encryption at Host ────────────────────────────────────────

Write-Step "Step 5 – Enable Encryption at Host"

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName

if ($vm.SecurityProfile.EncryptionAtHost -eq $true) {
    Write-Host "Encryption at Host is already enabled on $VMName." -ForegroundColor Yellow
} else {
    if ($PSCmdlet.ShouldProcess("$VMName", "Update-AzVM -SecurityProfile EncryptionAtHost=true")) {
        Write-Host "Enabling Encryption at Host on $VMName..."
        $vm.SecurityProfile = if ($vm.SecurityProfile) { $vm.SecurityProfile } else {
            New-Object Microsoft.Azure.Management.Compute.Models.SecurityProfile
        }
        $vm.SecurityProfile.EncryptionAtHost = $true
        Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm | Out-Null
        Write-Host "Encryption at Host enabled." -ForegroundColor Green
    }
}

# ── Step 6: Start the VM ──────────────────────────────────────────────────────

Write-Step "Step 6 – Start the VM"

if ($PSCmdlet.ShouldProcess("$VMName", "Start-AzVM")) {
    Write-Host "Starting $VMName..."
    Start-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName | Out-Null
    Write-Host "VM started." -ForegroundColor Green
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " Migration complete!" -ForegroundColor Green
Write-Host " VM '$VMName' is now using Encryption at Host." -ForegroundColor Green
Write-Host " Run 04-Validate-EAH.ps1 to confirm." -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
