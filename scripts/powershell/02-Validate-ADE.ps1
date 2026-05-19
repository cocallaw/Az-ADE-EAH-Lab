#Requires -Modules Az.Compute

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
Write-Host "=== ADE Validation: $VMName ===" -ForegroundColor Cyan

# ── Retrieve VM ──────────────────────────────────────────────────────────────

try {
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
} catch {
    $isNotFound = $false

    # Az module wraps REST errors in CloudException with a structured Body.Code
    $cloudEx = $_.Exception
    while ($cloudEx -and -not ($cloudEx.PSObject.Properties['Body'])) {
        $cloudEx = $cloudEx.InnerException
    }
    if ($cloudEx -and $cloudEx.Body.Code -eq 'ResourceNotFound') {
        $isNotFound = $true
    }

    # Fallback: check the PowerShell error ID for the specific not-found category
    if (-not $isNotFound -and $_.FullyQualifiedErrorId -match 'ResourceNotFound') {
        $isNotFound = $true
    }

    if ($isNotFound) {
        Write-Host "ERROR: VM '$VMName' was not found in resource group '$ResourceGroupName'." -ForegroundColor Red
        Write-Host "Please verify the VM name and resource group, then try again." -ForegroundColor Yellow
        exit 1
    }
    throw
}

# ── Extension status ─────────────────────────────────────────────────────────
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

    # In-VM validation via Run Command
    Write-Host ""
    Write-Host "── In-VM encryption verification (via Invoke-AzVMRunCommand) ──" -ForegroundColor Cyan
    try {
        if ($osType -eq 'Windows') {
            Write-Host "Running manage-bde -status inside the VM..."
            $rcResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName `
                -CommandId 'RunPowerShellScript' -ScriptString 'manage-bde -status' -ErrorAction Stop
        } else {
            Write-Host "Running lsblk -f inside the VM..."
            $rcResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName `
                -CommandId 'RunShellScript' -ScriptString 'lsblk -f && echo "---" && ls /dev/mapper/ 2>/dev/null' -ErrorAction Stop
        }
        $rcOutput = $rcResult.Value | ForEach-Object { $_.Message } | Out-String
        Write-Host $rcOutput
    } catch {
        Write-Host "[Run Command failed – VM agent may not be ready: $_]" -ForegroundColor Yellow
    }
    Write-Host ""

    Write-Host "You can now proceed to 03-Migrate-ADE-to-EAH.ps1"
    exit 0
} else {
    Write-Host "RESULT: One or more disks are NOT fully encrypted. Review the output above." -ForegroundColor Red
    exit 1
}
