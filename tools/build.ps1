<#
.SYNOPSIS
    Build script for mini-os.  Assembles MBR + VBR, creates a partitioned VHD.

.DESCRIPTION
    1. Downloads NASM if not found on PATH or in tools/nasm/.
    2. Assembles src/boot/mbr.asm -> build/boot/mbr.bin
    3. Assembles src/boot/vbr.asm -> build/boot/vbr.bin
    4. Creates a partitioned raw disk image via tools/create-disk.ps1
    5. Wraps the raw image as a VHD via tools/create-vhd.ps1

.PARAMETER Clean
    Remove the build/ directory before building.

.PARAMETER DiskSizeMB
    VHD disk size in megabytes (default: 16).
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$Clean,
    [int]$DiskSizeMB = 16
)

$ErrorActionPreference = 'Stop'
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Root       = Split-Path -Parent $ScriptDir

# ---------- paths -----------------------------------------------------------
$BuildDir   = Join-Path $Root 'build\boot'
$ToolsDir   = $ScriptDir
$NasmDir    = Join-Path $ToolsDir 'nasm'
$SrcBoot    = Join-Path $Root 'src\boot'
$MbrAsm     = Join-Path $SrcBoot 'mbr.asm'
$VbrAsm     = Join-Path $SrcBoot 'vbr.asm'
$LoaderAsm  = Join-Path $Root 'src\loader\loader.asm'
$ShellAsm   = Join-Path $Root 'src\shell\shell.asm'
$MbrBin     = Join-Path $BuildDir 'mbr.bin'
$VbrBin     = Join-Path $BuildDir 'vbr.bin'
$LoaderBin  = Join-Path $BuildDir 'loader.bin'
$ShellBin   = Join-Path $BuildDir 'shell.bin'
$RawImg     = Join-Path $BuildDir 'mini-os.img'
$VhdOut     = Join-Path $BuildDir 'mini-os.vhd'

# ---------- helpers ---------------------------------------------------------
function Write-Step([string]$msg) { Write-Host "[mini-os] $msg" -ForegroundColor Cyan }

function Get-NasmPath {
    # 1. On PATH?
    $found = Get-Command nasm -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }

    # 2. In tools/nasm/?
    $local = Join-Path $NasmDir 'nasm.exe'
    if (Test-Path $local) { return $local }

    return $null
}

function Install-Nasm {
    Write-Step 'NASM not found — downloading...'
    $version = '2.16.03'
    $zip     = "nasm-$version-win64.zip"
    $url     = "https://www.nasm.us/pub/nasm/releasebuilds/$version/win64/$zip"
    $tmp     = Join-Path $env:TEMP $zip

    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    Expand-Archive -Path $tmp -DestinationPath $ToolsDir -Force
    Rename-Item (Join-Path $ToolsDir "nasm-$version") $NasmDir -Force
    Remove-Item $tmp -ErrorAction SilentlyContinue

    $exe = Join-Path $NasmDir 'nasm.exe'
    if (-not (Test-Path $exe)) {
        throw "NASM download/extract failed — $exe not found."
    }
    Write-Step "NASM installed to $NasmDir"
    return $exe
}

# ---------- clean -----------------------------------------------------------
if ($Clean -and (Test-Path $BuildDir)) {
    Write-Step 'Cleaning build directory...'
    Remove-Item $BuildDir -Recurse -Force
}

# ---------- ensure build dir ------------------------------------------------
if (-not (Test-Path $BuildDir)) { New-Item -ItemType Directory -Path $BuildDir | Out-Null }

# ---------- NASM ------------------------------------------------------------
$nasm = Get-NasmPath
if (-not $nasm) { $nasm = Install-Nasm }
Write-Step "Using NASM: $nasm"

# ---------- assemble MBR ----------------------------------------------------
Write-Step 'Assembling MBR...'
& $nasm -f bin -o $MbrBin $MbrAsm
if ($LASTEXITCODE -ne 0) { throw 'NASM assembly of MBR failed.' }

$binSize = (Get-Item $MbrBin).Length
Write-Step "  mbr.bin: $binSize bytes"
if ($binSize -ne 512) { Write-Warning "MBR is $binSize bytes (expected 512)." }

# ---------- assemble VBR ----------------------------------------------------
Write-Step 'Assembling VBR...'
& $nasm -f bin -o $VbrBin $VbrAsm
if ($LASTEXITCODE -ne 0) { throw 'NASM assembly of VBR failed.' }

$vbrSize = (Get-Item $VbrBin).Length
Write-Step "  vbr.bin: $vbrSize bytes ($([math]::Ceiling($vbrSize / 512)) sectors)"
if (($vbrSize % 512) -ne 0) { Write-Warning "VBR size is not a multiple of 512 bytes." }

# ---------- assemble LOADER ------------------------------------------------
Write-Step 'Assembling LOADER...'
& $nasm -f bin -o $LoaderBin $LoaderAsm
if ($LASTEXITCODE -ne 0) { throw 'NASM assembly of LOADER failed.' }

$loaderSize = (Get-Item $LoaderBin).Length
Write-Step "  loader.bin: $loaderSize bytes ($([math]::Ceiling($loaderSize / 512)) sectors)"
if (($loaderSize % 512) -ne 0) { Write-Warning "LOADER size is not a multiple of 512 bytes." }

# ---------- assemble SHELL -------------------------------------------------
Write-Step 'Assembling SHELL...'
& $nasm -f bin -o $ShellBin $ShellAsm
if ($LASTEXITCODE -ne 0) { throw 'NASM assembly of SHELL failed.' }

$shellSize = (Get-Item $ShellBin).Length
Write-Step "  shell.bin: $shellSize bytes ($([math]::Ceiling($shellSize / 512)) sectors)"
if (($shellSize % 512) -ne 0) { Write-Warning "SHELL size is not a multiple of 512 bytes." }

# ---------- create partitioned disk image -----------------------------------
Write-Step 'Creating partitioned disk image...'
$DiskScript = Join-Path $ToolsDir 'create-disk.ps1'
& $DiskScript -MbrPath $MbrBin -VbrPath $VbrBin -LoaderPath $LoaderBin -ShellPath $ShellBin -OutputPath $RawImg -SizeMB $DiskSizeMB

# ---------- create VHD ------------------------------------------------------
Write-Step 'Creating VHD...'
$VhdScript = Join-Path $ToolsDir 'create-vhd.ps1'
& $VhdScript -InputPath $RawImg -OutputPath $VhdOut -SizeMB $DiskSizeMB

# ---------- done ------------------------------------------------------------
Write-Host ''
Write-Step '=== Build complete ==='
Write-Step "VHD: $VhdOut"
Write-Host ''
Write-Host 'To test in Hyper-V:' -ForegroundColor Yellow
Write-Host "  build.bat           — build the OS"
Write-Host "  setup-vm.bat        — create/update the VM"
Write-Host "  Start-VM 'mini-os'  — boot it"
Write-Host ''
