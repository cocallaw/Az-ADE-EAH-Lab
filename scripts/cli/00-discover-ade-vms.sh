#!/bin/bash
set -euo pipefail
#===============================================================================
# 00-discover-ade-vms.sh
#
# Discovers ADE-encrypted VMs across accessible subscriptions using
# Azure Resource Graph. Also identifies VMs already on Encryption at Host
# to help plan migration scope.
#
# Prerequisites:
#   - Azure CLI 2.50+ (resource-graph is built-in on recent versions)
#   - Logged in: az login
#
# Usage:
#   bash 00-discover-ade-vms.sh
#===============================================================================

# Verify az graph query is available
if ! az graph query -q "Resources | limit 1" --first 1 &>/dev/null; then
    echo "ERROR: 'az graph query' failed. Ensure Azure CLI 2.50+ is installed"
    echo "       and you are logged in (az login)."
    echo ""
    echo "On older CLI versions, install the extension:"
    echo "  az extension add --name resource-graph"
    exit 1
fi

echo "=== ADE-Encrypted VMs (via extension detection) ==="
echo ""
az graph query -q "
  Resources
  | where type =~ 'microsoft.compute/virtualmachines/extensions'
  | where name in ('AzureDiskEncryption', 'AzureDiskEncryptionForLinux')
  | where properties.provisioningState == 'Succeeded'
  | extend vmName = tostring(split(id, '/')[8])
  | project vmName, resourceGroup, location, subscriptionId, extensionType = name
  | order by subscriptionId, resourceGroup
" --first 1000 --query "data" -o table

echo ""
echo "=== VMs Already on Encryption at Host (exclude from migration) ==="
echo ""
az graph query -q "
  Resources
  | where type =~ 'microsoft.compute/virtualmachines'
  | where properties.securityProfile.encryptionAtHost == true
  | project name, resourceGroup, location, subscriptionId
" --first 1000 --query "data" -o table

echo ""
echo "=== EaH Compliance Summary ==="
echo ""
az graph query -q "
  Resources
  | where type =~ 'microsoft.compute/virtualmachines'
  | extend eahEnabled = (properties.securityProfile.encryptionAtHost == true)
  | summarize Total = count(), EaH = countif(eahEnabled), NoEaH = countif(not(eahEnabled))
    by subscriptionId
" --first 1000 --query "data" -o table

echo ""
echo "NOTE: Results are limited to the first 1000 rows per query."
echo "      If your environment has more VMs, use --skip-token for pagination."
echo ""
echo "Done. VMs listed under 'ADE-Encrypted VMs' that are NOT in the 'Already on EaH' list are migration candidates."
