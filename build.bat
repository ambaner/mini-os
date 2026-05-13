@echo off
:: build.bat — Build mini-os (assembles MBR, creates VHD)
:: Usage: build.bat [clean] [/debug]

setlocal

:: Ensure we're running from the repo root
cd /d "%~dp0"

:: Check for PowerShell 7
where pwsh >nul 2>&1
if errorlevel 1 (
    echo ERROR: PowerShell 7 ^(pwsh^) is not installed or not on PATH.
    echo Install it from: https://aka.ms/powershell
    exit /b 1
)

if /i "%~1"=="clean" (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "tools\build.ps1" -Clean
) else if /i "%~1"=="/debug" (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "tools\build.ps1" -DebugBuild
) else (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "tools\build.ps1"
)
