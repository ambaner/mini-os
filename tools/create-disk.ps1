<#
.SYNOPSIS
    Create a partitioned raw disk image from MBR, VBR, loader, kernel, and shell binaries.

.DESCRIPTION
    Builds a raw disk image with:
      1. MBR at sector 0 (with partition table stamped in)
      2. One partition starting at a configurable LBA offset
      3. VBR written at the partition's first sector
      4. LOADER.BIN written at partition offset 4 sectors
      5. KERNEL.BIN written at partition offset 20 sectors
      6. SHELL.BIN written at partition offset 36 sectors
      7. Partition start LBA stamped into VBR header at offset 9

.PARAMETER MbrPath
    Path to the assembled MBR binary (512 bytes).

.PARAMETER VbrPath
    Path to the assembled VBR binary (multiple of 512 bytes).

.PARAMETER LoaderPath
    Path to the assembled LOADER.BIN binary (multiple of 512 bytes).

.PARAMETER KernelPath
    Path to the assembled KERNEL.BIN binary (multiple of 512 bytes).

.PARAMETER ShellPath
    Path to the assembled SHELL.BIN binary (multiple of 512 bytes).

.PARAMETER OutputPath
    Path for the output raw disk image.

.PARAMETER SizeMB
    Disk size in megabytes (default: 16).

.PARAMETER PartitionStartLBA
    LBA sector where the partition begins (default: 2048 = 1 MB offset).

.PARAMETER PartitionType
    Partition type byte (default: 0x7F — experimental/private use).
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MbrPath,
    [Parameter(Mandatory)][string]$VbrPath,
    [Parameter(Mandatory)][string]$LoaderPath,
    [Parameter(Mandatory)][string]$KernelPath,
    [Parameter(Mandatory)][string]$ShellPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [int]$SizeMB = 16,
    [int]$PartitionStartLBA = 2048,
    [int]$PartitionType = 0x7F
)

$ErrorActionPreference = 'Stop'

# --- Partition-relative offsets (in sectors) ---
$LoaderPartOff = 4                   # LOADER.BIN at partition offset 4
$KernelPartOff = 20                  # KERNEL.BIN at partition offset 20
$ShellPartOff  = 36                  # SHELL.BIN at partition offset 36

function Write-Step([string]$msg) { Write-Host "[create-disk] $msg" -ForegroundColor Cyan }

# ---------- validate inputs -------------------------------------------------
$mbrBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $MbrPath))
if ($mbrBytes.Length -ne 512) {
    throw "MBR must be exactly 512 bytes (got $($mbrBytes.Length))."
}
if ($mbrBytes[510] -ne 0x55 -or $mbrBytes[511] -ne 0xAA) {
    throw "MBR is missing boot signature (0x55AA)."
}

$vbrBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $VbrPath))
if (($vbrBytes.Length % 512) -ne 0) {
    throw "VBR must be a multiple of 512 bytes (got $($vbrBytes.Length))."
}
if ($vbrBytes.Length -lt 512) {
    throw "VBR must be at least 512 bytes (got $($vbrBytes.Length))."
}
if ($vbrBytes[510] -ne 0x55 -or $vbrBytes[511] -ne 0xAA) {
    throw "VBR is missing boot signature (0x55AA) at offset 510."
}
$vbrSectors = $vbrBytes.Length / 512
Write-Step "VBR: $($vbrBytes.Length) bytes ($vbrSectors sectors)"

$loaderBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $LoaderPath))
if (($loaderBytes.Length % 512) -ne 0) {
    throw "LOADER.BIN must be a multiple of 512 bytes (got $($loaderBytes.Length))."
}
$magic = [System.Text.Encoding]::ASCII.GetString($loaderBytes, 0, 4)
if ($magic -ne 'MNLD') {
    throw "LOADER.BIN magic is '$magic' (expected 'MNLD')."
}
$loaderSectors = $loaderBytes.Length / 512
Write-Step "LOADER: $($loaderBytes.Length) bytes ($loaderSectors sectors)"

$shellBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $ShellPath))
if (($shellBytes.Length % 512) -ne 0) {
    throw "SHELL.BIN must be a multiple of 512 bytes (got $($shellBytes.Length))."
}
$shellMagic = [System.Text.Encoding]::ASCII.GetString($shellBytes, 0, 4)
if ($shellMagic -ne 'MNEX') {
    throw "SHELL.BIN magic is '$shellMagic' (expected 'MNEX')."
}
$shellSectors = $shellBytes.Length / 512
Write-Step "SHELL: $($shellBytes.Length) bytes ($shellSectors sectors)"

# Validate KERNEL.BIN
$kernelBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $KernelPath))
if (($kernelBytes.Length % 512) -ne 0) {
    throw "KERNEL.BIN must be a multiple of 512 bytes (got $($kernelBytes.Length))."
}
$kernelMagic = [System.Text.Encoding]::ASCII.GetString($kernelBytes, 0, 4)
if ($kernelMagic -ne 'MNKN') {
    throw "KERNEL.BIN magic is '$kernelMagic' (expected 'MNKN')."
}
$kernelSectors = $kernelBytes.Length / 512
Write-Step "KERNEL: $($kernelBytes.Length) bytes ($kernelSectors sectors)"

# Verify no overlaps
if (($LoaderPartOff + $loaderSectors) -gt $KernelPartOff) {
    throw "LOADER.BIN ($loaderSectors sectors at offset $LoaderPartOff) overlaps KERNEL.BIN (at offset $KernelPartOff)."
}
if (($KernelPartOff + $kernelSectors) -gt $ShellPartOff) {
    throw "KERNEL.BIN ($kernelSectors sectors at offset $KernelPartOff) overlaps SHELL.BIN (at offset $ShellPartOff)."
}

$diskSize = [long]$SizeMB * 1024 * 1024
$totalSectors = [int]($diskSize / 512)

if ($PartitionStartLBA -ge $totalSectors) {
    throw "Partition start LBA ($PartitionStartLBA) exceeds disk size ($totalSectors sectors)."
}

# Partition spans from PartitionStartLBA to end of disk
$partSizeSectors = $totalSectors - $PartitionStartLBA

Write-Step "Disk: $SizeMB MB ($totalSectors sectors)"
Write-Step "Partition 1: LBA $PartitionStartLBA, size $partSizeSectors sectors ($([math]::Round($partSizeSectors * 512 / 1MB, 2)) MB)"
Write-Step "Partition type: 0x$($PartitionType.ToString('X2'))"

# ---------- stamp partition table into MBR ----------------------------------
# Partition entry format (16 bytes):
#   [0]    Status (0x80 = active)
#   [1-3]  CHS of first sector (we use 0xFE,0xFF,0xFF for LBA mode)
#   [4]    Partition type
#   [5-7]  CHS of last sector  (we use 0xFE,0xFF,0xFF for LBA mode)
#   [8-11] LBA of first sector (little-endian 32-bit)
#   [12-15] Size in sectors     (little-endian 32-bit)

$partEntry = [byte[]]::new(16)
$partEntry[0]  = 0x80               # Active/bootable
$partEntry[1]  = 0xFE               # CHS start — use LBA
$partEntry[2]  = 0xFF
$partEntry[3]  = 0xFF
$partEntry[4]  = [byte]$PartitionType
$partEntry[5]  = 0xFE               # CHS end — use LBA
$partEntry[6]  = 0xFF
$partEntry[7]  = 0xFF

# LBA start (little-endian)
$lbaBytes = [BitConverter]::GetBytes([uint32]$PartitionStartLBA)
[Array]::Copy($lbaBytes, 0, $partEntry, 8, 4)

# Size in sectors (little-endian)
$sizeBytes = [BitConverter]::GetBytes([uint32]$partSizeSectors)
[Array]::Copy($sizeBytes, 0, $partEntry, 12, 4)

# Write partition entry 1 at MBR offset 0x1BE
[Array]::Copy($partEntry, 0, $mbrBytes, 0x1BE, 16)

# Entries 2-4 remain zeroed (already are from NASM)

Write-Step "Partition table stamped into MBR."

# ---------- stamp partition start LBA into VBR header -----------------------
# VBR header offset 9: dd partition_start_lba (4 bytes, little-endian)
$partLbaBytes = [BitConverter]::GetBytes([uint32]$PartitionStartLBA)
[Array]::Copy($partLbaBytes, 0, $vbrBytes, 9, 4)
Write-Step "Partition LBA ($PartitionStartLBA) stamped into VBR header at offset 9."

# ---------- build the raw disk image ----------------------------------------
Write-Step "Writing disk image..."

$fs = [System.IO.FileStream]::new($OutputPath, 'Create', 'Write')

# Write MBR at sector 0
$fs.Write($mbrBytes, 0, 512)

# Zero-fill from sector 1 to partition start
$gapBytes = ($PartitionStartLBA - 1) * 512
if ($gapBytes -gt 0) {
    $zeroBuf = [byte[]]::new([math]::Min($gapBytes, 65536))
    $remaining = $gapBytes
    while ($remaining -gt 0) {
        $chunk = [math]::Min($remaining, $zeroBuf.Length)
        $fs.Write($zeroBuf, 0, $chunk)
        $remaining -= $chunk
    }
}

# Write VBR (all sectors) at partition start
$fs.Write($vbrBytes, 0, $vbrBytes.Length)

# Zero-fill gap between VBR and LOADER.BIN
$vbrEndSector = $vbrSectors
$gapToLoader = ($LoaderPartOff - $vbrEndSector) * 512
if ($gapToLoader -gt 0) {
    $zeroBuf = [byte[]]::new($gapToLoader)
    $fs.Write($zeroBuf, 0, $gapToLoader)
}

# Write LOADER.BIN at partition offset LoaderPartOff
$fs.Write($loaderBytes, 0, $loaderBytes.Length)

# Zero-fill gap between LOADER.BIN and KERNEL.BIN
$loaderEndSector = $LoaderPartOff + $loaderSectors
$gapToKernel = ($KernelPartOff - $loaderEndSector) * 512
if ($gapToKernel -gt 0) {
    $zeroBuf = [byte[]]::new($gapToKernel)
    $fs.Write($zeroBuf, 0, $gapToKernel)
}

# Write KERNEL.BIN at partition offset KernelPartOff
$fs.Write($kernelBytes, 0, $kernelBytes.Length)

# Zero-fill gap between KERNEL.BIN and SHELL.BIN
$kernelEndSector = $KernelPartOff + $kernelSectors
$gapToShell = ($ShellPartOff - $kernelEndSector) * 512
if ($gapToShell -gt 0) {
    $zeroBuf = [byte[]]::new($gapToShell)
    $fs.Write($zeroBuf, 0, $gapToShell)
}

# Write SHELL.BIN at partition offset ShellPartOff
$fs.Write($shellBytes, 0, $shellBytes.Length)

# Zero-fill the rest of the disk
$shellEndAbsLBA = $PartitionStartLBA + $ShellPartOff + $shellSectors
$remainingBytes = $diskSize - ($shellEndAbsLBA * 512)
if ($remainingBytes -gt 0) {
    $zeroBuf = [byte[]]::new([math]::Min($remainingBytes, 65536))
    $remaining = $remainingBytes
    while ($remaining -gt 0) {
        $chunk = [math]::Min($remaining, $zeroBuf.Length)
        $fs.Write($zeroBuf, 0, $chunk)
        $remaining -= $chunk
    }
}

$fs.Close()

$fileSize = (Get-Item $OutputPath).Length
Write-Step "Raw image: $OutputPath ($fileSize bytes)"
Write-Step "  Sector 0       : MBR (with partition table)"
Write-Step "  Sector $PartitionStartLBA  : VBR ($vbrSectors sectors, $($vbrBytes.Length) bytes)"
Write-Step "  Sector $($PartitionStartLBA + $LoaderPartOff)  : LOADER.BIN ($loaderSectors sectors, $($loaderBytes.Length) bytes)"
Write-Step "  Sector $($PartitionStartLBA + $KernelPartOff)  : KERNEL.BIN ($kernelSectors sectors, $($kernelBytes.Length) bytes)"
Write-Step "  Sector $($PartitionStartLBA + $ShellPartOff)  : SHELL.BIN ($shellSectors sectors, $($shellBytes.Length) bytes)"
