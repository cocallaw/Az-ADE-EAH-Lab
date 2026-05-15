#!/usr/bin/env bash
# =============================================================================
# 05-enforce-eah-policy.sh
#
# Assigns the built-in Azure Policy that audits (or denies) VMs without
# Encryption at Host enabled, triggers a compliance scan, and lists
# non-compliant resources.
#
# Policy: "Virtual machines and virtual machine scale sets should have
#          encryption at host enabled"
# Policy ID: fc4d8e41-e223-45ea-9bf5-eada37891d87
#
# Usage:
#   bash 05-enforce-eah-policy.sh [SUBSCRIPTION_ID]
#
# Environment variables:
#   POLICY_EFFECT     - "Audit" (default) or "Deny"
#   ASSIGNMENT_NAME   - Custom assignment name (default: enforce-eah-<effect>)
#   SCOPE             - Custom scope (default: /subscriptions/<current sub>)
#   SKIP_SCAN         - Set to "1" to skip the compliance scan wait
#
# Reference:
#   https://learn.microsoft.com/en-us/azure/governance/policy/assign-policy-azurecli
#   https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate
# =============================================================================
set -euo pipefail

SUBSCRIPTION_ID="${1:-}"
POLICY_EFFECT="${POLICY_EFFECT:-Audit}"
POLICY_DEFINITION_ID="fc4d8e41-e223-45ea-9bf5-eada37891d87"

# ── Validate effect ──────────────────────────────────────────────────────────

EFFECT_LOWER=$(echo "$POLICY_EFFECT" | tr '[:upper:]' '[:lower:]')
case "$EFFECT_LOWER" in
  audit) POLICY_EFFECT="Audit" ;;
  deny)  POLICY_EFFECT="Deny"  ;;
  *)
    echo "ERROR: POLICY_EFFECT must be 'Audit' or 'Deny' (got: '$POLICY_EFFECT')" >&2
    exit 1
    ;;
esac

# ── Context ──────────────────────────────────────────────────────────────────

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  echo "Setting subscription: $SUBSCRIPTION_ID"
  az account set --subscription "$SUBSCRIPTION_ID"
fi

CURRENT_SUB_ID=$(az account show --query "id" -o tsv)
CURRENT_SUB_NAME=$(az account show --query "name" -o tsv)
echo "Active subscription: $CURRENT_SUB_NAME ($CURRENT_SUB_ID)"

SCOPE="${SCOPE:-/subscriptions/$CURRENT_SUB_ID}"
ASSIGNMENT_NAME="${ASSIGNMENT_NAME:-enforce-eah-$(echo "$POLICY_EFFECT" | tr '[:upper:]' '[:lower:]')}"
DISPLAY_NAME="Encryption at Host - ${POLICY_EFFECT} All VMs"

echo ""
echo "=== Azure Policy: Encryption at Host Enforcement ==="
echo "  Policy Effect : $POLICY_EFFECT"
echo "  Assignment    : $ASSIGNMENT_NAME"
echo "  Scope         : $SCOPE"
echo ""

# ── Assign policy ────────────────────────────────────────────────────────────

echo "Creating/updating policy assignment..."

az policy assignment create \
  --name "$ASSIGNMENT_NAME" \
  --display-name "$DISPLAY_NAME" \
  --policy "$POLICY_DEFINITION_ID" \
  --scope "$SCOPE" \
  --params "{\"effect\": {\"value\": \"$POLICY_EFFECT\"}}" \
  --output none

echo "Policy assignment '$ASSIGNMENT_NAME' created with effect '$POLICY_EFFECT'."

# ── Trigger compliance scan ──────────────────────────────────────────────────

if [[ "${SKIP_SCAN:-}" == "1" ]]; then
  echo ""
  echo "SKIP_SCAN=1 — skipping compliance scan."
else
  echo ""
  echo "Triggering compliance scan (this may take several minutes)..."
  az policy state trigger-scan --no-wait --output none 2>/dev/null || true

  echo "Waiting for scan to complete..."
  TIMEOUT_MINUTES=10
  POLL_INTERVAL=30
  ELAPSED=0
  MAX_SECONDS=$(( TIMEOUT_MINUTES * 60 ))

  while true; do
    sleep "$POLL_INTERVAL"
    ELAPSED=$(( ELAPSED + POLL_INTERVAL ))

    # Check if any compliance data exists for our assignment
    COUNT=$(az policy state list \
      --policy-assignment "$ASSIGNMENT_NAME" \
      --query "length(@)" -o tsv 2>/dev/null || echo "0")

    if [[ "$COUNT" -gt 0 ]]; then
      echo "  Compliance data available."
      break
    fi

    echo "  [$(( ELAPSED / 60 ))m] Waiting for compliance data..."

    if (( ELAPSED >= MAX_SECONDS )); then
      echo "WARNING: Compliance scan did not produce results within ${TIMEOUT_MINUTES} minutes." >&2
      echo "         Results may still be processing. Run the commands below manually to check." >&2
      break
    fi
  done
fi

# ── List non-compliant resources ─────────────────────────────────────────────

echo ""
echo "Non-compliant resources:"
echo ""

NON_COMPLIANT=$(az policy state list \
  --policy-assignment "$ASSIGNMENT_NAME" \
  --filter "isCompliant eq false" \
  --query "[].{Resource:resourceId, State:complianceState}" \
  -o table 2>/dev/null || echo "")

if [[ -z "$NON_COMPLIANT" || "$NON_COMPLIANT" == *"0 items"* ]]; then
  echo "  No non-compliant resources found. All VMs have Encryption at Host enabled."
else
  echo "$NON_COMPLIANT"
fi

# ── Summary and next steps ───────────────────────────────────────────────────

echo ""
echo "================================================================"

if [[ "$POLICY_EFFECT" == "Audit" ]]; then
  echo " Policy is in AUDIT mode."
  echo ""
  echo " Non-compliant VMs are flagged but NOT blocked."
  echo " After migrating all VMs to Encryption at Host, switch to"
  echo " Deny mode to prevent new VMs without EaH:"
  echo ""
  echo "   POLICY_EFFECT=Deny bash 05-enforce-eah-policy.sh"
  echo ""
  echo " Or update the existing assignment:"
  echo ""
  echo "   az policy assignment update \\"
  echo "     --name '$ASSIGNMENT_NAME' \\"
  echo "     --params '{\"effect\": {\"value\": \"Deny\"}}'"
else
  echo " Policy is in DENY mode."
  echo ""
  echo " New VMs without Encryption at Host will be BLOCKED."
  echo " To switch back to Audit mode:"
  echo ""
  echo "   POLICY_EFFECT=Audit bash 05-enforce-eah-policy.sh"
fi

echo "================================================================"
echo ""
echo "To re-check compliance at any time:"
echo ""
echo "  az policy state list \\"
echo "    --policy-assignment '$ASSIGNMENT_NAME' \\"
echo "    --filter 'isCompliant eq false' \\"
echo "    --query '[].{VM:resourceId, State:complianceState}'"
