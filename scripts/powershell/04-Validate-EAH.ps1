#Requires -Modules Az.Compute

<#
.SYNOPSIS
    Validates that Encryption at Host (EaH) is enabled on a VM and ADE is removed.

.DESCRIPTION
    Confirms the post-migration state:
      • Encryption at Host is enabled on the VM security profile.
      • The ADE VM extension is absent (or in a disabled state).
      • No disks report ADE encryption status.

.PARAMETER ResourceGroupName
    Name of the resource group containing the VM.

.PARAMETER VMName
    Name of the virtual machine to inspect.

.PARAMETER SubscriptionId
    (Optional) Target subscription. Defaults to the current Az context.

.EXAMPLE
    .\04-Validate-EAH.ps1 -ResourceGroupName "ade-lab-rg" -VMName "adelab-win-vm"

.NOTES
    Requires: Az.Compute
    Reference: https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

Write-Host ""
Write-Host "=== Encryption at Host Validation: $VMName ===" -ForegroundColor Cyan

$allPassed = $true

# ── Check 1: EncryptionAtHost on VM security profile ─────────────────────────

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
$eahEnabled = $vm.SecurityProfile.EncryptionAtHost -eq $true

if ($eahEnabled) {
    Write-Host "[PASS] Encryption at Host is enabled on the VM security profile." -ForegroundColor Green
} else {
    Write-Host "[FAIL] Encryption at Host is NOT enabled on the VM security profile." -ForegroundColor Red
    $allPassed = $false
}

# ── Check 2: ADE extension is absent ─────────────────────────────────────────

$osType = $vm.StorageProfile.OsDisk.OsType
$extName = if ($osType -eq 'Windows') { 'AzureDiskEncryption' } else { 'AzureDiskEncryptionForLinux' }
$adeExt = $vm.Extensions | Where-Object { $_.Name -eq $extName }

if (-not $adeExt) {
    Write-Host "[PASS] ADE extension ($extName) is not present." -ForegroundColor Green
} else {
    # Extension may remain in a disabled/uninstalled state after decryption
    Write-Host "[INFO] ADE extension ($extName) is still listed (ProvisioningState: $($adeExt.ProvisioningState))." -ForegroundColor Yellow
    Write-Host "       This is expected if decryption has completed. Verify disk encryption status below."
}

# ── Check 3: Disk encryption status ──────────────────────────────────────────

$encStatus = Get-AzVMDiskEncryptionStatus -ResourceGroupName $ResourceGroupName -VMName $VMName

$osEncrypted   = $encStatus.OsVolumeEncrypted
$dataEncrypted = $encStatus.DataVolumesEncrypted

if ($osEncrypted -in 'NotEncrypted', 'NoDiskFound') {
    Write-Host "[PASS] OS disk ADE encryption: $osEncrypted" -ForegroundColor Green
} else {
    Write-Host "[FAIL] OS disk still reports ADE encryption: $osEncrypted" -ForegroundColor Red
    $allPassed = $false
}

if ($dataEncrypted -in 'NotEncrypted', 'NoDiskFound', 'NotMounted') {
    Write-Host "[PASS] Data disk ADE encryption: $dataEncrypted" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Data disk(s) still report ADE encryption: $dataEncrypted" -ForegroundColor Red
    $allPassed = $false
}

# ── Check 4: Individual managed disk encryption settings ─────────────────────

Write-Host ""
Write-Host "Managed disk encryption settings:"

$allDisks = @()
$allDisks += $vm.StorageProfile.OsDisk
$allDisks += $vm.StorageProfile.DataDisks

foreach ($disk in $allDisks) {
    $managedDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $disk.Name -ErrorAction SilentlyContinue
    if ($managedDisk) {
        $enc = $managedDisk.Encryption
        Write-Host "  Disk: $($disk.Name)"
        Write-Host "    Encryption type : $($enc.Type)"
    }
}

# ── Result ────────────────────────────────────────────────────────────────────

Write-Host ""
if ($allPassed) {
    Write-Host "============================================" -ForegroundColor Green
    Write-Host " PASSED: $VMName is fully migrated to" -ForegroundColor Green
    Write-Host "         Encryption at Host." -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    exit 0
} else {
    Write-Host "============================================" -ForegroundColor Red
    Write-Host " FAILED: One or more checks did not pass." -ForegroundColor Red
    Write-Host " Review output above and re-run migration." -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    exit 1
}
