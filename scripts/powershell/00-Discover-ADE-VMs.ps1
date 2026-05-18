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
      - Az.ResourceGraph module (Install-Module Az.ResourceGraph)
      - Logged in: Connect-AzAccount
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Verify Az.ResourceGraph module is available
if (-not (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
    Write-Host "ERROR: Az.ResourceGraph module is not installed." -ForegroundColor Red
    Write-Host "       Install it with:" -ForegroundColor Red
    Write-Host "         Install-Module -Name Az.ResourceGraph -Scope CurrentUser" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "       Then re-run this script." -ForegroundColor Red
    exit 1
}
Import-Module Az.ResourceGraph

Write-Host "=== ADE-Encrypted VMs (via extension detection) ===" -ForegroundColor Cyan
Write-Host ""

$adeQuery = @"
Resources
| where type =~ 'microsoft.compute/virtualmachines/extensions'
| where properties.type in ('AzureDiskEncryption', 'AzureDiskEncryptionForLinux')
| where properties.provisioningState == 'Succeeded'
| extend vmName = tostring(split(id, '/')[8])
| project vmName, resourceGroup, location, subscriptionId, extensionType = tostring(properties.type)
| order by subscriptionId, resourceGroup
"@

$adeVMs = @(Search-AzGraph -Query $adeQuery -First 1000)
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

$eahVMs = @(Search-AzGraph -Query $eahQuery -First 1000)
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

$summary = @(Search-AzGraph -Query $summaryQuery -First 1000)
if ($summary.Count -gt 0) {
    $summary | Format-Table -AutoSize
} else {
    Write-Host "  No VMs found in accessible subscriptions." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "NOTE: Results are limited to the first 1000 rows per query." -ForegroundColor DarkGray
Write-Host "      For larger environments, implement paging with -SkipToken." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Done. VMs listed under 'ADE-Encrypted VMs' that are NOT in the 'Already on EaH' list are migration candidates." -ForegroundColor Green
