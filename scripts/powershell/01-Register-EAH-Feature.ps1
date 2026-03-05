<#
.SYNOPSIS
    Registers the EncryptionAtHost feature on the current Azure subscription.

.DESCRIPTION
    This is a one-time, per-subscription prerequisite before Encryption at Host
    can be enabled on any VM in that subscription.  The script registers the
    Microsoft.Compute/EncryptionAtHost feature, waits for the registration to
    complete (up to 15 minutes), and then re-registers the compute provider so
    the feature flag is propagated.

.PARAMETER SubscriptionId
    (Optional) The subscription ID to target. Defaults to the currently selected
    subscription in the Az PowerShell context.

.EXAMPLE
    # Use the currently active subscription
    .\01-Register-EAH-Feature.ps1

.EXAMPLE
    # Target a specific subscription
    .\01-Register-EAH-Feature.ps1 -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.NOTES
    Requires: Az.Accounts, Az.Resources
    Reference: https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Context ─────────────────────────────────────────────────────────────────

if ($SubscriptionId) {
    Write-Host "Setting subscription context to: $SubscriptionId" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$ctx = Get-AzContext
Write-Host "Active subscription: $($ctx.Subscription.Name) [$($ctx.Subscription.Id)]" -ForegroundColor Cyan

# ── Check current state ──────────────────────────────────────────────────────

$feature = Get-AzProviderFeature -FeatureName 'EncryptionAtHost' -ProviderNamespace 'Microsoft.Compute'

if ($feature.RegistrationState -eq 'Registered') {
    Write-Host "EncryptionAtHost is already Registered on this subscription. No action needed." -ForegroundColor Green
    exit 0
}

# ── Register ─────────────────────────────────────────────────────────────────

Write-Host "Registering EncryptionAtHost feature..." -ForegroundColor Yellow
Register-AzProviderFeature -FeatureName 'EncryptionAtHost' -ProviderNamespace 'Microsoft.Compute' | Out-Null

# ── Poll until registered ────────────────────────────────────────────────────

$timeoutMinutes = 15
$pollIntervalSeconds = 30
$elapsed = 0

Write-Host "Waiting for registration to complete (timeout: ${timeoutMinutes}m, polling every ${pollIntervalSeconds}s)..."

do {
    Start-Sleep -Seconds $pollIntervalSeconds
    $elapsed += $pollIntervalSeconds
    $feature = Get-AzProviderFeature -FeatureName 'EncryptionAtHost' -ProviderNamespace 'Microsoft.Compute'
    Write-Host "  [$([math]::Round($elapsed/60,1))m] State: $($feature.RegistrationState)"
} while ($feature.RegistrationState -ne 'Registered' -and $elapsed -lt ($timeoutMinutes * 60))

if ($feature.RegistrationState -ne 'Registered') {
    Write-Error "EncryptionAtHost registration did not complete within ${timeoutMinutes} minutes. " +
        "Check the Azure Portal and re-run this script."
    exit 1
}

# ── Re-register provider to propagate ────────────────────────────────────────

Write-Host "Re-registering Microsoft.Compute provider to propagate the feature flag..." -ForegroundColor Yellow
Register-AzResourceProvider -ProviderNamespace 'Microsoft.Compute' | Out-Null

Write-Host ""
Write-Host "EncryptionAtHost feature is now Registered." -ForegroundColor Green
Write-Host "You can now proceed to deploy the lab VM and run the migration script."
