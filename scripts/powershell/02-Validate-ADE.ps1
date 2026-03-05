<#
.SYNOPSIS
    Validates that Azure Disk Encryption (ADE) is enabled on a VM.

.DESCRIPTION
    Checks the ADE extension status and the encryption state of all disks
    attached to a VM.  Outputs a colour-coded summary and exits with code 0
    when all disks are encrypted, or 1 when any disk is unencrypted.

.PARAMETER ResourceGroupName
    Name of the resource group containing the VM.

.PARAMETER VMName
    Name of the virtual machine to inspect.

.PARAMETER SubscriptionId
    (Optional) Target subscription. Defaults to the current Az context.

.EXAMPLE
    .\02-Validate-ADE.ps1 -ResourceGroupName "ade-lab-rg" -VMName "adelab-win-vm"

.NOTES
    Requires: Az.Compute
    Reference: https://learn.microsoft.com/en-us/azure/virtual-machines/windows/disk-encryption-windows
#>

[CmdletBinding()]
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

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

Write-Host ""
Write-Host "=== ADE Validation: $VMName ===" -ForegroundColor Cyan

# ── Extension status ─────────────────────────────────────────────────────────

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
$osType = $vm.StorageProfile.OsDisk.OsType

$extName = if ($osType -eq 'Windows') { 'AzureDiskEncryption' } else { 'AzureDiskEncryptionForLinux' }
$ext = $vm.Extensions | Where-Object { $_.Name -eq $extName }

if (-not $ext) {
    Write-Warning "ADE extension '$extName' was NOT found on $VMName."
} else {
    $provisioningState = $ext.ProvisioningState
    $color = if ($provisioningState -eq 'Succeeded') { 'Green' } else { 'Red' }
    Write-Host "ADE extension ($extName): $provisioningState" -ForegroundColor $color
}

# ── Disk encryption status ───────────────────────────────────────────────────

$status = Get-AzVMDiskEncryptionStatus -ResourceGroupName $ResourceGroupName -VMName $VMName

Write-Host ""
Write-Host "Disk encryption status:"

$allEncrypted = $true

if ($status.OsVolumeEncrypted -ne 'Encrypted') {
    Write-Host "  OS Disk  : $($status.OsVolumeEncrypted)" -ForegroundColor Red
    $allEncrypted = $false
} else {
    Write-Host "  OS Disk  : $($status.OsVolumeEncrypted)" -ForegroundColor Green
}

if ($status.DataVolumesEncrypted -ne 'Encrypted') {
    Write-Host "  Data Disk: $($status.DataVolumesEncrypted)" -ForegroundColor Yellow
    # Data disks may legitimately show NotMounted when there are no data disks
    if ($status.DataVolumesEncrypted -ne 'NotMounted') {
        $allEncrypted = $false
    }
} else {
    Write-Host "  Data Disk: $($status.DataVolumesEncrypted)" -ForegroundColor Green
}

Write-Host ""
if ($allEncrypted) {
    Write-Host "RESULT: ADE is active and all disks are encrypted." -ForegroundColor Green
    Write-Host "You can now proceed to 03-Migrate-ADE-to-EAH.ps1"
    exit 0
} else {
    Write-Host "RESULT: One or more disks are NOT fully encrypted. Review the output above." -ForegroundColor Red
    exit 1
}
