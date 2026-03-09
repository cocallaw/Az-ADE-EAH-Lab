<#
.SYNOPSIS
    Migrates a VM from Azure Disk Encryption (ADE) to Encryption at Host (EaH).

.DESCRIPTION
    Performs the full migration sequence documented at:
    https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate

    Azure does not allow enabling Encryption at Host on VMs whose disks carry the
    Unified Data Encryption (UDE) flag set by ADE — even after ADE has been disabled.
    Migration therefore requires creating new managed disks and a new VM.  The
    Upload+AzCopy method copies disk data into new managed disk objects that have no
    ADE/UDE metadata, and a new VM is created from those disks with EaH enabled.

    Steps executed:
      1. Verify the EncryptionAtHost subscription feature is Registered.
      2. Verify AzCopy is installed and available in PATH.
      3. Confirm ADE status and capture the original VM configuration.
      4. Disable ADE (Windows: All volumes; Linux: Data volumes only).
         Prompt to confirm OS-level decryption is fully complete before continuing.
      5. Deallocate the original VM.
      6. Create new managed disks (OS + data) via Upload+AzCopy to strip the UDE flag.
      7. Create a new VM using the new disks with Encryption at Host enabled.
      8. Start the new VM.
      9. Verify Encryption at Host is active on the new VM.
     10. Display cleanup commands for the original VM and disks.

    Linux VMs with an ADE-encrypted OS disk cannot have ADE disabled in-place.
    The script detects this case and exits with remediation guidance.

.PARAMETER ResourceGroupName
    Name of the resource group containing the VM.

.PARAMETER VMName
    Name of the virtual machine to migrate.

.PARAMETER NewVMName
    (Optional) Name for the new VM. Defaults to "<VMName>-eah".

.PARAMETER SubscriptionId
    (Optional) Target subscription. Defaults to the current Az context.

.PARAMETER SasExpiryHours
    (Optional) Validity period in hours for SAS URIs used during disk copy. Default: 24.

.PARAMETER WhatIf
    Dry-run mode – shows what would happen without making any changes.

.EXAMPLE
    .\03-Migrate-ADE-to-EAH.ps1 -ResourceGroupName "ade-lab-rg" -VMName "adelab-win-vm"

.EXAMPLE
    .\03-Migrate-ADE-to-EAH.ps1 -ResourceGroupName "ade-lab-rg" -VMName "adelab-win-vm" `
        -NewVMName "adelab-win-vm-eah" -SasExpiryHours 48

.EXAMPLE
    .\03-Migrate-ADE-to-EAH.ps1 -ResourceGroupName "ade-lab-rg" -VMName "adelab-win-vm" -WhatIf

.NOTES
    Requires  : Az.Accounts, Az.Compute, AzCopy v10+ (must be in PATH)
    Reference : https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $false)]
    [string]$NewVMName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 72)]
    [int]$SasExpiryHours = 24
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "──────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "──────────────────────────────────────────" -ForegroundColor DarkGray
}

function Format-Elapsed {
    param([TimeSpan]$Span)
    if ($Span.TotalSeconds -lt 60) { return "$([math]::Round($Span.TotalSeconds,1))s" }
    return "$([math]::Floor($Span.TotalMinutes))m $($Span.Seconds)s"
}

function Copy-DiskViaUpload {
    <#
      Creates a new managed disk without ADE/UDE metadata by writing disk data from a
      source SAS URI directly into a new Upload-mode disk using AzCopy.

      A 512-byte offset is added to UploadSizeInBytes because Azure omits the VHD
      footer when it reports DiskSizeBytes; the copy would fail without this offset.
    #>
    param(
        [string]$SourceDiskName,
        [string]$SourceRG,
        [string]$TargetDiskName,
        [string]$TargetRG,
        [string]$Location,
        [string]$OsType,           # 'Windows', 'Linux', or $null/$empty for data disks
        [string]$HyperVGeneration, # 'V1', 'V2', or $null/$empty for data disks
        [string]$SkuName,
        [int]$SasExpirySeconds
    )

    Write-Host "  Creating new disk '$TargetDiskName' from '$SourceDiskName'..."

    $sourceDisk = Get-AzDisk -ResourceGroupName $SourceRG -DiskName $SourceDiskName

    $diskConfigParams = @{
        Location          = $Location
        CreateOption      = 'Upload'
        UploadSizeInBytes = $sourceDisk.DiskSizeBytes + 512
        SkuName           = $SkuName
    }
    if ($OsType)          { $diskConfigParams['OsType']          = $OsType }
    if ($HyperVGeneration) { $diskConfigParams['HyperVGeneration'] = $HyperVGeneration }

    $diskConfig = New-AzDiskConfig @diskConfigParams
    $targetDisk = New-AzDisk -ResourceGroupName $TargetRG -DiskName $TargetDiskName -Disk $diskConfig

    Write-Host "  Granting SAS access for disk copy..."
    $sourceSAS = Grant-AzDiskAccess -ResourceGroupName $SourceRG -DiskName $SourceDiskName `
                     -Access Read  -DurationInSecond $SasExpirySeconds
    $targetSAS = Grant-AzDiskAccess -ResourceGroupName $TargetRG -DiskName $TargetDiskName `
                     -Access Write -DurationInSecond $SasExpirySeconds

    try {
        Write-Host "  Copying disk data via AzCopy (this may take several minutes)..."
        azcopy copy $sourceSAS.AccessSAS $targetSAS.AccessSAS --blob-type PageBlob
        if ($LASTEXITCODE -ne 0) {
            throw "AzCopy exited with code $LASTEXITCODE. See output above for details."
        }
        Write-Host "  Disk copy complete." -ForegroundColor Green
    }
    finally {
        # Revoke SAS access regardless of success or failure
        Write-Host "  Revoking SAS access..."
        Revoke-AzDiskAccess -ResourceGroupName $SourceRG -DiskName $SourceDiskName `
            -ErrorAction SilentlyContinue | Out-Null
        Revoke-AzDiskAccess -ResourceGroupName $TargetRG -DiskName $TargetDiskName `
            -ErrorAction SilentlyContinue | Out-Null
    }

    return (Get-AzDisk -ResourceGroupName $TargetRG -DiskName $TargetDiskName)
}

$migrationTimer = [System.Diagnostics.Stopwatch]::StartNew()
$stepTimings    = [ordered]@{}

# ── Context ──────────────────────────────────────────────────────────────────

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$ctx = Get-AzContext
if (-not $NewVMName) { $NewVMName = "$VMName-eah" }

Write-Host "Active subscription : $($ctx.Subscription.Name) [$($ctx.Subscription.Id)]" -ForegroundColor Cyan
Write-Host "Resource Group      : $ResourceGroupName"
Write-Host "VM Name (source)    : $VMName"
Write-Host "VM Name (new)       : $NewVMName"

# ── Step 1: Verify EncryptionAtHost feature ───────────────────────────────────

Write-Step "Step 1 – Verify EncryptionAtHost feature registration"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

$feature = Get-AzProviderFeature -FeatureName 'EncryptionAtHost' -ProviderNamespace 'Microsoft.Compute'
if ($feature.RegistrationState -ne 'Registered') {
    Write-Error ("EncryptionAtHost is not Registered on subscription '$($ctx.Subscription.Id)'. " +
        "Run 01-Register-EAH-Feature.ps1 first and wait for registration to complete.")
    exit 1
}
Write-Host "EncryptionAtHost feature: Registered" -ForegroundColor Green

$stepTimer.Stop()
$stepTimings['Step 1 – Verify EaH feature'] = $stepTimer.Elapsed
Write-Host "  ⏱  $(Format-Elapsed $stepTimer.Elapsed)" -ForegroundColor DarkGray

# ── Step 2: Verify AzCopy ─────────────────────────────────────────────────────

Write-Step "Step 2 – Verify AzCopy availability"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

$azCopyCmd = Get-Command azcopy -ErrorAction SilentlyContinue
if (-not $azCopyCmd) {
    Write-Error ("AzCopy was not found in PATH. AzCopy v10+ is required to copy disk data " +
        "without the ADE/UDE metadata flag. Download it from https://aka.ms/downloadazcopy " +
        "and ensure it is available in PATH before re-running this script.")
    exit 1
}
Write-Host "AzCopy found: $($azCopyCmd.Source)" -ForegroundColor Green

$stepTimer.Stop()
$stepTimings['Step 2 – Verify AzCopy'] = $stepTimer.Elapsed
Write-Host "  ⏱  $(Format-Elapsed $stepTimer.Elapsed)" -ForegroundColor DarkGray

# ── Step 3: Confirm ADE status and gather VM configuration ───────────────────

Write-Step "Step 3 – Confirm ADE status and capture VM configuration"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

$vm        = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
$osType    = $vm.StorageProfile.OsDisk.OsType   # 'Windows' or 'Linux'
$dataDisks = $vm.StorageProfile.DataDisks

$adeStatus     = Get-AzVMDiskEncryptionStatus -ResourceGroupName $ResourceGroupName -VMName $VMName
$osEncrypted   = $adeStatus.OsVolumeEncrypted   -eq 'Encrypted'
$dataEncrypted = $adeStatus.DataVolumesEncrypted -eq 'Encrypted'

Write-Host "OS Type              : $osType"
Write-Host "OS disk encrypted    : $osEncrypted  ($($adeStatus.OsVolumeEncrypted))"
Write-Host "Data disks encrypted : $dataEncrypted ($($adeStatus.DataVolumesEncrypted))"

# ADE cannot be disabled on a Linux OS disk. A fresh VM must be built instead.
if ($osType -eq 'Linux' -and $osEncrypted) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║  LINUX VM WITH ENCRYPTED OS DISK – MANUAL MIGRATION REQUIRED   ║" -ForegroundColor Yellow
    Write-Host "╠══════════════════════════════════════════════════════════════════╣" -ForegroundColor Yellow
    Write-Host "║                                                                  ║" -ForegroundColor Yellow
    Write-Host "║  Disabling ADE on a Linux OS disk is not supported. You must:   ║" -ForegroundColor Yellow
    Write-Host "║                                                                  ║" -ForegroundColor Yellow
    Write-Host "║  1. Create a new Linux VM with Encryption at Host enabled.       ║" -ForegroundColor Yellow
    Write-Host "║  2. Reinstall or restore the OS environment on the new VM.       ║" -ForegroundColor Yellow
    Write-Host "║  3. Migrate application data using SCP, rsync, or backup tools.  ║" -ForegroundColor Yellow
    Write-Host "║                                                                  ║" -ForegroundColor Yellow
    Write-Host "║  Reference: https://aka.ms/disk-encryption-migrate              ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# Capture properties needed to recreate the VM
$vmLocation = $vm.Location
$vmSize     = $vm.HardwareProfile.VmSize
$nicIds     = $vm.NetworkProfile.NetworkInterfaces | Select-Object -ExpandProperty Id

$osDisk    = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $vm.StorageProfile.OsDisk.Name
$hyperVGen = if ($osDisk.HyperVGeneration) { $osDisk.HyperVGeneration } else { 'V1' }

Write-Host ""
Write-Host "VM Size       : $vmSize"
Write-Host "Location      : $vmLocation"
Write-Host "HyperV Gen    : $hyperVGen"
Write-Host "NIC count     : $($nicIds.Count)"
Write-Host "OS disk       : $($osDisk.Name)  [$($osDisk.Sku.Name), $([math]::Round($osDisk.DiskSizeBytes/1GB,1)) GiB]"
Write-Host "Data disks    : $($dataDisks.Count)"

$stepTimer.Stop()
$stepTimings['Step 3 – Confirm ADE / capture config'] = $stepTimer.Elapsed
Write-Host "  ⏱  $(Format-Elapsed $stepTimer.Elapsed)" -ForegroundColor DarkGray

# ── Step 4: Disable ADE ───────────────────────────────────────────────────────

Write-Step "Step 4 – Disable ADE and confirm OS-level decryption"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

if ($osEncrypted -or $dataEncrypted) {
    # Linux: only data disks can be disabled in-place (OS disk encrypted case already exited above)
    $volumeType = if ($osType -eq 'Linux') { 'Data' } else { 'All' }

    if ($PSCmdlet.ShouldProcess("$VMName", "Disable-AzVMDiskEncryption -VolumeType $volumeType")) {
        Write-Host "Disabling ADE on '$VMName' (VolumeType: $volumeType). This may take several minutes..."
        Disable-AzVMDiskEncryption -ResourceGroupName $ResourceGroupName -VMName $VMName `
            -VolumeType $volumeType -Force | Out-Null
        Write-Host "ADE disable command succeeded." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  IMPORTANT: The portal now shows 'SSE + PMK' but OS-level decryption" -ForegroundColor Yellow
    Write-Host "  continues in the background and may take time to complete." -ForegroundColor Yellow
    Write-Host ""
    if ($osType -eq 'Windows') {
        Write-Host "  Connect to the VM and run the following as Administrator:" -ForegroundColor Yellow
        Write-Host "    manage-bde -status" -ForegroundColor White
        Write-Host "  All volumes must show 'Fully Decrypted' before you continue." -ForegroundColor Yellow
    }
    else {
        Write-Host "  Connect to the VM and run:" -ForegroundColor Yellow
        Write-Host "    sudo cryptsetup status /dev/mapper/<device-name>" -ForegroundColor White
        Write-Host "    lsblk" -ForegroundColor White
        Write-Host "  No encrypted mappings should remain before you continue." -ForegroundColor Yellow
    }
    Write-Host ""

    if (-not $WhatIfPreference) {
        $answer = Read-Host "  Confirm OS-level decryption is fully complete on '$VMName'. Continue? (yes/no)"
        if ($answer -notmatch '^y(es)?$') {
            Write-Error "Migration stopped. Re-run this script once decryption is confirmed complete."
            exit 1
        }
    }
}
else {
    Write-Host "ADE is not active – disks may still carry the UDE flag from a prior ADE enable/disable cycle." -ForegroundColor Yellow
    Write-Host "Continuing – new disks will be created via the Upload method to ensure no UDE metadata." -ForegroundColor Yellow
}

$stepTimer.Stop()
$stepTimings['Step 4 – Disable ADE'] = $stepTimer.Elapsed
Write-Host "  ⏱  $(Format-Elapsed $stepTimer.Elapsed)" -ForegroundColor DarkGray

# ── Step 5: Deallocate the original VM ───────────────────────────────────────

Write-Step "Step 5 – Deallocate the original VM"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

$vmStatus = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status).Statuses |
    Where-Object { $_.Code -like 'PowerState/*' }

if ($vmStatus.Code -ne 'PowerState/deallocated') {
    if ($PSCmdlet.ShouldProcess("$VMName", "Stop-AzVM (deallocate)")) {
        Write-Host "Stopping and deallocating '$VMName'..."
        Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force | Out-Null
        Write-Host "VM deallocated." -ForegroundColor Green
    }
}
else {
    Write-Host "VM is already deallocated." -ForegroundColor Yellow
}

$stepTimer.Stop()
$stepTimings['Step 5 – Deallocate VM'] = $stepTimer.Elapsed
Write-Host "  ⏱  $(Format-Elapsed $stepTimer.Elapsed)" -ForegroundColor DarkGray

# ── Step 6: Create new managed disks via Upload + AzCopy ─────────────────────

Write-Step "Step 6 – Create new managed disks via Upload+AzCopy (removes UDE flag)"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

# newDiskMap tracks: 'osDisk' → AzDisk; 'data_<lun>' → @{ Disk; Lun }
$newDiskMap    = [ordered]@{}
$sasExpirySecs = $SasExpiryHours * 3600

if ($PSCmdlet.ShouldProcess("$ResourceGroupName disks", "Copy all VM disks via Upload+AzCopy")) {

    # OS disk
    $newOsDiskName = "$($osDisk.Name)-eah"
    Write-Host "OS disk: $($osDisk.Name) → $newOsDiskName"
    $newOsDisk = Copy-DiskViaUpload `
        -SourceDiskName   $osDisk.Name `
        -SourceRG         $ResourceGroupName `
        -TargetDiskName   $newOsDiskName `
        -TargetRG         $ResourceGroupName `
        -Location         $vmLocation `
        -OsType           $osType `
        -HyperVGeneration $hyperVGen `
        -SkuName          $osDisk.Sku.Name `
        -SasExpirySeconds $sasExpirySecs
    $newDiskMap['osDisk'] = $newOsDisk

    # Data disks
    foreach ($dataDiskRef in $dataDisks) {
        $srcDisk         = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $dataDiskRef.Name
        $newDataDiskName = "$($srcDisk.Name)-eah"
        Write-Host "Data disk (LUN $($dataDiskRef.Lun)): $($srcDisk.Name) → $newDataDiskName"
        $newDataDisk = Copy-DiskViaUpload `
            -SourceDiskName   $srcDisk.Name `
            -SourceRG         $ResourceGroupName `
            -TargetDiskName   $newDataDiskName `
            -TargetRG         $ResourceGroupName `
            -Location         $vmLocation `
            -OsType           $null `
            -HyperVGeneration $null `
            -SkuName          $srcDisk.Sku.Name `
            -SasExpirySeconds $sasExpirySecs
        $newDiskMap["data_$($dataDiskRef.Lun)"] = @{ Disk = $newDataDisk; Lun = $dataDiskRef.Lun }
    }

    Write-Host "All new disks created successfully." -ForegroundColor Green
}

$stepTimer.Stop()
$stepTimings['Step 6 – Create new disks'] = $stepTimer.Elapsed
Write-Host "  ⏱  $(Format-Elapsed $stepTimer.Elapsed)" -ForegroundColor DarkGray

# ── Step 7: Create new VM with Encryption at Host ────────────────────────────

Write-Step "Step 7 – Create new VM '$NewVMName' with Encryption at Host"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

if ($PSCmdlet.ShouldProcess("$NewVMName", "New-AzVM with EncryptionAtHost enabled")) {

    # Detach NICs from the original VM so they can be attached to the new VM.
    # The original VM stays deallocated and is not deleted at this stage.
    Write-Host "Detaching NICs from original VM '$VMName' to reuse on new VM..."
    $originalVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
    $originalVm.NetworkProfile.NetworkInterfaces.Clear()
    Update-AzVM -ResourceGroupName $ResourceGroupName -VM $originalVm | Out-Null
    Write-Host "NICs detached." -ForegroundColor Green

    # Build new VM config
    Write-Host "Building VM configuration for '$NewVMName'..."
    $newVmConfig = New-AzVMConfig -VMName $NewVMName -VMSize $vmSize

    # Attach OS disk
    if ($osType -eq 'Windows') {
        $newVmConfig = Set-AzVMOSDisk -VM $newVmConfig `
            -ManagedDiskId $newDiskMap['osDisk'].Id -CreateOption Attach -Windows
    }
    else {
        $newVmConfig = Set-AzVMOSDisk -VM $newVmConfig `
            -ManagedDiskId $newDiskMap['osDisk'].Id -CreateOption Attach -Linux
    }

    # Attach data disks
    foreach ($key in ($newDiskMap.Keys | Where-Object { $_ -ne 'osDisk' })) {
        $entry       = $newDiskMap[$key]
        $newVmConfig = Add-AzVMDataDisk -VM $newVmConfig `
            -ManagedDiskId $entry.Disk.Id -Lun $entry.Lun -CreateOption Attach
    }

    # Reattach NICs (first NIC is primary)
    $isPrimary = $true
    foreach ($nicId in $nicIds) {
        if ($isPrimary) {
            $newVmConfig = Add-AzVMNetworkInterface -VM $newVmConfig -Id $nicId -Primary
        }
        else {
            $newVmConfig = Add-AzVMNetworkInterface -VM $newVmConfig -Id $nicId
        }
        $isPrimary = $false
    }

    # Enable Encryption at Host
    $newVmConfig = Set-AzVMSecurityProfile -VM $newVmConfig -EncryptionAtHost $true

    Write-Host "Creating VM '$NewVMName'..."
    New-AzVM -ResourceGroupName $ResourceGroupName -Location $vmLocation -VM $newVmConfig | Out-Null
    Write-Host "VM '$NewVMName' created with Encryption at Host." -ForegroundColor Green
}

$stepTimer.Stop()
$stepTimings['Step 7 – Create new VM'] = $stepTimer.Elapsed
Write-Host "  ⏱  $(Format-Elapsed $stepTimer.Elapsed)" -ForegroundColor DarkGray

# ── Step 8: Start the new VM ─────────────────────────────────────────────────

Write-Step "Step 8 – Start the new VM"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

$newVmStatus = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $NewVMName -Status `
    -ErrorAction SilentlyContinue).Statuses | Where-Object { $_.Code -like 'PowerState/*' }

if ($newVmStatus.Code -ne 'PowerState/running') {
    if ($PSCmdlet.ShouldProcess("$NewVMName", "Start-AzVM")) {
        Write-Host "Starting '$NewVMName'..."
        Start-AzVM -ResourceGroupName $ResourceGroupName -Name $NewVMName | Out-Null
        Write-Host "VM started." -ForegroundColor Green
    }
}
else {
    Write-Host "VM is already running (started by New-AzVM)." -ForegroundColor Yellow
}

$stepTimer.Stop()
$stepTimings['Step 8 – Start new VM'] = $stepTimer.Elapsed
Write-Host "  ⏱  $(Format-Elapsed $stepTimer.Elapsed)" -ForegroundColor DarkGray

# ── Step 9: Verify Encryption at Host ────────────────────────────────────────

Write-Step "Step 9 – Verify Encryption at Host on new VM"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

$newVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $NewVMName -ErrorAction SilentlyContinue
if ($newVm -and $newVm.SecurityProfile.EncryptionAtHost -eq $true) {
    Write-Host "Encryption at Host: ENABLED on '$NewVMName'." -ForegroundColor Green
}
else {
    Write-Warning ("Encryption at Host is not confirmed on '$NewVMName'. " +
        "Run 04-Validate-EAH.ps1 to perform a full validation check.")
}

$stepTimer.Stop()
$stepTimings['Step 9 – Verify EaH'] = $stepTimer.Elapsed
Write-Host "  ⏱  $(Format-Elapsed $stepTimer.Elapsed)" -ForegroundColor DarkGray

# ── Summary ───────────────────────────────────────────────────────────────────

$migrationTimer.Stop()

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host " Migration complete!" -ForegroundColor Green
Write-Host " New VM '$NewVMName' is running with Encryption at Host." -ForegroundColor Green
Write-Host " Run 04-Validate-EAH.ps1 to perform a full validation." -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "Timing Summary" -ForegroundColor Cyan
Write-Host "──────────────────────────────────────────" -ForegroundColor DarkGray
foreach ($entry in $stepTimings.GetEnumerator()) {
    Write-Host ("  {0,-42} {1}" -f $entry.Key, (Format-Elapsed $entry.Value)) -ForegroundColor DarkGray
}
Write-Host "──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ("  {0,-42} {1}" -f "Total", (Format-Elapsed $migrationTimer.Elapsed)) -ForegroundColor Cyan

Write-Host ""
Write-Host "───────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host " CLEANUP – After verifying '$NewVMName' works correctly:" -ForegroundColor Yellow
Write-Host "───────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host " # Delete the original VM (disks are NOT removed automatically)" -ForegroundColor DarkGray
Write-Host " Remove-AzVM -ResourceGroupName '$ResourceGroupName' -Name '$VMName' -Force" -ForegroundColor White
Write-Host ""
Write-Host " # Delete the original OS disk" -ForegroundColor DarkGray
Write-Host " Remove-AzDisk -ResourceGroupName '$ResourceGroupName' -DiskName '$($osDisk.Name)' -Force" -ForegroundColor White
foreach ($dataDiskRef in $dataDisks) {
    Write-Host " Remove-AzDisk -ResourceGroupName '$ResourceGroupName' -DiskName '$($dataDiskRef.Name)' -Force" -ForegroundColor White
}
Write-Host ""
Write-Host " # Optionally disable ADE access on the Key Vault (if no longer used for ADE)" -ForegroundColor DarkGray
Write-Host " # Update-AzKeyVault -VaultName '<KeyVaultName>' -ResourceGroupName '$ResourceGroupName' -EnabledForDiskEncryption `$false" -ForegroundColor DarkGray
Write-Host "───────────────────────────────────────────────────────────" -ForegroundColor DarkGray
