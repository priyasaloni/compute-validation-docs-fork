<#
.SYNOPSIS
  Installs Azure CLI if not already present.

.DESCRIPTION
  - Checks if `az` is available in PATH
  - If missing:
      1) Tries WinGet (preferred, silent)0
      2) Falls back to MSI installer via PowerShell
  - Verifies installation at the end

.NOTES
  - Requires Windows
  - MSI install requires admin privileges
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-AzCli {
    return (Get-Command az -ErrorAction SilentlyContinue) -ne $null
}

function Install-With-WinGet {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Installing Azure CLI using WinGet..." -ForegroundColor Cyan
        winget install --exact --id Microsoft.AzureCLI --silent --accept-package-agreements --accept-source-agreements
        return
    }
    throw "WinGet not available"
}

function Install-With-MSI {
    Write-Host "Installing Azure CLI using MSI installer..." -ForegroundColor Cyan
    $msi = "$env:TEMP\AzureCLI.msi"
    Invoke-WebRequest -Uri "https://aka.ms/installazurecliwindows" -OutFile $msi
    Start-Process msiexec.exe -Wait -ArgumentList "/I `"$msi`" /quiet"
    Remove-Item $msi -Force
}

# -------------------------
# Main
# -------------------------

if (Test-AzCli) {
    Write-Host "Azure CLI already installed." -ForegroundColor Green
    az version
    return
}

Write-Host "Azure CLI not found. Installing..." -ForegroundColor Yellow

try {
    Install-With-WinGet
}
catch {
    Write-Host "WinGet install failed or unavailable. Falling back to MSI..." -ForegroundColor Yellow
    Install-With-MSI
}

# Reload PATH in current session (new shell still recommended) or open a new powershell window or restart shell.
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH","User")

if (-not (Test-AzCli)) {
    throw "Azure CLI installation failed. Restart PowerShell and try again."
}

Write-Host "Azure CLI installed successfully." -ForegroundColor Green
az version