#!/usr/bin/env bash
# =============================================================================
# 03b-migrate-linux-os-disk.sh
#
# Migrates a Linux VM with an ADE-encrypted OS disk to Encryption at Host.
#
# Unlike Windows, Azure does not support disabling ADE on a Linux OS disk.
# This script performs an alternative migration path:
#   - Creates a FRESH Linux VM from a marketplace image with EaH enabled
#   - Copies data disks (if any) via Upload+AzCopy to strip UDE metadata
#   - Attaches the copied data disks to the new VM
#   - Provides a post-migration checklist for OS/application reconfiguration
#
# The original VM resource is deleted to release NICs for reuse; original disks
# are preserved as unattached managed disks for reference or rollback.
#
# Steps:
#   1. Verify the EncryptionAtHost subscription feature is Registered.
#   2. Verify azcopy and jq are installed and available in PATH.
#   3. Validate the source VM is Linux with an ADE-encrypted OS disk.
#   4. Capture the original VM configuration (size, location, NICs, data disks).
#   5. Disable ADE on data volumes and confirm decryption is complete.
#   6. Deallocate the original VM.
#   7. Copy data disks via Upload+AzCopy to strip the UDE flag.
#   8. Delete the original VM resource (preserving disks and NICs).
#   9. Create a new Linux VM from a marketplace image with EaH enabled,
#      attaching the copied data disks and reusing the original NICs.
#  10. Start the new VM and verify Encryption at Host is active.
#  11. Print post-migration checklist and cleanup commands.
#
# Usage:
#   bash 03b-migrate-linux-os-disk.sh <RESOURCE_GROUP> <VM_NAME> <SSH_PUBLIC_KEY> [NEW_VM_NAME] [IMAGE] [SUBSCRIPTION_ID]
#
#   SSH_PUBLIC_KEY   Path to SSH public key file OR the key string itself
#   NEW_VM_NAME     Defaults to "<VM_NAME>-eah"
#   IMAGE           Marketplace image URN. Default: Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest
#   SAS_EXPIRY_HOURS (env var) controls SAS URI validity for disk copy. Default: 2
#
# Dry-run (no changes applied):
#   DRY_RUN=1 bash 03b-migrate-linux-os-disk.sh <RESOURCE_GROUP> <VM_NAME> <SSH_PUBLIC_KEY>
#
# Reference:
#   https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate
# =============================================================================
set -euo pipefail

RESOURCE_GROUP="${1:?Usage: $0 <RESOURCE_GROUP> <VM_NAME> <SSH_PUBLIC_KEY> [NEW_VM_NAME] [IMAGE] [SUBSCRIPTION_ID]}"
VM_NAME="${2:?Usage: $0 <RESOURCE_GROUP> <VM_NAME> <SSH_PUBLIC_KEY> [NEW_VM_NAME] [IMAGE] [SUBSCRIPTION_ID]}"
SSH_PUBLIC_KEY="${3:?Usage: $0 <RESOURCE_GROUP> <VM_NAME> <SSH_PUBLIC_KEY> [NEW_VM_NAME] [IMAGE] [SUBSCRIPTION_ID]}"
NEW_VM_NAME="${4:-}"
IMAGE="${5:-Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest}"
SUBSCRIPTION_ID="${6:-}"
DRY_RUN="${DRY_RUN:-0}"
SAS_EXPIRY_HOURS="${SAS_EXPIRY_HOURS:-2}"

[[ -z "$NEW_VM_NAME" ]] && NEW_VM_NAME="${VM_NAME}-eah"

# Validate SAS_EXPIRY_HOURS is between 1 and 72
if ! [[ "$SAS_EXPIRY_HOURS" =~ ^[0-9]+$ ]] || (( SAS_EXPIRY_HOURS < 1 || SAS_EXPIRY_HOURS > 72 )); then
  echo "ERROR: SAS_EXPIRY_HOURS must be an integer between 1 and 72 (got: $SAS_EXPIRY_HOURS)." >&2
  exit 1
fi

# Resolve SSH public key (accept file path or raw key string)
if [[ -f "$SSH_PUBLIC_KEY" ]]; then
  SSH_KEY_DATA=$(cat "$SSH_PUBLIC_KEY")
else
  SSH_KEY_DATA="$SSH_PUBLIC_KEY"
fi

# ── SAS grant tracking and cleanup trap ───────────────────────────────────────
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

# Copy a managed disk via Upload+AzCopy, producing a new disk with no ADE/UDE metadata.
# A 512-byte offset is added to the upload size because Azure omits the VHD footer.
#
# Args: <source_disk_name> <target_disk_name> <sku>
copy_disk_via_upload() {
  local src_disk_name="$1"
  local tgt_disk_name="$2"
  local sku="$3"
  local sas_expiry_secs=$(( SAS_EXPIRY_HOURS * 3600 ))

  echo "  Creating new disk '$tgt_disk_name' from '$src_disk_name'..."

  local src_size_bytes
  src_size_bytes=$(az disk show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$src_disk_name" \
    --query "diskSizeBytes" -o tsv)

  local upload_size=$(( src_size_bytes + 512 ))

  local create_args=(
    az disk create
    --resource-group "$RESOURCE_GROUP"
    --name "$tgt_disk_name"
    --location "$VM_LOCATION"
    --for-upload
    --upload-size-bytes "$upload_size"
    --sku "$sku"
  )

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

# ── Timing setup ──────────────────────────────────────────────────────────────
SCRIPT_START=$SECONDS
STEP_NAMES=()
STEP_TIMES=()

# ── Set subscription context ──────────────────────────────────────────────────
if [[ -n "$SUBSCRIPTION_ID" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║  Linux OS Disk Migration: ADE → Encryption at Host (Fresh OS Path)     ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Source VM       : $VM_NAME"
echo "New VM          : $NEW_VM_NAME"
echo "Resource Group  : $RESOURCE_GROUP"
echo "Image           : $IMAGE"
echo "Dry-run         : $DRY_RUN"
echo ""

# ── Step 1: Verify EncryptionAtHost feature registration ──────────────────────
step "Step 1 – Verify EncryptionAtHost feature is registered"
STEP_START=$SECONDS

EAH_STATE=$(az feature show \
  --namespace "Microsoft.Compute" \
  --name "EncryptionAtHost" \
  --query "properties.state" -o tsv 2>/dev/null || echo "NotRegistered")

if [[ "$EAH_STATE" != "Registered" ]]; then
  echo "ERROR: EncryptionAtHost feature is '$EAH_STATE'. It must be 'Registered'." >&2
  echo "Run 01-register-eah-feature.sh first, then wait for registration to complete." >&2
  exit 1
fi
echo "  EncryptionAtHost feature: Registered ✓"

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 1 – Verify feature registration"); STEP_TIMES+=("$STEP_ELAPSED")

# ── Step 2: Verify tool dependencies ─────────────────────────────────────────
step "Step 2 – Verify tool dependencies (azcopy, jq)"
STEP_START=$SECONDS

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is not installed or not in PATH." >&2
  echo "Install: https://jqlang.github.io/jq/download/" >&2
  exit 1
fi
echo "  jq: $(jq --version) ✓"

if ! command -v azcopy &>/dev/null; then
  echo "ERROR: azcopy is not installed or not in PATH." >&2
  echo "Install: https://aka.ms/downloadazcopy" >&2
  exit 1
fi
echo "  azcopy: $(azcopy --version | head -1) ✓"

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 2 – Verify dependencies"); STEP_TIMES+=("$STEP_ELAPSED")

# ── Step 3: Validate source VM is Linux with ADE-encrypted OS disk ────────────
step "Step 3 – Validate source VM (Linux + ADE-encrypted OS disk)"
STEP_START=$SECONDS

VM_JSON=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  -o json)

OS_TYPE=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.osType')
if [[ "$OS_TYPE" != "Linux" ]]; then
  echo "ERROR: VM '$VM_NAME' has OS type '$OS_TYPE'. This script is for Linux VMs only." >&2
  echo "For Windows VMs, use 03-migrate-ade-to-eah.sh instead." >&2
  exit 1
fi

VM_SIZE=$(echo "$VM_JSON" | jq -r '.hardwareProfile.vmSize')
VM_LOCATION=$(echo "$VM_JSON" | jq -r '.location')
ADMIN_USER=$(echo "$VM_JSON" | jq -r '.osProfile.adminUsername')
NIC_IDS=$(echo "$VM_JSON" | jq -r '.networkProfile.networkInterfaces[].id')
OS_DISK_NAME=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.name')

# Capture data disk info (name, LUN, SKU)
DATA_DISK_INFO=$(echo "$VM_JSON" | jq -r '.storageProfile.dataDisks[] | "\(.name)|\(.lun)"' 2>/dev/null || true)

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
echo "VM Size              : $VM_SIZE"
echo "Location             : $VM_LOCATION"
echo "Admin user           : $ADMIN_USER"
echo "OS disk              : $OS_DISK_NAME"
echo "NIC count            : $(echo "$NIC_IDS" | grep -c . || true)"
echo "Data disk count      : $(echo "$DATA_DISK_INFO" | grep -c . 2>/dev/null || echo 0)"

if [[ "$OS_ENC" != "Encrypted" ]]; then
  echo ""
  echo "ERROR: OS disk is not ADE-encrypted ('$OS_ENC')." >&2
  echo "This script is for Linux VMs with ADE-encrypted OS disks that cannot be" >&2
  echo "disabled. Use 03-migrate-ade-to-eah.sh instead (standard non-destructive path)." >&2
  exit 1
fi

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 3 – Validate source VM"); STEP_TIMES+=("$STEP_ELAPSED")

# ── Step 4: Disable ADE on data volumes ───────────────────────────────────────
step "Step 4 – Disable ADE on data volumes"
STEP_START=$SECONDS

if [[ -n "$DATA_DISK_INFO" && "$DATA_ENC" == "Encrypted" ]]; then
  echo "  Disabling ADE on data volumes (VolumeType=Data)..."
  run az vm encryption disable \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --volume-type Data \
    --output none

  if [[ "$DRY_RUN" != "1" ]]; then
    echo ""
    echo "  ADE data-volume decryption initiated. This can take 10–30+ minutes."
    echo "  Polling decryption status..."
    poll_timeout=1800; poll_elapsed=0; poll_interval=30; decrypted=false
    while (( poll_elapsed < poll_timeout )); do
      sleep $poll_interval
      poll_elapsed=$(( poll_elapsed + poll_interval ))
      CURRENT_DATA_ENC=$(az vm encryption show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --query "dataDisk" -o tsv 2>/dev/null || echo "Unknown")
      if [[ "$CURRENT_DATA_ENC" == "NotEncrypted" ]]; then
        decrypted=true
        break
      fi
      echo "    Waiting... (${poll_elapsed}s elapsed, status: $CURRENT_DATA_ENC)"
    done

    if [[ "$decrypted" == "true" ]]; then
      echo "  ADE data-volume decryption complete. ✓"
    else
      echo "  ⚠️  Timeout reached (${poll_timeout}s). Decryption may still be in progress." >&2
      echo "  Verify manually before continuing." >&2
    fi
    echo ""
    echo "  ⚠️  Confirm decryption is fully complete before continuing."
    echo "     SSH into the VM or check via portal → Run Command:"
    echo "       lsblk -f   (look for 'crypto_LUKS' → should be gone on data volumes)"
    echo ""
    read -rp "  Press ENTER when decryption is confirmed complete (or Ctrl+C to abort)... "
  fi
else
  echo "  No encrypted data disks or data volumes already decrypted. Skipping."
fi

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 4 – Disable ADE on data volumes"); STEP_TIMES+=("$STEP_ELAPSED")

# ── Step 5: Deallocate the original VM ────────────────────────────────────────
step "Step 5 – Deallocate original VM"
STEP_START=$SECONDS

echo "  Deallocating VM '$VM_NAME'..."
run az vm deallocate \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME"
echo "  VM deallocated. ✓"

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 5 – Deallocate VM"); STEP_TIMES+=("$STEP_ELAPSED")

# ── Step 6: Copy data disks via Upload+AzCopy ─────────────────────────────────
step "Step 6 – Copy data disks via Upload+AzCopy (strip UDE metadata)"
STEP_START=$SECONDS

NEW_DATA_DISK_ARGS=()

if [[ -n "$DATA_DISK_INFO" ]]; then
  while IFS='|' read -r DISK_NAME LUN; do
    [[ -z "$DISK_NAME" ]] && continue

    DISK_SKU=$(az disk show \
      --resource-group "$RESOURCE_GROUP" \
      --name "$DISK_NAME" \
      --query "sku.name" -o tsv)

    NEW_DISK_NAME="${NEW_VM_NAME}-data-lun${LUN}"
    copy_disk_via_upload "$DISK_NAME" "$NEW_DISK_NAME" "$DISK_SKU"
    NEW_DATA_DISK_ARGS+=("$NEW_DISK_NAME=$LUN")
  done <<< "$DATA_DISK_INFO"
  echo ""
  echo "  All data disks copied. ✓"
else
  echo "  No data disks to copy."
fi

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 6 – Copy data disks"); STEP_TIMES+=("$STEP_ELAPSED")

# ── Step 7: Delete original VM resource (preserve disks + NICs) ───────────────
step "Step 7 – Delete original VM resource (preserving disks and NICs)"
STEP_START=$SECONDS

echo "  Setting NIC, OS disk, and data disk delete options to 'Detach' so they survive VM removal..."
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

echo "  Deleting VM resource '$VM_NAME' (disks and NICs are preserved)..."
run az vm delete \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --yes \
  --output none
echo "  Original VM resource deleted. ✓"

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 7 – Delete original VM"); STEP_TIMES+=("$STEP_ELAPSED")

# ── Step 8: Create new VM with EaH from marketplace image ─────────────────────
step "Step 8 – Create new Linux VM with Encryption at Host enabled"
STEP_START=$SECONDS

echo "  Creating VM '$NEW_VM_NAME' from image '$IMAGE'..."
echo "  VM Size: $VM_SIZE | Location: $VM_LOCATION | EaH: enabled"

CREATE_ARGS=(
  az vm create
  --resource-group "$RESOURCE_GROUP"
  --name "$NEW_VM_NAME"
  --image "$IMAGE"
  --size "$VM_SIZE"
  --location "$VM_LOCATION"
  --encryption-at-host true
  --admin-username "$ADMIN_USER"
  --ssh-key-value "$SSH_KEY_DATA"
  --nics $(echo "$NIC_IDS" | tr '\n' ' ')
  --os-disk-name "${NEW_VM_NAME}-osdisk"
  --output none
)

run "${CREATE_ARGS[@]}"

# Attach copied data disks
if [[ ${#NEW_DATA_DISK_ARGS[@]} -gt 0 ]]; then
  echo "  Attaching data disks..."
  for disk_lun_pair in "${NEW_DATA_DISK_ARGS[@]}"; do
    DISK_NAME="${disk_lun_pair%%=*}"
    DISK_LUN="${disk_lun_pair##*=}"
    run az vm disk attach \
      --resource-group "$RESOURCE_GROUP" \
      --vm-name "$NEW_VM_NAME" \
      --name "$DISK_NAME" \
      --lun "$DISK_LUN" \
      --output none
    echo "    Attached '$DISK_NAME' at LUN $DISK_LUN ✓"
  done
fi

echo "  VM '$NEW_VM_NAME' created with Encryption at Host. ✓"

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 8 – Create new VM"); STEP_TIMES+=("$STEP_ELAPSED")

# ── Step 9: Start VM and verify EaH ──────────────────────────────────────────
step "Step 9 – Verify Encryption at Host is active"
STEP_START=$SECONDS

if [[ "$DRY_RUN" == "1" ]]; then
  echo "  [DRY RUN] Skipping verification — VM was not created."
else
  EAH_ENABLED=$(az vm show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NEW_VM_NAME" \
    --query "securityProfile.encryptionAtHost" -o tsv 2>/dev/null || echo "false")

  if [[ "$EAH_ENABLED" == "true" ]]; then
    echo "  ✅ Encryption at Host is ENABLED on '$NEW_VM_NAME'."
  else
    echo "  ⚠️  Encryption at Host is '$EAH_ENABLED'. Verify VM creation succeeded." >&2
  fi
fi

STEP_ELAPSED=$(( SECONDS - STEP_START ))
STEP_NAMES+=("Step 9 – Verify EaH"); STEP_TIMES+=("$STEP_ELAPSED")

# ── Step 10: Post-migration checklist ─────────────────────────────────────────
step "Step 10 – Post-migration checklist"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║  POST-MIGRATION: OS/APPLICATION RECONFIGURATION REQUIRED               ║"
echo "╠══════════════════════════════════════════════════════════════════════════╣"
echo "║                                                                          ║"
echo "║  The new VM has a FRESH OS. Data disks have been migrated, but the OS    ║"
echo "║  must be reconfigured manually. Complete these steps:                    ║"
echo "║                                                                          ║"
echo "║  1. SSH into the new VM:                                                 ║"
echo "║     ssh $ADMIN_USER@<PUBLIC_IP>                                          ║"
echo "║                                                                          ║"
echo "║  2. Mount data disks:                                                    ║"
echo "║     - Run: lsblk -f && blkid                                            ║"
echo "║     - Mount disks manually: mount /dev/sdX /mnt/data                     ║"
echo "║     - Add data-disk entries to /etc/fstab using UUID or                  ║"
echo "║       /dev/disk/azure/scsi1/lunX paths with 'nofail' option              ║"
echo "║     - Do NOT copy old root/boot fstab entries                            ║"
echo "║                                                                          ║"
echo "║  3. Reinstall application packages:                                      ║"
echo "║     - Refer to old VM package list (dpkg-query -W / rpm -qa)             ║"
echo "║     - Restore /etc configs, cron jobs, systemd units as needed           ║"
echo "║                                                                          ║"
echo "║  4. Verify application functionality and connectivity                    ║"
echo "║                                                                          ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# ── Cleanup commands ──────────────────────────────────────────────────────────
echo "────────────────────────────────────────────────────────────────────────────"
echo "CLEANUP (run manually after verifying the new VM is working correctly):"
echo "────────────────────────────────────────────────────────────────────────────"
echo ""
echo "# Delete original OS disk:"
echo "az disk delete --resource-group \"$RESOURCE_GROUP\" --name \"$OS_DISK_NAME\" --yes"
echo ""
if [[ -n "$DATA_DISK_INFO" ]]; then
  echo "# Delete original data disks:"
  while IFS='|' read -r DISK_NAME LUN; do
    [[ -z "$DISK_NAME" ]] && continue
    echo "az disk delete --resource-group \"$RESOURCE_GROUP\" --name \"$DISK_NAME\" --yes"
  done <<< "$DATA_DISK_INFO"
  echo ""
fi

# ── Timing summary ───────────────────────────────────────────────────────────
TOTAL_ELAPSED=$(( SECONDS - SCRIPT_START ))
echo "════════════════════════════════════════════════════════════════════════════"
echo "TIMING SUMMARY"
echo "════════════════════════════════════════════════════════════════════════════"
for i in "${!STEP_NAMES[@]}"; do
  printf "  %-45s %s\n" "${STEP_NAMES[$i]}" "$(format_elapsed "${STEP_TIMES[$i]}")"
done
echo "  ─────────────────────────────────────────────────────────"
printf "  %-45s %s\n" "Total" "$(format_elapsed $TOTAL_ELAPSED)"
echo ""
echo "Migration complete. ✓"
