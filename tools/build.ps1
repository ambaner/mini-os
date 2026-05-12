<#
.SYNOPSIS
    Build script for mini-os.  Assembles MBR + VBR + LOADER + FS + KERNEL + SHELL, creates a partitioned VHD.

.DESCRIPTION
    1. Downloads NASM if not found on PATH or in tools/nasm/.
    2. Assembles src/boot/mbr.asm      -> build/boot/mbr.bin
    3. Assembles src/boot/vbr.asm      -> build/boot/vbr.bin
    4. Assembles src/loader/loader.asm  -> build/boot/loader.bin
    5. Assembles src/fs/fs.asm          -> build/boot/fs.bin
    6. Assembles src/kernel/kernel.asm  -> build/boot/kernel.bin
    7. Assembles src/shell/shell.asm    -> build/boot/shell.bin
    8. Creates a partitioned raw disk image via tools/create-disk.ps1
    9. Wraps the raw image as a VHD via tools/create-vhd.ps1

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
$KernelAsm  = Join-Path $Root 'src\kernel\kernel.asm'
$FsAsm      = Join-Path $Root 'src\fs\fs.asm'
$ShellAsm   = Join-Path $Root 'src\shell\shell.asm'
$MbrBin     = Join-Path $BuildDir 'mbr.bin'
$VbrBin     = Join-Path $BuildDir 'vbr.bin'
$LoaderBin  = Join-Path $BuildDir 'loader.bin'
$KernelBin  = Join-Path $BuildDir 'kernel.bin'
$FsBin      = Join-Path $BuildDir 'fs.bin'
$ShellBin   = Join-Path $BuildDir 'shell.bin'
$IncludeDir = Join-Path $Root 'src\include'
$RawImg     = Join-Path $BuildDir 'mini-os.img'
$VhdOut     = Join-Path $BuildDir 'mini-os.vhd'

# ---------- helpers ---------------------------------------------------------
function Write-Step([string]$msg) { Write-Host "[mini-os] $msg" -ForegroundColor Cyan }

function Build-Binary {
    param(
        [string]$Name,
        [string]$AsmPath,
        [string]$BinPath,
        [int]$ExpectedSize = 0    # 0 = no specific size check
    )
    Write-Step "Assembling ${Name}..."
    & $nasm -f bin -I "$IncludeDir/" -o $BinPath $AsmPath
    if ($LASTEXITCODE -ne 0) { throw "NASM assembly of $Name failed." }

    $size = (Get-Item $BinPath).Length
    $sectors = [math]::Ceiling($size / 512)
    Write-Step "  $([System.IO.Path]::GetFileName($BinPath)): $size bytes ($sectors sectors)"

    if ($ExpectedSize -gt 0 -and $size -ne $ExpectedSize) {
        Write-Warning "$Name is $size bytes (expected $ExpectedSize)."
    }
    if (($size % 512) -ne 0) {
        Write-Warning "$Name size is not a multiple of 512 bytes."
    }
}

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

# ---------- assemble all binaries -------------------------------------------
Build-Binary -Name 'MBR'    -AsmPath $MbrAsm    -BinPath $MbrBin    -ExpectedSize 512
Build-Binary -Name 'VBR'    -AsmPath $VbrAsm    -BinPath $VbrBin
Build-Binary -Name 'LOADER' -AsmPath $LoaderAsm -BinPath $LoaderBin
Build-Binary -Name 'FS'     -AsmPath $FsAsm     -BinPath $FsBin
Build-Binary -Name 'KERNEL' -AsmPath $KernelAsm -BinPath $KernelBin
Build-Binary -Name 'SHELL'  -AsmPath $ShellAsm  -BinPath $ShellBin

# ---------- create partitioned disk image -----------------------------------
Write-Step 'Creating partitioned disk image...'
$DiskScript = Join-Path $ToolsDir 'create-disk.ps1'
& $DiskScript -MbrPath $MbrBin -VbrPath $VbrBin -LoaderPath $LoaderBin -FsPath $FsBin -KernelPath $KernelBin -ShellPath $ShellBin -OutputPath $RawImg -SizeMB $DiskSizeMB

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
