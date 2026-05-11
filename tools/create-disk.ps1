<#
.SYNOPSIS
    Create a partitioned raw disk image from MBR and VBR binaries.

.DESCRIPTION
    Builds a raw disk image with:
      1. MBR at sector 0 (with partition table stamped in)
      2. One partition starting at a configurable LBA offset
      3. VBR written at the partition's first sector

    The partition table entry is written into the MBR binary at offset 0x1BE.

.PARAMETER MbrPath
    Path to the assembled MBR binary (512 bytes).

.PARAMETER VbrPath
    Path to the assembled VBR binary (512 bytes).

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
    [Parameter(Mandatory)][string]$OutputPath,
    [int]$SizeMB = 16,
    [int]$PartitionStartLBA = 2048,
    [int]$PartitionType = 0x7F
)

$ErrorActionPreference = 'Stop'

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
if ($vbrBytes.Length -ne 512) {
    throw "VBR must be exactly 512 bytes (got $($vbrBytes.Length))."
}
if ($vbrBytes[510] -ne 0x55 -or $vbrBytes[511] -ne 0xAA) {
    throw "VBR is missing boot signature (0x55AA)."
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

# Write VBR at partition start
$fs.Write($vbrBytes, 0, 512)

# Zero-fill the rest of the disk
$remainingBytes = $diskSize - (($PartitionStartLBA + 1) * 512)
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
Write-Step "  Sector $PartitionStartLBA  : VBR (active partition)"
