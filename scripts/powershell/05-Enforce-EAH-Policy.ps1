#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
    Assigns the built-in Azure Policy that audits (or denies) VMs without
    Encryption at Host enabled.

.DESCRIPTION
    Creates a policy assignment for the built-in definition
    "Virtual machines and virtual machine scale sets should have encryption
    at host enabled" (fc4d8e41-e223-45ea-9bf5-eada37891d87).

    By default the policy runs in Audit mode — non-compliant VMs are flagged
    but not blocked. After migrating all VMs, switch to Deny mode to prevent
    new VMs without Encryption at Host.

    The script:
      1. Creates/updates the policy assignment with the specified effect.
      2. Triggers a compliance scan and waits for results.
      3. Lists non-compliant resources.
      4. Provides guidance on switching between Audit and Deny modes.

.PARAMETER SubscriptionId
    (Optional) Target subscription. Defaults to the current Az context.

.PARAMETER PolicyEffect
    Policy effect: "Audit" (default) or "Deny".

.PARAMETER AssignmentName
    (Optional) Custom name for the policy assignment.
    Defaults to "enforce-eah-audit" or "enforce-eah-deny".

.PARAMETER Scope
    (Optional) Custom scope for the assignment (subscription or resource group
    resource ID). Defaults to the current subscription.

.PARAMETER SkipScan
    If specified, skips waiting for the compliance scan to complete.

.EXAMPLE
    # Assign in Audit mode (default)
    .\05-Enforce-EAH-Policy.ps1

.EXAMPLE
    # Assign in Deny mode
    .\05-Enforce-EAH-Policy.ps1 -PolicyEffect Deny

.EXAMPLE
    # Target a specific subscription
    .\05-Enforce-EAH-Policy.ps1 -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    # Scope to a specific resource group
    .\05-Enforce-EAH-Policy.ps1 -Scope "/subscriptions/<sub-id>/resourceGroups/my-rg"

.NOTES
    Requires: Az.Accounts, Az.Resources
    Policy ID: fc4d8e41-e223-45ea-9bf5-eada37891d87
    Reference: https://learn.microsoft.com/en-us/azure/governance/policy/assign-policy-powershell
    Reference: https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate
#>

[CmdletBinding()]
param (
    [string]$SubscriptionId,

    [ValidateSet('Audit', 'Deny')]
    [string]$PolicyEffect = 'Audit',

    [string]$AssignmentName,

    [string]$Scope,

    [switch]$SkipScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PolicyDefinitionId = 'fc4d8e41-e223-45ea-9bf5-eada37891d87'

# ── Context ──────────────────────────────────────────────────────────────────

if ($SubscriptionId) {
    Write-Host "Setting subscription context to: $SubscriptionId" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$ctx = Get-AzContext
Write-Host "Active subscription: $($ctx.Subscription.Name) [$($ctx.Subscription.Id)]" -ForegroundColor Cyan

if (-not $Scope) {
    $Scope = "/subscriptions/$($ctx.Subscription.Id)"
}

if (-not $AssignmentName) {
    $AssignmentName = "enforce-eah-$($PolicyEffect.ToLower())"
}

$displayName = "Encryption at Host - $PolicyEffect All VMs"

Write-Host ""
Write-Host "=== Azure Policy: Encryption at Host Enforcement ===" -ForegroundColor Cyan
Write-Host "  Policy Effect : $PolicyEffect"
Write-Host "  Assignment    : $AssignmentName"
Write-Host "  Scope         : $Scope"
Write-Host ""

# ── Assign policy ────────────────────────────────────────────────────────────

Write-Host "Creating/updating policy assignment..." -ForegroundColor Yellow

$policyDef = Get-AzPolicyDefinition -Id "/providers/Microsoft.Authorization/policyDefinitions/$PolicyDefinitionId"

$paramObj = @{ effect = @{ value = $PolicyEffect } }

New-AzPolicyAssignment `
    -Name $AssignmentName `
    -DisplayName $displayName `
    -PolicyDefinition $policyDef `
    -Scope $Scope `
    -PolicyParameterObject $paramObj | Out-Null

Write-Host "Policy assignment '$AssignmentName' created with effect '$PolicyEffect'." -ForegroundColor Green

# ── Trigger compliance scan ──────────────────────────────────────────────────

if ($SkipScan) {
    Write-Host ""
    Write-Host "SkipScan specified — skipping compliance scan." -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "Triggering compliance scan (this may take several minutes)..." -ForegroundColor Yellow

    try {
        Start-AzPolicyComplianceScan -AsJob | Out-Null
    } catch {
        Write-Host "  Note: Scan trigger returned: $_" -ForegroundColor Yellow
    }

    $timeoutMinutes = 10
    $pollIntervalSeconds = 30
    $elapsed = 0

    Write-Host "Waiting for compliance data (timeout: ${timeoutMinutes}m, polling every ${pollIntervalSeconds}s)..."

    do {
        Start-Sleep -Seconds $pollIntervalSeconds
        $elapsed += $pollIntervalSeconds

        $states = Get-AzPolicyState -PolicyAssignmentName $AssignmentName -ErrorAction SilentlyContinue

        if ($states -and $states.Count -gt 0) {
            Write-Host "  Compliance data available." -ForegroundColor Green
            break
        }

        Write-Host "  [$([math]::Round($elapsed/60,1))m] Waiting for compliance data..."
    } while ($elapsed -lt ($timeoutMinutes * 60))

    if ($elapsed -ge ($timeoutMinutes * 60) -and (-not $states -or $states.Count -eq 0)) {
        Write-Host "WARNING: Compliance scan did not produce results within ${timeoutMinutes} minutes." -ForegroundColor Yellow
        Write-Host "         Results may still be processing. Run the commands below manually to check."
    }
}

# ── List non-compliant resources ─────────────────────────────────────────────

Write-Host ""
Write-Host "Non-compliant resources:" -ForegroundColor Cyan
Write-Host ""

$nonCompliant = Get-AzPolicyState `
    -PolicyAssignmentName $AssignmentName `
    -Filter "isCompliant eq false" `
    -ErrorAction SilentlyContinue

if (-not $nonCompliant -or $nonCompliant.Count -eq 0) {
    Write-Host "  No non-compliant resources found. All VMs have Encryption at Host enabled." -ForegroundColor Green
} else {
    $nonCompliant | Select-Object ResourceId, ComplianceState | Format-Table -AutoSize
}

# ── Summary and next steps ───────────────────────────────────────────────────

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan

if ($PolicyEffect -eq 'Audit') {
    Write-Host " Policy is in AUDIT mode." -ForegroundColor Yellow
    Write-Host ""
    Write-Host " Non-compliant VMs are flagged but NOT blocked."
    Write-Host " After migrating all VMs to Encryption at Host, switch to"
    Write-Host " Deny mode to prevent new VMs without EaH:"
    Write-Host ""
    Write-Host "   .\05-Enforce-EAH-Policy.ps1 -PolicyEffect Deny" -ForegroundColor White
    Write-Host ""
    Write-Host " Or update the existing assignment:"
    Write-Host ""
    Write-Host "   Set-AzPolicyAssignment ``" -ForegroundColor White
    Write-Host "     -Name '$AssignmentName' ``" -ForegroundColor White
    Write-Host "     -PolicyParameterObject @{ effect = @{ value = 'Deny' } }" -ForegroundColor White
} else {
    Write-Host " Policy is in DENY mode." -ForegroundColor Red
    Write-Host ""
    Write-Host " New VMs without Encryption at Host will be BLOCKED."
    Write-Host " To switch back to Audit mode:"
    Write-Host ""
    Write-Host "   .\05-Enforce-EAH-Policy.ps1 -PolicyEffect Audit" -ForegroundColor White
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "To re-check compliance at any time:"
Write-Host ""
Write-Host "  Get-AzPolicyState ``" -ForegroundColor White
Write-Host "    -PolicyAssignmentName '$AssignmentName' ``" -ForegroundColor White
Write-Host "    -Filter 'isCompliant eq false' |" -ForegroundColor White
Write-Host "    Select-Object ResourceId, ComplianceState" -ForegroundColor White
