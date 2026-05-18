# Scale Automation – Fleet-Wide ADE→EaH Migration

This document covers patterns for applying the ADE-to-Encryption at Host migration at scale across multiple VMs and subscriptions. It bridges the gap between the single-VM lab exercises and production-scale operations.

---

## Discovery: Finding Migration Candidates

Before migrating at scale, identify which VMs have ADE enabled and which already use Encryption at Host. Use the discovery scripts included in this lab:

| Script | Path |
|--------|------|
| Azure CLI | [`scripts/cli/00-discover-ade-vms.sh`](../scripts/cli/00-discover-ade-vms.sh) |
| PowerShell | [`scripts/powershell/00-Discover-ADE-VMs.ps1`](../scripts/powershell/00-Discover-ADE-VMs.ps1) |

---

## Parallel Pre-Migration Checks with Run Command

Use `az vm run-command` to verify disk encryption status across multiple VMs simultaneously.

### Bash – Parallel Action Run Commands

```bash
# Query ADE VMs via Resource Graph
ADE_VMS=$(az graph query -q "
  Resources
  | where type =~ 'microsoft.compute/virtualmachines/extensions'
  | where name in ('AzureDiskEncryption','AzureDiskEncryptionForLinux')
  | project vmName = tostring(split(id,'/')[8]), rg = resourceGroup
" --query "data[].{vm:vmName,rg:rg}" -o json)

# Run BitLocker status check in parallel
echo "$ADE_VMS" | jq -c '.[]' | while IFS= read -r entry; do
  VM=$(echo "$entry" | jq -r '.vm')
  RG=$(echo "$entry" | jq -r '.rg')
  echo "Checking $VM in $RG..."
  (az vm run-command invoke -g "$RG" -n "$VM" \
    --command-id RunPowerShellScript \
    --scripts "manage-bde -status C:" \
    --query "value[0].message" -o tsv) &
done
wait
echo "All checks complete."
```

### PowerShell 7 – ForEach-Object -Parallel

```powershell
$adeVMs = Search-AzGraph -Query @"
  Resources
  | where type =~ 'microsoft.compute/virtualmachines/extensions'
  | where name in ('AzureDiskEncryption','AzureDiskEncryptionForLinux')
  | project vmName = tostring(split(id,'/')[8]), rg = resourceGroup
"@

$adeVMs | ForEach-Object -Parallel {
    $result = Invoke-AzVMRunCommand -ResourceGroupName $_.rg -VMName $_.vmName `
        -CommandId 'RunPowerShellScript' `
        -ScriptString "manage-bde -status"
    [PSCustomObject]@{
        VM     = $_.vmName
        RG     = $_.rg
        Status = $result.Value[0].Message
    }
} -ThrottleLimit 10 | Format-Table -AutoSize
```

---

## Managed Run Command (Fire-and-Forget for Large Fleets)

For fleets with hundreds of VMs, use the **Managed Run Command** API which supports async execution and blob-backed output:

```bash
RG="my-resource-group"
for VM in $(az vm list -g "$RG" --query "[].name" -o tsv); do
  az vm run-command create \
    --resource-group "$RG" \
    --vm-name "$VM" \
    --run-command-name "CheckDecryption" \
    --script "manage-bde -status C:" \
    --async-execution true \
    --no-wait
done

# Check results later
for VM in $(az vm list -g "$RG" --query "[].name" -o tsv); do
  echo "=== $VM ==="
  az vm run-command show \
    --resource-group "$RG" \
    --vm-name "$VM" \
    --run-command-name "CheckDecryption" \
    --instance-view \
    --query "instanceView.output" -o tsv
done
```

---

## Key Constraints and Limits

| Constraint | Action Run Command | Managed Run Command |
|-----------|-------------------|---------------------|
| Concurrent per VM | 1 | 25 |
| Timeout | 90 minutes (fixed) | Custom (configurable) |
| Output size | 4 KB | Unlimited (via blob) |
| Async support | No (blocks until done) | Yes (`--async-execution`) |

### ARM API Rate Limits

| Limit | Value |
|-------|-------|
| Read operations | ~12,000 per subscription/hour |
| Write operations | ~1,200 per subscription/hour |

**Recommendation:** Throttle parallel operations to **10 concurrent maximum** to stay within rate limits. For large fleets (100+ VMs), stagger batches with a 30-second delay between groups.

---

## Batch Migration Pattern

For production migrations, combine discovery + validation + migration in batches:

```bash
#!/bin/bash
set -euo pipefail

BATCH_SIZE=10
DELAY_BETWEEN_BATCHES=60  # seconds

# Get migration candidates
CANDIDATES=$(az graph query -q "
  Resources
  | where type =~ 'microsoft.compute/virtualmachines/extensions'
  | where name in ('AzureDiskEncryption','AzureDiskEncryptionForLinux')
  | where properties.provisioningState == 'Succeeded'
  | extend vmName = tostring(split(id,'/')[8])
  | project vmName, rg = resourceGroup
" --query "data" -o json)

TOTAL=$(echo "$CANDIDATES" | jq length)
echo "Found $TOTAL VMs to migrate"

# Process in batches
for ((i=0; i<TOTAL; i+=BATCH_SIZE)); do
  BATCH=$(echo "$CANDIDATES" | jq ".[$i:$((i+BATCH_SIZE))]")
  BATCH_NUM=$(( (i / BATCH_SIZE) + 1 ))
  echo ""
  echo "=== Batch $BATCH_NUM (VMs $((i+1)) to $((i+BATCH_SIZE < TOTAL ? i+BATCH_SIZE : TOTAL))) ==="

  echo "$BATCH" | jq -c '.[]' | while IFS= read -r entry; do
    VM=$(echo "$entry" | jq -r '.vmName')
    RG=$(echo "$entry" | jq -r '.rg')
    echo "  Migrating $VM in $RG..."
    # Uncomment to execute:
    # bash scripts/cli/03-migrate-ade-to-eah.sh "$RG" "$VM" &
  done
  wait

  if [ $((i + BATCH_SIZE)) -lt "$TOTAL" ]; then
    echo "  Waiting ${DELAY_BETWEEN_BATCHES}s before next batch..."
    sleep "$DELAY_BETWEEN_BATCHES"
  fi
done

echo ""
echo "All batches complete."
```

---

## References

- [Run Command overview](https://learn.microsoft.com/en-us/azure/virtual-machines/run-command-overview)
- [az vm run-command create](https://learn.microsoft.com/en-us/cli/azure/vm/run-command#az-vm-run-command-create)
- [Action vs Managed Run Command comparison](https://learn.microsoft.com/en-us/azure/virtual-machines/run-command-overview#compare-feature-support)
- [ARM throttling and rate limits](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/request-limits-and-throttling)
