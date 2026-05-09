<#
.SYNOPSIS
    Create or update a Hyper-V Generation 1 VM for testing mini-os.

.DESCRIPTION
    - Prompts for VM name and file location (with sensible defaults).
    - Creates a Gen 1 VM with 32 MB RAM if it doesn't exist.
    - Copies the latest build/mini-os.vhd into a HDD subfolder.
    - On subsequent runs, replaces the VHD with the latest build and
      ensures the VM points to it — no manual steps needed.

.NOTES
    Requires Hyper-V PowerShell module and admin privileges.
#>
#Requires -Version 7.0

$ErrorActionPreference = 'Stop'

# ---------- preflight -------------------------------------------------------
function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$id
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host ''
        Write-Host 'ERROR: This script must be run as Administrator (Hyper-V requires elevation).' -ForegroundColor Red
        Write-Host ''
        Write-Host 'Open an elevated PowerShell 7 prompt:' -ForegroundColor Yellow
        Write-Host '  1. Right-click the Start menu -> Terminal (Admin)'
        Write-Host '  2. Or run:  Start-Process pwsh -Verb RunAs'
        Write-Host ''
        exit 1
    }
}

function Assert-HyperV {
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        Write-Host 'ERROR: Hyper-V PowerShell module not found. Enable Hyper-V first.' -ForegroundColor Red
        exit 1
    }
}

Assert-Admin
Assert-HyperV

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Root      = Split-Path -Parent $ScriptDir
$SourceVhd = Join-Path $Root 'build\boot\mini-os.vhd'

if (-not (Test-Path $SourceVhd)) {
    Write-Host "ERROR: $SourceVhd not found. Run .\build.ps1 first." -ForegroundColor Red
    exit 1
}

# ---------- prompt for settings ---------------------------------------------
function Read-WithDefault([string]$Prompt, [string]$Default) {
    $input_val = Read-Host "$Prompt [default: $Default]"
    if ([string]::IsNullOrWhiteSpace($input_val)) { return $Default }
    return $input_val.Trim()
}

$DefaultVMPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'HyperV\mini-os'

$VMName = Read-WithDefault 'VM name' 'mini-os'
$VMPath = Read-WithDefault 'VM file location' $DefaultVMPath

# ---------- derived paths ---------------------------------------------------
$HddDir = Join-Path $VMPath 'HDD'
$TargetVhd = Join-Path $HddDir 'mini-os.vhd'

# ---------- helpers ---------------------------------------------------------
function Write-Step([string]$msg) { Write-Host "[setup-vm] $msg" -ForegroundColor Cyan }

function Copy-LatestVhd {
    if (-not (Test-Path $HddDir)) {
        New-Item -ItemType Directory -Path $HddDir -Force | Out-Null
    }
    Copy-Item -Path $SourceVhd -Destination $TargetVhd -Force
    Write-Step "Copied latest VHD to $TargetVhd"
}

# ---------- check for existing VM -------------------------------------------
$existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue

if ($existingVM) {
    Write-Step "Found existing VM '$VMName' — updating with latest VHD..."

    # Stop the VM if it's running
    if ($existingVM.State -ne 'Off') {
        Write-Step "Stopping VM..."
        Stop-VM -Name $VMName -TurnOff -Force
        # Wait for it to fully stop
        while ((Get-VM -Name $VMName).State -ne 'Off') {
            Start-Sleep -Milliseconds 500
        }
        Write-Step "VM stopped."
    }

    # Replace the VHD
    Copy-LatestVhd

    # Ensure the VHD is attached to IDE Controller 0, Location 0
    $drives = Get-VMHardDiskDrive -VMName $VMName
    if ($drives) {
        # Update the first drive to point to the new VHD
        Set-VMHardDiskDrive -VMName $VMName `
            -ControllerType IDE -ControllerNumber 0 -ControllerLocation 0 `
            -Path $TargetVhd
        Write-Step "Updated IDE 0:0 to point to latest VHD."
    } else {
        Add-VMHardDiskDrive -VMName $VMName `
            -ControllerType IDE -ControllerNumber 0 -ControllerLocation 0 `
            -Path $TargetVhd
        Write-Step "Attached VHD to IDE 0:0."
    }

} else {
    Write-Step "Creating new VM '$VMName'..."

    # Copy VHD first so the path exists when we create the VM
    Copy-LatestVhd

    # Create the VM — Gen 1, 32 MB static RAM, no network, no default VHD
    New-VM -Name $VMName `
           -Path $VMPath `
           -Generation 1 `
           -MemoryStartupBytes 32MB `
           -NoVHD | Out-Null

    # Attach our VHD
    Add-VMHardDiskDrive -VMName $VMName `
        -ControllerType IDE -ControllerNumber 0 -ControllerLocation 0 `
        -Path $TargetVhd

    # Remove the default network adapter — not needed
    Get-VMNetworkAdapter -VMName $VMName | Remove-VMNetworkAdapter

    # Disable checkpoints (not useful for a toy OS)
    Set-VM -Name $VMName -CheckpointType Disabled

    Write-Step "VM '$VMName' created at $VMPath"
}

# ---------- summary ---------------------------------------------------------
Write-Host ''
Write-Step '=== VM ready ==='
Write-Host "  Name : $VMName"
Write-Host "  Path : $VMPath"
Write-Host "  VHD  : $TargetVhd"
Write-Host "  RAM  : 32 MB"
Write-Host "  Gen  : 1"
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Yellow
Write-Host "  Start-VM -Name '$VMName'           # start from PowerShell"
Write-Host "  vmconnect localhost '$VMName'       # open console window"
Write-Host ''
Write-Host 'After rebuilding (.\build.ps1), just run this script again to update the VM.' -ForegroundColor Yellow
Write-Host ''
