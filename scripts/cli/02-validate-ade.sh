#!/usr/bin/env bash
# =============================================================================
# 02-validate-ade.sh
#
# Validates that Azure Disk Encryption (ADE) is active on a VM.
# Exits 0 when all disks are encrypted, 1 when any disk is not.
#
# Usage:
#   bash 02-validate-ade.sh <RESOURCE_GROUP> <VM_NAME> [SUBSCRIPTION_ID]
#
# Reference:
#   https://learn.microsoft.com/en-us/azure/virtual-machines/linux/disk-encryption-linux
# =============================================================================
set -euo pipefail

RESOURCE_GROUP="${1:?Usage: $0 <RESOURCE_GROUP> <VM_NAME> [SUBSCRIPTION_ID]}"
VM_NAME="${2:?Usage: $0 <RESOURCE_GROUP> <VM_NAME> [SUBSCRIPTION_ID]}"
SUBSCRIPTION_ID="${3:-}"

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi

echo ""
echo "=== ADE Validation: $VM_NAME ==="

# ── Extension presence ────────────────────────────────────────────────────────

OS_TYPE=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "storageProfile.osDisk.osType" -o tsv)

if [[ "$OS_TYPE" == "Windows" ]]; then
  EXT_NAME="AzureDiskEncryption"
else
  EXT_NAME="AzureDiskEncryptionForLinux"
fi

EXT_STATE=$(az vm extension show \
  --resource-group "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  --name "$EXT_NAME" \
  --query "provisioningState" -o tsv 2>/dev/null || echo "NotFound")

if [[ "$EXT_STATE" == "NotFound" ]]; then
  echo "WARNING: ADE extension ($EXT_NAME) was NOT found on $VM_NAME."
else
  echo "ADE extension ($EXT_NAME): $EXT_STATE"
fi

# ── Disk encryption status ────────────────────────────────────────────────────

echo ""
echo "Disk encryption status:"

ENCRYPTION_STATUS=$(az vm encryption show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "{osDisk: osDisk, dataDisks: dataDisk}" \
  -o json 2>/dev/null || echo '{}')

OS_STATE=$(echo "$ENCRYPTION_STATUS" | \
  python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('osDisk','Unknown'))" 2>/dev/null || echo "Unknown")

DATA_STATE=$(echo "$ENCRYPTION_STATUS" | \
  python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('dataDisks','Unknown'))" 2>/dev/null || echo "Unknown")

ALL_ENCRYPTED=true

if [[ "$OS_STATE" == "Encrypted" ]]; then
  echo "  OS Disk  : $OS_STATE ✓"
else
  echo "  OS Disk  : $OS_STATE ✗"
  ALL_ENCRYPTED=false
fi

if [[ "$DATA_STATE" == "Encrypted" ]]; then
  echo "  Data Disk: $DATA_STATE ✓"
elif [[ "$DATA_STATE" == "NotMounted" ]]; then
  echo "  Data Disk: $DATA_STATE (no data disks attached)"
else
  echo "  Data Disk: $DATA_STATE ✗"
  ALL_ENCRYPTED=false
fi

echo ""
if [[ "$ALL_ENCRYPTED" == "true" ]]; then
  echo "RESULT: ADE is active and all disks are encrypted."
  echo "You can now proceed to 03-migrate-ade-to-eah.sh"
  exit 0
else
  echo "RESULT: One or more disks are NOT fully encrypted. Review the output above." >&2
  exit 1
fi
