<#
.SYNOPSIS
    Build script for mini-os.  Assembles the MBR and creates a bootable VHD.

.DESCRIPTION
    1. Downloads NASM if not found on PATH or in tools/nasm/.
    2. Assembles src/boot/mbr.asm -> build/mbr.bin.
    3. Creates build/boot/mini-os.vhd via tools/create-vhd.ps1.

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
$SrcBoot    = Join-Path $Root 'src\boot\mbr.asm'
$MbrBin     = Join-Path $BuildDir 'mbr.bin'
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
& $nasm -f bin -o $MbrBin $SrcBoot
if ($LASTEXITCODE -ne 0) { throw 'NASM assembly failed.' }

$binSize = (Get-Item $MbrBin).Length
Write-Step "  mbr.bin: $binSize bytes"
if ($binSize -ne 512) { Write-Warning "MBR is $binSize bytes (expected 512)." }

# ---------- create VHD ------------------------------------------------------
Write-Step 'Creating VHD...'
$VhdScript = Join-Path $ToolsDir 'create-vhd.ps1'
& $VhdScript -InputPath $MbrBin -OutputPath $VhdOut -SizeMB $DiskSizeMB

# ---------- done ------------------------------------------------------------
Write-Host ''
Write-Step '=== Build complete ==='
Write-Step "VHD: $VhdOut"
Write-Host ''
Write-Host 'To test in Hyper-V:' -ForegroundColor Yellow
Write-Host "  1. Open Hyper-V Manager"
Write-Host "  2. Create a new Generation 1 VM"
Write-Host "  3. Attach $VhdOut as the IDE hard drive"
Write-Host "  4. Boot the VM — you should see 'mini-os' printed on screen"
Write-Host ''
