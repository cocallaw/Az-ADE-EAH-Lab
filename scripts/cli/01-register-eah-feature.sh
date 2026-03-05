#!/usr/bin/env bash
# =============================================================================
# 01-register-eah-feature.sh
#
# Registers the EncryptionAtHost feature on the current Azure subscription.
# This is a one-time, per-subscription prerequisite before Encryption at Host
# can be enabled on any VM.
#
# Usage:
#   bash 01-register-eah-feature.sh [SUBSCRIPTION_ID]
#
# Reference:
#   https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate
# =============================================================================
set -euo pipefail

SUBSCRIPTION_ID="${1:-}"

# ── Context ──────────────────────────────────────────────────────────────────

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  echo "Setting subscription: $SUBSCRIPTION_ID"
  az account set --subscription "$SUBSCRIPTION_ID"
fi

CURRENT_SUB=$(az account show --query "[name, id]" -o tsv | tr '\t' ' / ')
echo "Active subscription: $CURRENT_SUB"

# ── Check current state ───────────────────────────────────────────────────────

STATE=$(az feature show \
  --name EncryptionAtHost \
  --namespace Microsoft.Compute \
  --query "properties.state" -o tsv)

if [[ "$STATE" == "Registered" ]]; then
  echo "EncryptionAtHost is already Registered on this subscription. No action needed."
  exit 0
fi

# ── Register ──────────────────────────────────────────────────────────────────

echo "Registering EncryptionAtHost feature..."
az feature register \
  --name EncryptionAtHost \
  --namespace Microsoft.Compute \
  --output none

# ── Poll until registered ─────────────────────────────────────────────────────

TIMEOUT_MINUTES=15
POLL_INTERVAL=30
ELAPSED=0
MAX_SECONDS=$(( TIMEOUT_MINUTES * 60 ))

echo "Waiting for registration (timeout: ${TIMEOUT_MINUTES}m, polling every ${POLL_INTERVAL}s)..."

while true; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$(( ELAPSED + POLL_INTERVAL ))

  STATE=$(az feature show \
    --name EncryptionAtHost \
    --namespace Microsoft.Compute \
    --query "properties.state" -o tsv)

  echo "  [$(( ELAPSED / 60 ))m] State: $STATE"

  if [[ "$STATE" == "Registered" ]]; then
    break
  fi

  if (( ELAPSED >= MAX_SECONDS )); then
    echo "ERROR: EncryptionAtHost registration did not complete within ${TIMEOUT_MINUTES} minutes." >&2
    echo "Check the Azure Portal and re-run this script." >&2
    exit 1
  fi
done

# ── Re-register provider to propagate ────────────────────────────────────────

echo "Re-registering Microsoft.Compute provider to propagate the feature flag..."
az provider register --namespace Microsoft.Compute --output none

echo ""
echo "EncryptionAtHost feature is now Registered."
echo "You can now deploy the lab VM and run the migration script."
