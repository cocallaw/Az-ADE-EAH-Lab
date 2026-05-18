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
#   - Azure CLI 2.50+ with 'resource-graph' extension
#   - Logged in: az login
#
# Usage:
#   bash 00-discover-ade-vms.sh
#===============================================================================

# Ensure resource-graph extension is available
if ! az extension show --name resource-graph &>/dev/null; then
    echo "Installing Azure CLI resource-graph extension..."
    az extension add --name resource-graph --only-show-errors
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
" --query "data" -o table

echo ""
echo "=== VMs Already on Encryption at Host (exclude from migration) ==="
echo ""
az graph query -q "
  Resources
  | where type =~ 'microsoft.compute/virtualmachines'
  | where properties.securityProfile.encryptionAtHost == true
  | project name, resourceGroup, location, subscriptionId
" --query "data" -o table

echo ""
echo "=== EaH Compliance Summary ==="
echo ""
az graph query -q "
  Resources
  | where type =~ 'microsoft.compute/virtualmachines'
  | extend eahEnabled = (properties.securityProfile.encryptionAtHost == true)
  | summarize Total = count(), EaH = countif(eahEnabled), NoEaH = countif(not(eahEnabled))
    by subscriptionId
" --query "data" -o table

echo ""
echo "Done. VMs listed under 'ADE-Encrypted VMs' that are NOT in the 'Already on EaH' list are migration candidates."
