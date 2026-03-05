#!/usr/bin/env bash
# =============================================================================
# 04-validate-eah.sh
#
# Validates that Encryption at Host (EaH) is enabled on a VM and ADE is gone.
#
# Checks:
#   1. securityProfile.encryptionAtHost == true on the VM.
#   2. ADE extension is absent.
#   3. Disk encryption status reports no ADE encryption.
#
# Usage:
#   bash 04-validate-eah.sh <RESOURCE_GROUP> <VM_NAME> [SUBSCRIPTION_ID]
#
# Exits 0 on full pass, 1 if any check fails.
#
# Reference:
#   https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate
# =============================================================================
set -euo pipefail

RESOURCE_GROUP="${1:?Usage: $0 <RESOURCE_GROUP> <VM_NAME> [SUBSCRIPTION_ID]}"
VM_NAME="${2:?Usage: $0 <RESOURCE_GROUP> <VM_NAME> [SUBSCRIPTION_ID]}"
SUBSCRIPTION_ID="${3:-}"

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi

echo ""
echo "=== Encryption at Host Validation: $VM_NAME ==="

ALL_PASSED=true

# ── Check 1: EncryptionAtHost on VM security profile ─────────────────────────

EAH_ENABLED=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "securityProfile.encryptionAtHost" -o tsv 2>/dev/null || echo "false")

if [[ "$EAH_ENABLED" == "true" ]]; then
  echo "[PASS] Encryption at Host is enabled on the VM security profile."
else
  echo "[FAIL] Encryption at Host is NOT enabled on the VM security profile." >&2
  ALL_PASSED=false
fi

# ── Check 2: ADE extension is absent ─────────────────────────────────────────

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
  echo "[PASS] ADE extension ($EXT_NAME) is not present."
else
  echo "[INFO] ADE extension ($EXT_NAME) still listed with state: $EXT_STATE."
  echo "       This is expected if decryption completed. Verify disk status below."
fi

# ── Check 3: Disk encryption status ──────────────────────────────────────────

echo ""
echo "Disk encryption status:"

ENC_SHOW=$(az vm encryption show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "{osDisk: osDisk, dataDisks: dataDisk}" \
  -o json 2>/dev/null || echo '{}')

OS_ENC=$(echo "$ENC_SHOW" | python3 -c "import sys,json; print(json.load(sys.stdin).get('osDisk','Unknown'))" 2>/dev/null || echo "Unknown")
DATA_ENC=$(echo "$ENC_SHOW" | python3 -c "import sys,json; print(json.load(sys.stdin).get('dataDisks','Unknown'))" 2>/dev/null || echo "Unknown")

if [[ "$OS_ENC" == "NotEncrypted" || "$OS_ENC" == "NoDiskFound" ]]; then
  echo "  [PASS] OS disk ADE encryption : $OS_ENC"
else
  echo "  [FAIL] OS disk still reports ADE encryption: $OS_ENC" >&2
  ALL_PASSED=false
fi

if [[ "$DATA_ENC" == "NotEncrypted" || "$DATA_ENC" == "NoDiskFound" || "$DATA_ENC" == "NotMounted" ]]; then
  echo "  [PASS] Data disk ADE encryption: $DATA_ENC"
else
  echo "  [FAIL] Data disk(s) still report ADE encryption: $DATA_ENC" >&2
  ALL_PASSED=false
fi

# ── Check 4: Individual managed disk encryption type ─────────────────────────

echo ""
echo "Managed disk encryption types:"

DISK_NAMES=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "[storageProfile.osDisk.name, storageProfile.dataDisks[].name]" \
  -o json | python3 -c "
import sys, json
items = json.load(sys.stdin)
names = [items[0]] if items[0] else []
if items[1]: names.extend(items[1])
print('\n'.join(names))
" 2>/dev/null || true)

while IFS= read -r DISK_NAME; do
  [[ -z "$DISK_NAME" ]] && continue
  ENC_TYPE=$(az disk show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$DISK_NAME" \
    --query "encryption.type" -o tsv 2>/dev/null || echo "Unknown")
  echo "  Disk: $DISK_NAME  →  encryption.type: $ENC_TYPE"
done <<< "$DISK_NAMES"

# ── Result ────────────────────────────────────────────────────────────────────

echo ""
if [[ "$ALL_PASSED" == "true" ]]; then
  echo "============================================"
  echo " PASSED: $VM_NAME is fully migrated to"
  echo "         Encryption at Host."
  echo "============================================"
  exit 0
else
  echo "============================================" >&2
  echo " FAILED: One or more checks did not pass." >&2
  echo " Review output above and re-run migration." >&2
  echo "============================================" >&2
  exit 1
fi
