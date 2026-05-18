<#
.SYNOPSIS
    Discovers ADE-encrypted VMs across accessible subscriptions using Azure Resource Graph.

.DESCRIPTION
    Uses Azure Resource Graph to find all VMs with the ADE extension installed,
    identifies VMs already on Encryption at Host, and provides a compliance summary.
    This helps plan ADE-to-EaH migration scope.

.NOTES
    Prerequisites:
      - Az PowerShell module 10.0+
      - Az.ResourceGraph module
      - Logged in: Connect-AzAccount
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure Az.ResourceGraph module is available
if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
    Write-Host "Installing Az.ResourceGraph module..."
    Install-Module -Name Az.ResourceGraph -Scope CurrentUser -Force
}
Import-Module Az.ResourceGraph

Write-Host "=== ADE-Encrypted VMs (via extension detection) ===" -ForegroundColor Cyan
Write-Host ""

$adeQuery = @"
Resources
| where type =~ 'microsoft.compute/virtualmachines/extensions'
| where name in ('AzureDiskEncryption', 'AzureDiskEncryptionForLinux')
| where properties.provisioningState == 'Succeeded'
| extend vmName = tostring(split(id, '/')[8])
| project vmName, resourceGroup, location, subscriptionId, extensionType = name
| order by subscriptionId, resourceGroup
"@

$adeVMs = Search-AzGraph -Query $adeQuery
if ($adeVMs.Count -gt 0) {
    $adeVMs | Format-Table -AutoSize
} else {
    Write-Host "  No ADE-encrypted VMs found." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== VMs Already on Encryption at Host (exclude from migration) ===" -ForegroundColor Cyan
Write-Host ""

$eahQuery = @"
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| where properties.securityProfile.encryptionAtHost == true
| project name, resourceGroup, location, subscriptionId
"@

$eahVMs = Search-AzGraph -Query $eahQuery
if ($eahVMs.Count -gt 0) {
    $eahVMs | Format-Table -AutoSize
} else {
    Write-Host "  No VMs with Encryption at Host found." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== EaH Compliance Summary ===" -ForegroundColor Cyan
Write-Host ""

$summaryQuery = @"
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend eahEnabled = (properties.securityProfile.encryptionAtHost == true)
| summarize Total = count(), EaH = countif(eahEnabled), NoEaH = countif(not(eahEnabled))
  by subscriptionId
"@

$summary = Search-AzGraph -Query $summaryQuery
if ($summary.Count -gt 0) {
    $summary | Format-Table -AutoSize
} else {
    Write-Host "  No VMs found in accessible subscriptions." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done. VMs listed under 'ADE-Encrypted VMs' that are NOT in the 'Already on EaH' list are migration candidates." -ForegroundColor Green
