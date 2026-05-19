#!/usr/bin/env bash
# =============================================================================
# 03-migrate-ade-to-eah.sh
#
# Migrates a VM from Azure Disk Encryption (ADE) to Encryption at Host (EaH).
#
# Azure does not allow enabling Encryption at Host on VMs whose disks carry the
# Unified Data Encryption (UDE) flag set by ADE — even after ADE has been
# disabled.  Migration therefore requires creating new managed disks and a new
# VM.  The Upload+AzCopy method copies disk data into new managed disk objects
# that have no ADE/UDE metadata, and a new VM is created from those disks with
# EaH enabled.
#
# Steps:
#   1.  Verify the EncryptionAtHost subscription feature is Registered.
#   2.  Verify azcopy is installed and available in PATH.
#   3.  Confirm ADE status and capture the original VM configuration.
#   4.  Disable ADE (Windows: all volumes; Linux: data volumes only).
#       Prompt to confirm OS-level decryption is fully complete before continuing.
#   5.  Deallocate the original VM.
#   6.  Create new managed disks (OS + data) via Upload+AzCopy to strip the UDE flag.
#   7.  Create a new VM using the new disks with Encryption at Host enabled.
#   8.  Start the new VM.
#   9.  Verify Encryption at Host is active on the new VM.
#   10. Display cleanup commands for the original VM and disks.
#
#   Linux VMs with an ADE-encrypted OS disk cannot have ADE disabled in-place.
#   The script detects this case and exits with remediation guidance.
#
# Usage:
#   bash 03-migrate-ade-to-eah.sh <RESOURCE_GROUP> <VM_NAME> [NEW_VM_NAME] [SUBSCRIPTION_ID]
#
#   NEW_VM_NAME  defaults to "<VM_NAME>-eah"
#   SAS_EXPIRY_HOURS (env var) controls SAS URI validity for disk copy. Default: 2
#   For disks larger than 512 GiB, increase to 6-24 hours.
#   Azure enforces a maximum SAS duration of 60 days (5,184,000 seconds) as of
#   Feb 2025. The 72-hour cap below is well within this limit, but if you adapt
#   the script for very large (4+ TB) disks, keep SAS_EXPIRY_HOURS under 1440.
#
# Dry-run (no changes applied):
#   DRY_RUN=1 bash 03-migrate-ade-to-eah.sh <RESOURCE_GROUP> <VM_NAME>
#
# Reference:
#   https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate
# =============================================================================
set -euo pipefail

RESOURCE_GROUP="${1:?Usage: $0 <RESOURCE_GROUP> <VM_NAME> [NEW_VM_NAME] [SUBSCRIPTION_ID]}"
VM_NAME="${2:?Usage: $0 <RESOURCE_GROUP> <VM_NAME> [NEW_VM_NAME] [SUBSCRIPTION_ID]}"
NEW_VM_NAME="${3:-}"
SUBSCRIPTION_ID="${4:-}"
DRY_RUN="${DRY_RUN:-0}"
SAS_EXPIRY_HOURS="${SAS_EXPIRY_HOURS:-2}"

# Validate SAS_EXPIRY_HOURS is between 1 and 72 (Azure maximum is 60 days / 1440 hours)
if ! [[ "$SAS_EXPIRY_HOURS" =~ ^[0-9]+$ ]] || (( SAS_EXPIRY_HOURS < 1 || SAS_EXPIRY_HOURS > 72 )); then
  echo "ERROR: SAS_EXPIRY_HOURS must be an integer between 1 and 72 (got: $SAS_EXPIRY_HOURS)." >&2
  exit 1
fi

# ── SAS grant tracking and cleanup trap ───────────────────────────────────────
# Track disk names with active SAS grants so they can be revoked on unexpected exit.

SAS_GRANTED_DISKS=()

cleanup_sas() {
  if [[ ${#SAS_GRANTED_DISKS[@]} -eq 0 ]]; then
    return
  fi
  echo ""
  echo "Revoking outstanding SAS grants..."
  for disk_name in "${SAS_GRANTED_DISKS[@]}"; do
    az disk revoke-access --resource-group "$RESOURCE_GROUP" --name "$disk_name" --output none 2>/dev/null || true
  done
  SAS_GRANTED_DISKS=()
}

trap cleanup_sas EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

step() { echo ""; echo "──────────────────────────────────────────"; echo "$1"; echo "──────────────────────────────────────────"; }

run() {
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

# Copy a managed disk via Upload+AzCopy, producing a new disk object with no
# ADE/UDE metadata.  A 512-byte offset is added to the upload size because
# Azure omits the VHD footer when reporting DiskSizeBytes.
#
# Args: <source_disk_name> <target_disk_name> <os_type_or_empty> <hyper_v_gen_or_empty> <sku>
copy_disk_via_upload() {
  local src_disk_name="$1"
  local tgt_disk_name="$2"
  local os_type="$3"        # "Windows", "Linux", or "" for data disks
  local hyper_v_gen="$4"    # "V1", "V2", or "" for data disks
  local sku="$5"
  local sas_expiry_secs=$(( SAS_EXPIRY_HOURS * 3600 ))

  echo "  Creating new disk '$tgt_disk_name' from '$src_disk_name'..."

  local src_size_bytes
  src_size_bytes=$(az disk show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$src_disk_name" \
    --query "diskSizeBytes" -o tsv)

  local upload_size=$(( src_size_bytes + 512 ))

  # Build the az disk create command conditionally
  local create_args=(
    az disk create
    --resource-group "$RESOURCE_GROUP"
    --name "$tgt_disk_name"
    --location "$VM_LOCATION"
    --for-upload
    --upload-size-bytes "$upload_size"
    --sku "$sku"
  )
  [[ -n "$os_type" ]]    && create_args+=(--os-type "$os_type")
  [[ -n "$hyper_v_gen" ]] && create_args+=(--hyper-v-generation "$hyper_v_gen")

  run "${create_args[@]}" --output none

  if [[ "$DRY_RUN" != "1" ]]; then
    echo "  Granting SAS access for disk copy..."
    local src_sas tgt_sas
    src_sas=$(az disk grant-access \
      --resource-group "$RESOURCE_GROUP" \
      --name "$src_disk_name" \
      --access-level Read \
      --duration-in-seconds "$sas_expiry_secs" \
      --query "accessSas" -o tsv)
    SAS_GRANTED_DISKS+=("$src_disk_name")

    tgt_sas=$(az disk grant-access \
      --resource-group "$RESOURCE_GROUP" \
      --name "$tgt_disk_name" \
      --access-level Write \
      --duration-in-seconds "$sas_expiry_secs" \
      --query "accessSas" -o tsv)
    SAS_GRANTED_DISKS+=("$tgt_disk_name")

    echo "  Copying disk data via azcopy (this may take several minutes)..."
    if ! azcopy copy "$src_sas" "$tgt_sas" --blob-type PageBlob; then
      echo "ERROR: azcopy failed for disk '$src_disk_name'. See output above." >&2
      exit 1
    fi

    echo "  Revoking SAS access..."
    az disk revoke-access --resource-group "$RESOURCE_GROUP" --name "$src_disk_name" --output none
    az disk revoke-access --resource-group "$RESOURCE_GROUP" --name "$tgt_disk_name" --output none
    # Remove revoked disks from tracking array
    local new_arr=()
    for d in "${SAS_GRANTED_DISKS[@]}"; do
      [[ "$d" != "$src_disk_name" && "$d" != "$tgt_disk_name" ]] && new_arr+=("$d")
    done
    SAS_GRANTED_DISKS=("${new_arr[@]+"${new_arr[@]}"}")
    echo "  Disk copy complete. ✓"
  fi
}

MIGRATION_START=$SECONDS
declare -a STEP_NAMES=()
declare -a STEP_TIMES=()

# ── Context ───────────────────────────────────────────────────────────────────

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi

[[ -z "$NEW_VM_NAME" ]] && NEW_VM_NAME="${VM_NAME}-eah"

CURRENT_SUB=$(az account show --query "[name, id]" -o tsv | tr '\t' ' / ')
echo "Active subscription : $CURRENT_SUB"
echo "Resource Group      : $RESOURCE_GROUP"
echo "VM Name (source)    : $VM_NAME"
echo "VM Name (new)       : $NEW_VM_NAME"
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

# ── Step 2: Verify azcopy ─────────────────────────────────────────────────────

step "Step 2 – Verify azcopy availability"
STEP_START=$SECONDS

if ! command -v azcopy &>/dev/null; then
  echo "ERROR: azcopy was not found in PATH." >&2
  echo "azcopy v10+ is required to copy disk data without the ADE/UDE metadata flag." >&2
  echo "Download it from https://aka.ms/downloadazcopy and ensure it is in PATH." >&2
  exit 1
fi
echo "azcopy found: $(command -v azcopy) ✓"

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 2 – Verify azcopy"); STEP_TIMES+=("$STEP_ELAPSED")
echo "  ⏱  $(format_elapsed $STEP_ELAPSED)"

# ── Step 3: Confirm ADE status and gather VM configuration ───────────────────

step "Step 3 – Confirm ADE status and capture VM configuration"
STEP_START=$SECONDS

VM_JSON=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  -o json)

OS_TYPE=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.osType')
VM_SIZE=$(echo "$VM_JSON" | jq -r '.hardwareProfile.vmSize')
VM_LOCATION=$(echo "$VM_JSON" | jq -r '.location')
OS_DISK_NAME=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.name')

# Collect NIC IDs and data disk info as newline-separated values
NIC_IDS=$(echo "$VM_JSON" | jq -r '.networkProfile.networkInterfaces[].id')

DATA_DISK_INFO=$(echo "$VM_JSON" | jq -r '.storageProfile.dataDisks[] | "\(.name)|\(.lun)"')

# Get OS disk details
OS_DISK_JSON=$(az disk show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$OS_DISK_NAME" \
  -o json)

OS_DISK_SKU=$(echo "$OS_DISK_JSON" | jq -r '.sku.name')
HYPER_V_GEN=$(echo "$OS_DISK_JSON" | jq -r '.hyperVGeneration // "V1"')

ENC_SHOW=$(az vm encryption show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "{osDisk: osDisk, dataDisks: dataDisk}" \
  -o json 2>/dev/null || echo '{}')

OS_ENC=$(echo "$ENC_SHOW" | jq -r '.osDisk // "NotEncrypted"' 2>/dev/null || echo "NotEncrypted")
DATA_ENC=$(echo "$ENC_SHOW" | jq -r '.dataDisks // "NotEncrypted"' 2>/dev/null || echo "NotEncrypted")

echo "OS Type              : $OS_TYPE"
echo "OS disk encrypted    : $OS_ENC"
echo "Data disks encrypted : $DATA_ENC"
echo ""
echo "VM Size              : $VM_SIZE"
echo "Location             : $VM_LOCATION"
echo "HyperV Generation    : $HYPER_V_GEN"
echo "OS disk              : $OS_DISK_NAME  [SKU: $OS_DISK_SKU]"
echo "NIC count            : $(echo "$NIC_IDS" | grep -c . || true)"
echo "Data disk count      : $(echo "$DATA_DISK_INFO" | grep -c . 2>/dev/null || echo 0)"

# ADE cannot be disabled on a Linux OS disk — a fresh VM must be built instead.
if [[ "$OS_TYPE" == "Linux" && "$OS_ENC" == "Encrypted" ]]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  LINUX VM WITH ENCRYPTED OS DISK – ALTERNATIVE PATH REQUIRED   ║"
  echo "╠══════════════════════════════════════════════════════════════════╣"
  echo "║                                                                  ║"
  echo "║  Disabling ADE on a Linux OS disk is not supported.             ║"
  echo "║  Use 03b-migrate-linux-os-disk.sh instead, which:               ║"
  echo "║                                                                  ║"
  echo "║  1. Creates a new Linux VM with EaH from a marketplace image.   ║"
  echo "║  2. Copies data disks via Upload+AzCopy (strips UDE metadata).  ║"
  echo "║  3. Provides a post-migration checklist for OS reconfiguration.  ║"
  echo "║                                                                  ║"
  echo "║  Usage:                                                          ║"
  echo "║    bash 03b-migrate-linux-os-disk.sh <RG> <VM> <SSH_KEY>        ║"
  echo "║                                                                  ║"
  echo "║  Reference: https://aka.ms/disk-encryption-migrate              ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  exit 1
fi

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 3 – Confirm ADE / capture config"); STEP_TIMES+=("$STEP_ELAPSED")
echo "  ⏱  $(format_elapsed $STEP_ELAPSED)"

# ── Step 4: Disable ADE and confirm OS-level decryption ──────────────────────

step "Step 4 – Disable ADE and confirm OS-level decryption"
STEP_START=$SECONDS

if [[ "$OS_ENC" == "Encrypted" || "$DATA_ENC" == "Encrypted" ]]; then
  # Linux: only data disks can be disabled in-place (encrypted OS disk case already exited above)
  if [[ "$OS_TYPE" == "Linux" ]]; then
    VOLUME_TYPE="data"
  else
    VOLUME_TYPE="all"
  fi

  echo "Disabling ADE on '$VM_NAME' (volume-type: $VOLUME_TYPE). This may take several minutes..."
  run az vm encryption disable \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --volume-type "$VOLUME_TYPE" \
    --force \
    --output none
  echo "ADE disable command succeeded. ✓"

  echo ""
  echo "  IMPORTANT: The portal now shows 'SSE + PMK' but OS-level decryption"
  echo "  continues in the background and may take time to complete."
  echo ""
  if [[ "$OS_TYPE" == "Windows" ]]; then
    echo "  Verifying decryption status in-VM via Run Command..."
    echo "  (Running manage-bde -status inside the VM)"
    RC_OUTPUT=$(az vm run-command invoke \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --command-id RunPowerShellScript \
      --scripts "manage-bde -status" \
      --query "value[0].message" -o tsv 2>/dev/null || echo "[Run Command failed – check manually]")
    echo "$RC_OUTPUT"
    echo ""
    if echo "$RC_OUTPUT" | grep -qiE "Decryption in Progress|Encryption in Progress"; then
      echo "  ⚠️  In-VM check: one or more volumes still show decryption/encryption in progress."
      echo "  Wait for decryption to complete before continuing."
    elif echo "$RC_OUTPUT" | grep -qi "Fully Decrypted"; then
      echo "  ✅ In-VM check: all volumes report 'Fully Decrypted'."
    else
      echo "  ⚠️  In-VM check: could not confirm 'Fully Decrypted' status."
      echo "  Verify manually via RDP before continuing."
    fi
  else
    echo "  Verifying decryption status in-VM via Run Command..."
    echo "  (Running lsblk -f inside the VM)"
    RC_OUTPUT=$(az vm run-command invoke \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --command-id RunShellScript \
      --scripts "lsblk -f && echo '---' && ls /dev/mapper/ 2>/dev/null" \
      --query "value[0].message" -o tsv 2>/dev/null || echo "[Run Command failed – check manually]")
    echo "$RC_OUTPUT"
    echo ""
    if echo "$RC_OUTPUT" | grep -q "^\[Run Command failed"; then
      echo "  ⚠️  Run Command failed — could not verify in-VM decryption status."
      echo "  Verify manually via SSH before continuing."
    elif echo "$RC_OUTPUT" | grep -qi "crypto_LUKS"; then
      echo "  ⚠️  In-VM check: crypto_LUKS still detected on some volumes."
      echo "  Wait for decryption to complete before continuing."
    else
      echo "  ✅ In-VM check: no crypto_LUKS mappings found on data volumes."
    fi
  fi
  echo ""

  if [[ "$DRY_RUN" != "1" ]]; then
    read -r -p "  Confirm OS-level decryption is fully complete on '$VM_NAME'. Continue? (yes/no): " answer
    if [[ ! "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      echo "Migration stopped. Re-run this script once decryption is confirmed complete." >&2
      exit 1
    fi
  fi
else
  echo "ADE is not active – disks may still carry the UDE flag from a prior ADE enable/disable cycle."
  echo "Continuing – new disks will be created via the Upload method to ensure no UDE metadata."
fi

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 4 – Disable ADE"); STEP_TIMES+=("$STEP_ELAPSED")
echo "  ⏱  $(format_elapsed $STEP_ELAPSED)"

# ── Step 5: Deallocate the original VM ───────────────────────────────────────

step "Step 5 – Deallocate the original VM"
STEP_START=$SECONDS

POWER_STATE=$(az vm get-instance-view \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" \
  -o tsv 2>/dev/null || echo "unknown")

if [[ "$POWER_STATE" == "VM deallocated" ]]; then
  echo "VM is already deallocated."
else
  echo "Stopping and deallocating '$VM_NAME' (current state: $POWER_STATE)..."
  run az vm deallocate \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME"
  echo "VM deallocated. ✓"
fi

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 5 – Deallocate VM"); STEP_TIMES+=("$STEP_ELAPSED")
echo "  ⏱  $(format_elapsed $STEP_ELAPSED)"

# ── Step 6: Create new managed disks via Upload + azcopy ─────────────────────

step "Step 6 – Create new managed disks via Upload+azcopy (removes UDE flag)"
STEP_START=$SECONDS

NEW_OS_DISK_NAME="${OS_DISK_NAME}-eah"
echo "OS disk: $OS_DISK_NAME → $NEW_OS_DISK_NAME"
copy_disk_via_upload \
  "$OS_DISK_NAME" \
  "$NEW_OS_DISK_NAME" \
  "$OS_TYPE" \
  "$HYPER_V_GEN" \
  "$OS_DISK_SKU"

# Track new data disk names for cleanup output later; format: "new_name|lun"
declare -a NEW_DATA_DISK_INFO=()

if [[ -n "$DATA_DISK_INFO" ]]; then
  DATA_DISK_COUNT=$(echo "$DATA_DISK_INFO" | grep -c . 2>/dev/null || echo 0)

  if (( DATA_DISK_COUNT > 1 )); then
    echo "Copying $DATA_DISK_COUNT data disks in parallel..."
    declare -a COPY_PIDS=()
    declare -a COPY_DISK_NAMES=()

    while IFS='|' read -r disk_name lun; do
      [[ -z "$disk_name" ]] && continue
      src_sku=$(az disk show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$disk_name" \
        --query "sku.name" -o tsv)
      new_data_disk_name="${disk_name}-eah"
      echo "Data disk (LUN $lun): $disk_name → $new_data_disk_name"
      # Track disk names in parent for cleanup trap (subshells can't update parent arrays)
      SAS_GRANTED_DISKS+=("$disk_name" "$new_data_disk_name")
      # Clear SAS tracking in subshell to prevent inherited EXIT trap from
      # revoking SAS grants belonging to other parallel copies
      (SAS_GRANTED_DISKS=(); copy_disk_via_upload \
        "$disk_name" \
        "$new_data_disk_name" \
        "" \
        "" \
        "$src_sku") &
      COPY_PIDS+=($!)
      COPY_DISK_NAMES+=("${new_data_disk_name}|${lun}|${disk_name}")
    done <<< "$DATA_DISK_INFO"

    # Wait for all parallel copies and check for failures
    COPY_FAILED=0
    for i in "${!COPY_PIDS[@]}"; do
      if ! wait "${COPY_PIDS[$i]}"; then
        echo "ERROR: Disk copy failed for '${COPY_DISK_NAMES[$i]%%|*}'." >&2
        COPY_FAILED=1
      fi
    done
    if (( COPY_FAILED )); then
      echo "ERROR: One or more parallel disk copies failed. See output above." >&2
      exit 1
    fi
    # Parallel copies completed — revoke SAS grants tracked in parent
    while IFS='|' read -r new_name lun src_name; do
      [[ -z "$new_name" ]] && continue
      az disk revoke-access --resource-group "$RESOURCE_GROUP" --name "$src_name" --output none 2>/dev/null || true
      az disk revoke-access --resource-group "$RESOURCE_GROUP" --name "$new_name" --output none 2>/dev/null || true
    done < <(printf '%s\n' "${COPY_DISK_NAMES[@]}")
    # Clear tracked disks after successful revocation
    SAS_GRANTED_DISKS=()

    NEW_DATA_DISK_INFO=("${COPY_DISK_NAMES[@]}")
  else
    # Single data disk — copy sequentially (no benefit from parallelism)
    while IFS='|' read -r disk_name lun; do
      [[ -z "$disk_name" ]] && continue
      src_sku=$(az disk show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$disk_name" \
        --query "sku.name" -o tsv)
      new_data_disk_name="${disk_name}-eah"
      echo "Data disk (LUN $lun): $disk_name → $new_data_disk_name"
      copy_disk_via_upload \
        "$disk_name" \
        "$new_data_disk_name" \
        "" \
        "" \
        "$src_sku"
      NEW_DATA_DISK_INFO+=("${new_data_disk_name}|${lun}|${disk_name}")
    done <<< "$DATA_DISK_INFO"
  fi
fi

echo "All new disks created successfully. ✓"

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 6 – Create new disks"); STEP_TIMES+=("$STEP_ELAPSED")
echo "  ⏱  $(format_elapsed $STEP_ELAPSED)"

# ── Step 7: Create new VM with Encryption at Host ────────────────────────────

step "Step 7 – Create new VM '$NEW_VM_NAME' with Encryption at Host"
STEP_START=$SECONDS

# Ensure NICs, OS disk, and data disks survive VM deletion by setting deleteOption to Detach.
# VMs deployed with deleteOption: Delete on NIC/OSDisk/DataDisk references will auto-delete
# those resources when the VM is removed unless we change this first.
echo "Setting NIC, OS disk, and data disk delete options to 'Detach' so they survive VM removal..."
nic_count=$(echo "$NIC_IDS" | wc -l)
data_disk_count=$(echo "$VM_JSON" | jq '.storageProfile.dataDisks | length')
set_args=(--set "storageProfile.osDisk.deleteOption=Detach")
for i in $(seq 0 $(( nic_count - 1 ))); do
  set_args+=(--set "networkProfile.networkInterfaces[$i].deleteOption=Detach")
done
for ((i=0; i<data_disk_count; i++)); do
  set_args+=(--set "storageProfile.dataDisks[$i].deleteOption=Detach")
done
run az vm update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  "${set_args[@]}" \
  --output none
echo "Delete options updated. ✓"

# Delete the original VM resource to release NICs so they can be attached to the new VM.
# The OS disk and data disks remain as unattached managed disks.
echo "Removing original VM resource '$VM_NAME' to release its NICs (disks are preserved)..."
run az vm delete \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --yes \
  --output none
echo "Original VM resource removed. Disks and NICs are intact. ✓"

# Build the az vm create command.  The first NIC becomes the primary.
PRIMARY_NIC=$(echo "$NIC_IDS" | head -n 1)
EXTRA_NICS=$(echo "$NIC_IDS" | tail -n +2 | tr '\n' ' ')

CREATE_CMD=(
  az vm create
  --resource-group "$RESOURCE_GROUP"
  --name "$NEW_VM_NAME"
  --location "$VM_LOCATION"
  --size "$VM_SIZE"
  --os-type "$OS_TYPE"
  --attach-os-disk "$NEW_OS_DISK_NAME"
  --nics "$PRIMARY_NIC"
  --encryption-at-host true
  --output none
)

run "${CREATE_CMD[@]}"

# Attach extra NICs if present
if [[ -n "$EXTRA_NICS" ]]; then
  for nic_id in $EXTRA_NICS; do
    run az vm nic add \
      --resource-group "$RESOURCE_GROUP" \
      --vm-name "$NEW_VM_NAME" \
      --nics "$(basename "$nic_id")" \
      --output none
  done
fi

# Attach new data disks
for entry in "${NEW_DATA_DISK_INFO[@]:-}"; do
  [[ -z "$entry" ]] && continue
  IFS='|' read -r new_disk_name lun _orig <<< "$entry"
  run az vm disk attach \
    --resource-group "$RESOURCE_GROUP" \
    --vm-name "$NEW_VM_NAME" \
    --name "$new_disk_name" \
    --lun "$lun" \
    --output none
done

echo "VM '$NEW_VM_NAME' created with Encryption at Host. ✓"

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 7 – Create new VM"); STEP_TIMES+=("$STEP_ELAPSED")
echo "  ⏱  $(format_elapsed $STEP_ELAPSED)"

# ── Step 8: Start the new VM ─────────────────────────────────────────────────

step "Step 8 – Start the new VM"
STEP_START=$SECONDS

NEW_POWER_STATE=$(az vm get-instance-view \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NEW_VM_NAME" \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" \
  -o tsv 2>/dev/null || echo "unknown")

if [[ "$NEW_POWER_STATE" == "VM running" ]]; then
  echo "VM is already running (started by az vm create)."
else
  echo "Starting '$NEW_VM_NAME'..."
  run az vm start \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NEW_VM_NAME"
  echo "VM started. ✓"
fi

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 8 – Start new VM"); STEP_TIMES+=("$STEP_ELAPSED")
echo "  ⏱  $(format_elapsed $STEP_ELAPSED)"

# ── Step 9: Verify Encryption at Host ────────────────────────────────────────

step "Step 9 – Verify Encryption at Host on new VM"
STEP_START=$SECONDS

EAH_STATUS=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NEW_VM_NAME" \
  --query "securityProfile.encryptionAtHost" -o tsv 2>/dev/null || echo "false")

if [[ "$EAH_STATUS" == "true" ]]; then
  echo "Encryption at Host: ENABLED on '$NEW_VM_NAME'. ✓"
else
  echo "WARNING: Encryption at Host is not confirmed on '$NEW_VM_NAME'." >&2
  echo "Run 04-validate-eah.sh to perform a full validation check." >&2
fi

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 9 – Verify EaH"); STEP_TIMES+=("$STEP_ELAPSED")
echo "  ⏱  $(format_elapsed $STEP_ELAPSED)"

# ── Summary ───────────────────────────────────────────────────────────────────

TOTAL_ELAPSED=$(( SECONDS - MIGRATION_START ))

echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Migration complete!"
echo " New VM '$NEW_VM_NAME' is running with Encryption at Host."
echo " Run 04-validate-eah.sh to perform a full validation."
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Timing Summary"
echo "──────────────────────────────────────────"
for i in "${!STEP_NAMES[@]}"; do
  printf "  %-44s %s\n" "${STEP_NAMES[$i]}" "$(format_elapsed "${STEP_TIMES[$i]}")"
done
echo "──────────────────────────────────────────"
printf "  %-44s %s\n" "Total" "$(format_elapsed "$TOTAL_ELAPSED")"

echo ""
echo "───────────────────────────────────────────────────────────"
echo " CLEANUP – After verifying '$NEW_VM_NAME' works correctly:"
echo "───────────────────────────────────────────────────────────"
echo ""
echo " # The original VM resource was already removed during migration."
echo " # Delete the orphaned original disks once the new VM is confirmed working:"
echo ""
echo " # Delete the original OS disk"
echo " az disk delete --resource-group '$RESOURCE_GROUP' --name '$OS_DISK_NAME' --yes"
while IFS='|' read -r disk_name lun; do
  [[ -z "$disk_name" ]] && continue
  echo " az disk delete --resource-group '$RESOURCE_GROUP' --name '$disk_name' --yes"
done <<< "${DATA_DISK_INFO:-}"
echo ""
echo " # Optionally disable ADE access on the Key Vault (if no longer used for ADE)"
echo " # az keyvault update --name '<KeyVaultName>' --resource-group '$RESOURCE_GROUP' --enabled-for-disk-encryption false"
echo "───────────────────────────────────────────────────────────"
