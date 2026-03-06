#!/usr/bin/env bash
# =============================================================================
# 03-migrate-ade-to-eah.sh
#
# Migrates a VM from Azure Disk Encryption (ADE) to Encryption at Host (EaH).
#
# Steps:
#   1. Verify the EncryptionAtHost subscription feature is Registered.
#   2. Confirm ADE is currently active on the VM.
#   3. Disable ADE (decrypt all disks).
#   4. Deallocate the VM.
#   5. Enable Encryption at Host on the VM.
#   6. Start the VM.
#
# Usage:
#   bash 03-migrate-ade-to-eah.sh <RESOURCE_GROUP> <VM_NAME> [SUBSCRIPTION_ID]
#
# Dry-run (no changes applied):
#   DRY_RUN=1 bash 03-migrate-ade-to-eah.sh <RESOURCE_GROUP> <VM_NAME>
#
# Reference:
#   https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate
# =============================================================================
set -euo pipefail

RESOURCE_GROUP="${1:?Usage: $0 <RESOURCE_GROUP> <VM_NAME> [SUBSCRIPTION_ID]}"
VM_NAME="${2:?Usage: $0 <RESOURCE_GROUP> <VM_NAME> [SUBSCRIPTION_ID]}"
SUBSCRIPTION_ID="${3:-}"
DRY_RUN="${DRY_RUN:-0}"

# ── Helpers ───────────────────────────────────────────────────────────────────

step() { echo ""; echo "──────────────────────────────────────────"; echo "$1"; echo "──────────────────────────────────────────"; }
run()  {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY-RUN] Would run: $*"
  else
    "$@"
  fi
}

format_elapsed() {
  local total_secs=$1
  if (( total_secs < 60 )); then
    echo "${total_secs}s"
  else
    echo "$(( total_secs / 60 ))m $(( total_secs % 60 ))s"
  fi
}

MIGRATION_START=$SECONDS
declare -a STEP_NAMES=()
declare -a STEP_TIMES=()

# ── Context ───────────────────────────────────────────────────────────────────

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi

CURRENT_SUB=$(az account show --query "[name, id]" -o tsv | tr '\t' ' / ')
echo "Active subscription : $CURRENT_SUB"
echo "Resource Group      : $RESOURCE_GROUP"
echo "VM Name             : $VM_NAME"
[[ "$DRY_RUN" == "1" ]] && echo "(DRY-RUN mode – no changes will be applied)"

# ── Step 1: Verify EncryptionAtHost feature ───────────────────────────────────

step "Step 1 – Verify EncryptionAtHost feature registration"
STEP_START=$SECONDS

FEATURE_STATE=$(az feature show \
  --name EncryptionAtHost \
  --namespace Microsoft.Compute \
  --query "properties.state" -o tsv)

if [[ "$FEATURE_STATE" != "Registered" ]]; then
  echo "ERROR: EncryptionAtHost is not Registered (state: $FEATURE_STATE)." >&2
  echo "Run 01-register-eah-feature.sh first and wait for registration to complete." >&2
  exit 1
fi
echo "EncryptionAtHost feature: Registered ✓"

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 1 – Verify EaH feature"); STEP_TIMES+=("$STEP_ELAPSED")
echo "  ⏱  $(format_elapsed $STEP_ELAPSED)"

# ── Step 2: Confirm ADE is active ─────────────────────────────────────────────

step "Step 2 – Confirm ADE is currently active"
STEP_START=$SECONDS

OS_TYPE=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "storageProfile.osDisk.osType" -o tsv)

ENC_SHOW=$(az vm encryption show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "{osDisk: osDisk, dataDisks: dataDisk}" \
  -o json 2>/dev/null || echo '{}')

OS_ENC=$(echo "$ENC_SHOW" | python3 -c "import sys,json; print(json.load(sys.stdin).get('osDisk','Unknown'))" 2>/dev/null || echo "Unknown")
DATA_ENC=$(echo "$ENC_SHOW" | python3 -c "import sys,json; print(json.load(sys.stdin).get('dataDisks','Unknown'))" 2>/dev/null || echo "Unknown")

if [[ "$OS_ENC" == "Encrypted" || "$DATA_ENC" == "Encrypted" ]]; then
  echo "ADE is active. OS: $OS_ENC | Data: $DATA_ENC"
  ADE_ACTIVE=true
else
  echo "WARNING: ADE does not appear to be active (OS: $OS_ENC, Data: $DATA_ENC)."
  echo "Proceeding anyway – the VM may already be partially migrated."
  ADE_ACTIVE=false
fi

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 2 – Confirm ADE active"); STEP_TIMES+=("$STEP_ELAPSED")
echo "  ⏱  $(format_elapsed $STEP_ELAPSED)"

# ── Step 3: Disable ADE ───────────────────────────────────────────────────────

step "Step 3 – Disable ADE (decrypt all disks)"
STEP_START=$SECONDS

if [[ "$ADE_ACTIVE" == "true" ]]; then
  echo "Disabling ADE on $VM_NAME (volume-type: all). This may take several minutes..."
  run az vm encryption disable \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --volume-type all \
    --force
  echo "ADE disabled. ✓"
else
  echo "Skipping – ADE is not active."
fi

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 3 – Disable ADE"); STEP_TIMES+=("$STEP_ELAPSED")
echo "  ⏱  $(format_elapsed $STEP_ELAPSED)"

# ── Step 4: Deallocate the VM ─────────────────────────────────────────────────

step "Step 4 – Deallocate the VM"
STEP_START=$SECONDS

POWER_STATE=$(az vm get-instance-view \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" \
  -o tsv 2>/dev/null || echo "unknown")

if [[ "$POWER_STATE" == "VM deallocated" ]]; then
  echo "VM is already deallocated."
else
  echo "Stopping and deallocating $VM_NAME (current state: $POWER_STATE)..."
  run az vm deallocate \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME"
  echo "VM deallocated. ✓"
fi

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 4 – Deallocate VM"); STEP_TIMES+=("$STEP_ELAPSED")
echo "  ⏱  $(format_elapsed $STEP_ELAPSED)"

# ── Step 5: Enable Encryption at Host ────────────────────────────────────────

step "Step 5 – Enable Encryption at Host"
STEP_START=$SECONDS

EAH_ENABLED=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "securityProfile.encryptionAtHost" -o tsv 2>/dev/null || echo "false")

if [[ "$EAH_ENABLED" == "true" ]]; then
  echo "Encryption at Host is already enabled on $VM_NAME."
else
  echo "Enabling Encryption at Host on $VM_NAME..."
  run az vm update \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --set securityProfile.encryptionAtHost=true \
    --output none
  echo "Encryption at Host enabled. ✓"
fi

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 5 – Enable EaH"); STEP_TIMES+=("$STEP_ELAPSED")
echo "  ⏱  $(format_elapsed $STEP_ELAPSED)"

# ── Step 6: Start the VM ──────────────────────────────────────────────────────

step "Step 6 – Start the VM"
STEP_START=$SECONDS

echo "Starting $VM_NAME..."
run az vm start \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME"
echo "VM started. ✓"

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 6 – Start VM"); STEP_TIMES+=("$STEP_ELAPSED")
echo "  ⏱  $(format_elapsed $STEP_ELAPSED)"

# ── Summary ───────────────────────────────────────────────────────────────────

TOTAL_ELAPSED=$(( SECONDS - MIGRATION_START ))

echo ""
echo "============================================"
echo " Migration complete!"
echo " VM '$VM_NAME' is now using Encryption at Host."
echo " Run 04-validate-eah.sh to confirm."
echo "============================================"
echo ""
echo "Timing Summary"
echo "──────────────────────────────────────────"
for i in "${!STEP_NAMES[@]}"; do
  printf "  %-30s %s\n" "${STEP_NAMES[$i]}" "$(format_elapsed "${STEP_TIMES[$i]}")"
done
echo "──────────────────────────────────────────"
printf "  %-30s %s\n" "Total" "$(format_elapsed $TOTAL_ELAPSED)"
