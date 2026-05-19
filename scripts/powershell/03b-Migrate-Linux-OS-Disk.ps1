<#
.SYNOPSIS
    Migrates a Linux VM with an ADE-encrypted OS disk to Encryption at Host.

.DESCRIPTION
    Unlike Windows, Azure does not support disabling ADE on a Linux OS disk.
    This script performs an alternative migration path:
      - Creates a FRESH Linux VM from a marketplace image with EaH enabled
      - Copies data disks (if any) via Upload+AzCopy to strip UDE metadata
      - Attaches the copied data disks to the new VM
      - Provides a post-migration checklist for OS/application reconfiguration

    The original VM resource is deleted to release NICs for reuse; original
    disks are preserved as unattached managed disks for reference or rollback.

    Steps executed:
      1. Verify the EncryptionAtHost subscription feature is Registered.
      2. Verify AzCopy is installed and available in PATH.
      3. Validate the source VM is Linux with an ADE-encrypted OS disk.
      4. Capture the original VM configuration (size, location, NICs, data disks).
      5. Disable ADE on data volumes and confirm decryption is complete.
      6. Deallocate the original VM.
      7. Copy data disks via Upload+AzCopy to strip the UDE flag.
      8. Delete the original VM resource (preserving disks and NICs).
      9. Create a new Linux VM from a marketplace image with EaH enabled.
     10. Verify Encryption at Host is active on the new VM.
     11. Print post-migration checklist and cleanup commands.

    Linux VMs with an ADE-encrypted OS disk cannot have ADE disabled. The OS
    disk is NOT copied; instead, a fresh OS is deployed. Only data disks are
    migrated via the Upload+AzCopy method.

.PARAMETER ResourceGroupName
    Name of the resource group containing the VM.

.PARAMETER VMName
    Name of the virtual machine to migrate.

.PARAMETER SshPublicKey
    SSH public key string or path to a .pub file for the new VM.

.PARAMETER NewVMName
    (Optional) Name for the new VM. Defaults to "<VMName>-eah".

.PARAMETER Image
    (Optional) Marketplace image URN for the new VM OS.
    Default: Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest

.PARAMETER SubscriptionId
    (Optional) Target subscription. Defaults to the current Az context.

.PARAMETER SasExpiryHours
    (Optional) Validity period in hours for SAS URIs used during disk copy. Default: 2.
    For disks larger than 512 GiB, increase to 6-24 hours.

.PARAMETER WhatIf
    Dry-run mode – shows what would happen without making any changes.

.EXAMPLE
    .\03b-Migrate-Linux-OS-Disk.ps1 -ResourceGroupName "ade-lab-rg" -VMName "adelab-lnx-vm" `
        -SshPublicKey "~/.ssh/id_rsa.pub"

.EXAMPLE
    .\03b-Migrate-Linux-OS-Disk.ps1 -ResourceGroupName "ade-lab-rg" -VMName "adelab-lnx-vm" `
        -SshPublicKey "ssh-rsa AAAA..." -NewVMName "adelab-lnx-vm-eah"

.EXAMPLE
    .\03b-Migrate-Linux-OS-Disk.ps1 -ResourceGroupName "ade-lab-rg" -VMName "adelab-lnx-vm" `
        -SshPublicKey "~/.ssh/id_rsa.pub" -WhatIf

.NOTES
    Requires  : Az.Accounts, Az.Compute, AzCopy v10+ (must be in PATH)
    Reference : https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption-migrate
#>

#Requires -Modules Az.Accounts, Az.Compute

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SshPublicKey,

    [string]$NewVMName,

    [string]$Image = "Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest",

    [string]$SubscriptionId,

    [ValidateRange(1, 72)]
    [int]$SasExpiryHours = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve defaults ──────────────────────────────────────────────────────────
if (-not $NewVMName) { $NewVMName = "$VMName-eah" }

# Resolve SSH public key (accept file path or raw key string)
$isFilePath = $false
try {
    $isFilePath = Test-Path $SshPublicKey -PathType Leaf -ErrorAction SilentlyContinue
} catch {
    # Not a valid path — treat as raw key
}

if ($isFilePath) {
    $SshKeyData = (Get-Content $SshPublicKey -Raw).Trim()
} else {
    $SshKeyData = $SshPublicKey
}

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Step {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message
    )
    Write-Host ""
    Write-Host "──────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "──────────────────────────────────────────" -ForegroundColor DarkGray
}

function Format-Elapsed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [TimeSpan]$Span
    )
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceDiskName,
        [Parameter(Mandatory)][string]$TargetDiskName,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Sku,
        [Parameter(Mandatory)][int]$SasExpirySec
    )

    Write-Host "  Creating new disk '$TargetDiskName' from '$SourceDiskName'..."

    $srcDisk       = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $SourceDiskName
    $srcSizeBytes  = $srcDisk.DiskSizeBytes
    $uploadSize    = $srcSizeBytes + 512

    $diskConfig = New-AzDiskConfig `
        -Location $Location `
        -CreateOption Upload `
        -UploadSizeInBytes $uploadSize `
        -SkuName $Sku

    if ($PSCmdlet.ShouldProcess($TargetDiskName, "Create upload disk")) {
        New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $TargetDiskName -Disk $diskConfig | Out-Null
    } else {
        return
    }

    Write-Host "  Granting SAS access for disk copy..."
    $srcSas = (Grant-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $SourceDiskName `
        -Access Read -DurationInSecond $SasExpirySec).AccessSAS
    $tgtSas = (Grant-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $TargetDiskName `
        -Access Write -DurationInSecond $SasExpirySec).AccessSAS

    Write-Host "  Copying disk data via AzCopy (this may take several minutes)..."
    $azcopyResult = & azcopy copy $srcSas $tgtSas --blob-type PageBlob 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "AzCopy failed for disk '$SourceDiskName': $azcopyResult"
    }

    Write-Host "  Revoking SAS access..."
    Revoke-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $SourceDiskName | Out-Null
    Revoke-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $TargetDiskName | Out-Null
    Write-Host "  Disk copy complete. ✓"
}

# ── Timing setup ──────────────────────────────────────────────────────────────
$scriptTimer = [System.Diagnostics.Stopwatch]::StartNew()
$stepTimings = @()

# ── Set subscription context ──────────────────────────────────────────────────
if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Linux OS Disk Migration: ADE → Encryption at Host (Fresh OS Path)     ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Source VM       : $VMName"
Write-Host "New VM          : $NewVMName"
Write-Host "Resource Group  : $ResourceGroupName"
Write-Host "Image           : $Image"
Write-Host ""

# ── Step 1: Verify EncryptionAtHost feature registration ──────────────────────
Write-Step "Step 1 – Verify EncryptionAtHost feature is registered"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

$eahFeature = Get-AzProviderFeature -ProviderNamespace "Microsoft.Compute" -FeatureName "EncryptionAtHost"
if ($eahFeature.RegistrationState -ne 'Registered') {
    Write-Error "EncryptionAtHost feature is '$($eahFeature.RegistrationState)'. Run 01-Register-EAH-Feature.ps1 first."
}
Write-Host "  EncryptionAtHost feature: Registered ✓"

$stepTimer.Stop()
$stepTimings += [PSCustomObject]@{ Name = "Step 1 – Verify feature registration"; Elapsed = $stepTimer.Elapsed }

# ── Step 2: Verify AzCopy dependency ─────────────────────────────────────────
Write-Step "Step 2 – Verify AzCopy is available"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

$azcopyPath = Get-Command azcopy -ErrorAction SilentlyContinue
if (-not $azcopyPath) {
    Write-Error "AzCopy is not installed or not in PATH. Download from https://aka.ms/downloadazcopy"
}
$azcopyVer = & azcopy --version 2>&1 | Select-Object -First 1
Write-Host "  AzCopy: $azcopyVer ✓"

$stepTimer.Stop()
$stepTimings += [PSCustomObject]@{ Name = "Step 2 – Verify dependencies"; Elapsed = $stepTimer.Elapsed }

# ── Step 3: Validate source VM is Linux with ADE-encrypted OS disk ────────────
Write-Step "Step 3 – Validate source VM (Linux + ADE-encrypted OS disk)"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
$osType = $vm.StorageProfile.OsDisk.OsType

if ($osType -ne 'Linux') {
    Write-Error "VM '$VMName' has OS type '$osType'. This script is for Linux VMs only. Use 03-Migrate-ADE-to-EAH.ps1 for Windows."
}

$adeStatus     = Get-AzVMDiskEncryptionStatus -ResourceGroupName $ResourceGroupName -VMName $VMName
$osEncrypted   = $adeStatus.OsVolumeEncrypted -eq 'Encrypted'
$dataEncrypted = $adeStatus.DataVolumesEncrypted -eq 'Encrypted'

$vmSize     = $vm.HardwareProfile.VmSize
$vmLocation = $vm.Location
$adminUser  = $vm.OSProfile.AdminUsername
$nicIds     = @($vm.NetworkProfile.NetworkInterfaces | Select-Object -ExpandProperty Id)
$osDiskName = $vm.StorageProfile.OsDisk.Name
$dataDisks  = $vm.StorageProfile.DataDisks

Write-Host "OS Type              : $osType"
Write-Host "OS disk encrypted    : $osEncrypted ($($adeStatus.OsVolumeEncrypted))"
Write-Host "Data disks encrypted : $dataEncrypted ($($adeStatus.DataVolumesEncrypted))"
Write-Host "VM Size              : $vmSize"
Write-Host "Location             : $vmLocation"
Write-Host "Admin user           : $adminUser"
Write-Host "OS disk              : $osDiskName"
Write-Host "NIC count            : $($nicIds.Count)"
Write-Host "Data disk count      : $($dataDisks.Count)"

if (-not $osEncrypted) {
    Write-Host ""
    Write-Error "OS disk is not ADE-encrypted. This script is for Linux VMs with ADE-encrypted OS disks that cannot be disabled. Use 03-Migrate-ADE-to-EAH.ps1 instead (standard non-destructive path)."
    exit 1
}

$stepTimer.Stop()
$stepTimings += [PSCustomObject]@{ Name = "Step 3 – Validate source VM"; Elapsed = $stepTimer.Elapsed }

# ── Step 4: Disable ADE on data volumes ───────────────────────────────────────
Write-Step "Step 4 – Disable ADE on data volumes"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

if ($dataDisks.Count -gt 0 -and $dataEncrypted) {
    Write-Host "  Disabling ADE on data volumes (VolumeType=Data)..."
    if ($PSCmdlet.ShouldProcess($VMName, "Disable ADE on data volumes")) {
        Disable-AzVMDiskEncryption -ResourceGroupName $ResourceGroupName -VMName $VMName `
            -VolumeType Data -Force | Out-Null

        Write-Host "  ADE data-volume decryption initiated. Waiting for completion..."
        $timeout = 1800
        $elapsed = 0
        $interval = 30
        $decrypted = $false
        while ($elapsed -lt $timeout) {
            Start-Sleep -Seconds $interval
            $elapsed += $interval
            $currentStatus = Get-AzVMDiskEncryptionStatus -ResourceGroupName $ResourceGroupName -VMName $VMName
            if ($currentStatus.DataVolumesEncrypted -eq 'NotEncrypted') {
                $decrypted = $true
                break
            }
            Write-Host "    Waiting... ($elapsed`s elapsed, status: $($currentStatus.DataVolumesEncrypted))"
        }

        if ($decrypted) {
            Write-Host "  ADE data-volume decryption complete. ✓" -ForegroundColor Green
        } else {
            Write-Host "  ⚠️  Timeout reached (${timeout}s). Decryption may still be in progress." -ForegroundColor Yellow
            Write-Host "  Verify manually before continuing." -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  ⚠️  Confirm decryption is fully complete at the OS level." -ForegroundColor Yellow
        Write-Host "     SSH into the VM and run: lsblk -f" -ForegroundColor Yellow
        Write-Host "     (crypto_LUKS should be gone from data volumes)" -ForegroundColor Yellow
        Write-Host ""
        Read-Host "  Press ENTER when decryption is confirmed complete (or Ctrl+C to abort)"
    }
} else {
    Write-Host "  No encrypted data disks or data volumes already decrypted. Skipping."
}

$stepTimer.Stop()
$stepTimings += [PSCustomObject]@{ Name = "Step 4 – Disable ADE on data volumes"; Elapsed = $stepTimer.Elapsed }

# ── Step 5: Deallocate the original VM ────────────────────────────────────────
Write-Step "Step 5 – Deallocate original VM"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host "  Deallocating VM '$VMName'..."
if ($PSCmdlet.ShouldProcess($VMName, "Deallocate VM")) {
    Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force | Out-Null
}
Write-Host "  VM deallocated. ✓"

$stepTimer.Stop()
$stepTimings += [PSCustomObject]@{ Name = "Step 5 – Deallocate VM"; Elapsed = $stepTimer.Elapsed }

# ── Step 6: Copy data disks via Upload+AzCopy ─────────────────────────────────
Write-Step "Step 6 – Copy data disks via Upload+AzCopy (strip UDE metadata)"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

$newDataDisks = @()
$sasExpirySec = $SasExpiryHours * 3600

if ($dataDisks.Count -gt 0) {
    foreach ($dd in $dataDisks) {
        $srcDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $dd.Name
        $newDiskName = "$NewVMName-data-lun$($dd.Lun)"

        Copy-DiskViaUpload `
            -SourceDiskName $dd.Name `
            -TargetDiskName $newDiskName `
            -Location $vmLocation `
            -Sku $srcDisk.Sku.Name `
            -SasExpirySec $sasExpirySec

        $newDataDisks += [PSCustomObject]@{ Name = $newDiskName; Lun = $dd.Lun }
    }
    Write-Host ""
    Write-Host "  All data disks copied. ✓"
} else {
    Write-Host "  No data disks to copy."
}

$stepTimer.Stop()
$stepTimings += [PSCustomObject]@{ Name = "Step 6 – Copy data disks"; Elapsed = $stepTimer.Elapsed }

# ── Step 7: Delete original VM resource (preserve disks + NICs) ───────────────
Write-Step "Step 7 – Delete original VM resource (preserving disks and NICs)"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

if ($PSCmdlet.ShouldProcess($VMName, "Delete VM resource")) {
    # Ensure NICs and disks survive VM deletion by setting deleteOption to Detach.
    $vmUpdate = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
    foreach ($nicRef in $vmUpdate.NetworkProfile.NetworkInterfaces) {
        $nicRef.DeleteOption = 'Detach'
    }
    $vmUpdate.StorageProfile.OsDisk.DeleteOption = 'Detach'
    foreach ($dd in $vmUpdate.StorageProfile.DataDisks) {
        $dd.DeleteOption = 'Detach'
    }
    Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vmUpdate | Out-Null
    Write-Host "  Deleting VM resource '$VMName' (disks and NICs are preserved)..."
    Remove-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force | Out-Null
    Write-Host "  Original VM resource deleted. ✓"
}

$stepTimer.Stop()
$stepTimings += [PSCustomObject]@{ Name = "Step 7 – Delete original VM"; Elapsed = $stepTimer.Elapsed }

# ── Step 8: Create new VM with EaH from marketplace image ─────────────────────
Write-Step "Step 8 – Create new Linux VM with Encryption at Host enabled"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host "  Creating VM '$NewVMName' from image '$Image'..."
Write-Host "  VM Size: $vmSize | Location: $vmLocation | EaH: enabled"

if ($PSCmdlet.ShouldProcess($NewVMName, "Create VM with Encryption at Host")) {
    # Parse image URN
    $imageParts = $Image -split ':'
    $imageRef = @{
        Publisher = $imageParts[0]
        Offer     = $imageParts[1]
        Sku       = $imageParts[2]
        Version   = $imageParts[3]
    }

    # Build VM config
    $vmConfig = New-AzVMConfig -VMName $NewVMName -VMSize $vmSize -EncryptionAtHost

    # OS profile with SSH
    $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux `
        -ComputerName $NewVMName -Credential (New-Object PSCredential($adminUser, (ConvertTo-SecureString "Placeholder-Not-Used!" -AsPlainText -Force))) `
        -DisablePasswordAuthentication

    # SSH key
    $vmConfig = Add-AzVMSshPublicKey -VM $vmConfig `
        -KeyData $SshKeyData `
        -Path "/home/$adminUser/.ssh/authorized_keys"

    # Image
    $vmConfig = Set-AzVMSourceImage -VM $vmConfig `
        -PublisherName $imageRef.Publisher `
        -Offer $imageRef.Offer `
        -Skus $imageRef.Sku `
        -Version $imageRef.Version

    # OS disk
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig `
        -Name "$NewVMName-osdisk" `
        -CreateOption FromImage

    # NICs
    $primaryNic = $true
    foreach ($nicId in $nicIds) {
        $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nicId -Primary:$primaryNic
        $primaryNic = $false
    }

    # Create the VM
    New-AzVM -ResourceGroupName $ResourceGroupName -Location $vmLocation -VM $vmConfig | Out-Null

    # Attach data disks
    if ($newDataDisks.Count -gt 0) {
        Write-Host "  Attaching data disks..."
        $updatedVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $NewVMName
        foreach ($dd in $newDataDisks) {
            $disk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $dd.Name
            $updatedVm = Add-AzVMDataDisk -VM $updatedVm -Name $dd.Name -ManagedDiskId $disk.Id `
                -Lun $dd.Lun -CreateOption Attach
            Write-Host "    Attached '$($dd.Name)' at LUN $($dd.Lun) ✓"
        }
        Update-AzVM -ResourceGroupName $ResourceGroupName -VM $updatedVm | Out-Null
    }
}

Write-Host "  VM '$NewVMName' created with Encryption at Host. ✓"

$stepTimer.Stop()
$stepTimings += [PSCustomObject]@{ Name = "Step 8 – Create new VM"; Elapsed = $stepTimer.Elapsed }

# ── Step 9: Verify EaH ───────────────────────────────────────────────────────
Write-Step "Step 9 – Verify Encryption at Host is active"
$stepTimer = [System.Diagnostics.Stopwatch]::StartNew()

if (-not $WhatIfPreference) {
    $newVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $NewVMName
    $eahEnabled = $newVm.SecurityProfile.EncryptionAtHost

    if ($eahEnabled) {
        Write-Host "  ✅ Encryption at Host is ENABLED on '$NewVMName'."
    } else {
        Write-Host "  ⚠️  Encryption at Host is not confirmed. Verify VM creation." -ForegroundColor Yellow
    }
}

$stepTimer.Stop()
$stepTimings += [PSCustomObject]@{ Name = "Step 9 – Verify EaH"; Elapsed = $stepTimer.Elapsed }

# ── Step 10: Post-migration checklist ─────────────────────────────────────────
Write-Step "Step 10 – Post-migration checklist"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║  POST-MIGRATION: OS/APPLICATION RECONFIGURATION REQUIRED               ║" -ForegroundColor Yellow
Write-Host "╠══════════════════════════════════════════════════════════════════════════╣" -ForegroundColor Yellow
Write-Host "║                                                                          ║" -ForegroundColor Yellow
Write-Host "║  The new VM has a FRESH OS. Data disks have been migrated, but the OS    ║" -ForegroundColor Yellow
Write-Host "║  must be reconfigured manually. Complete these steps:                    ║" -ForegroundColor Yellow
Write-Host "║                                                                          ║" -ForegroundColor Yellow
Write-Host "║  1. SSH into the new VM:                                                 ║" -ForegroundColor Yellow
Write-Host "║     ssh $adminUser@<PUBLIC_IP>                                           ║" -ForegroundColor Yellow
Write-Host "║                                                                          ║" -ForegroundColor Yellow
Write-Host "║  2. Mount data disks:                                                    ║" -ForegroundColor Yellow
Write-Host "║     - Run: lsblk -f && blkid                                            ║" -ForegroundColor Yellow
Write-Host "║     - Mount disks manually: mount /dev/sdX /mnt/data                     ║" -ForegroundColor Yellow
Write-Host "║     - Add data-disk entries to /etc/fstab using UUID or                  ║" -ForegroundColor Yellow
Write-Host "║       /dev/disk/azure/scsi1/lunX paths with 'nofail' option              ║" -ForegroundColor Yellow
Write-Host "║     - Do NOT copy old root/boot fstab entries                            ║" -ForegroundColor Yellow
Write-Host "║                                                                          ║" -ForegroundColor Yellow
Write-Host "║  3. Reinstall application packages:                                      ║" -ForegroundColor Yellow
Write-Host "║     - Refer to old VM package list (dpkg-query -W / rpm -qa)             ║" -ForegroundColor Yellow
Write-Host "║     - Restore /etc configs, cron jobs, systemd units as needed           ║" -ForegroundColor Yellow
Write-Host "║                                                                          ║" -ForegroundColor Yellow
Write-Host "║  4. Verify application functionality and connectivity                    ║" -ForegroundColor Yellow
Write-Host "║                                                                          ║" -ForegroundColor Yellow
Write-Host "╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
Write-Host ""

# ── Cleanup commands ──────────────────────────────────────────────────────────
Write-Host "────────────────────────────────────────────────────────────────────────────"
Write-Host "CLEANUP (run manually after verifying the new VM is working correctly):"
Write-Host "────────────────────────────────────────────────────────────────────────────"
Write-Host ""
Write-Host "# Delete original OS disk:"
Write-Host "Remove-AzDisk -ResourceGroupName `"$ResourceGroupName`" -DiskName `"$osDiskName`" -Force"
Write-Host ""
if ($dataDisks.Count -gt 0) {
    Write-Host "# Delete original data disks:"
    foreach ($dd in $dataDisks) {
        Write-Host "Remove-AzDisk -ResourceGroupName `"$ResourceGroupName`" -DiskName `"$($dd.Name)`" -Force"
    }
    Write-Host ""
}

# ── Timing summary ───────────────────────────────────────────────────────────
$scriptTimer.Stop()
Write-Host "════════════════════════════════════════════════════════════════════════════"
Write-Host "TIMING SUMMARY"
Write-Host "════════════════════════════════════════════════════════════════════════════"
foreach ($s in $stepTimings) {
    Write-Host ("  {0,-45} {1}" -f $s.Name, (Format-Elapsed $s.Elapsed))
}
Write-Host "  ─────────────────────────────────────────────────────────"
Write-Host ("  {0,-45} {1}" -f "Total", (Format-Elapsed $scriptTimer.Elapsed))
Write-Host ""
Write-Host "Migration complete. ✓" -ForegroundColor Green
