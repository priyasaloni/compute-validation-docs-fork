<#
.SYNOPSIS
GET ExecutionPlanRun (EPR) resource for Microsoft Validate RP.

.DESCRIPTION
Builds correct ARM URI:
  https://{ArmHost}/subscriptions/{subscriptionId}/resourceGroups/{rg}/providers/Microsoft.Validate/cloudValidations/{cv}/validationExecutionPlans/{vep}/executionPlanRuns/{epr}?api-version={apiVersion}

Uses Azure CLI auth context via: az rest

.EXAMPLE
.\Get-ExecutionPlanRun.ps1 `
  -SubscriptionId "188751fa-ca88-42d9-bdfe-f1406e0bde62" `
  -ResourceGroupName "vrp-dev-eastus2-rg" `
  -CloudValidationName "cv-dev" `
  -ValidationExecutionPlanName "vep-dev" `
  -ExecutionPlanRunName "epr-dev" `
  -ArmHost "eastus2euap.management.azure.com" `
  -ApiVersion "2026-02-01-preview" `
  -Pretty -ShowCurl
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string] $SubscriptionId,
  [Parameter(Mandatory=$true)] [string] $ResourceGroupName,
  [Parameter(Mandatory=$true)] [string] $CloudValidationName,
  [Parameter(Mandatory=$true)] [string] $ValidationExecutionPlanName,
  [Parameter(Mandatory=$true)] [string] $ExecutionPlanRunName,

  [Parameter(Mandatory=$false)] [string] $ArmHost = "management.azure.com",
  [Parameter(Mandatory=$false)] [string] $ApiVersion = "2026-02-01-preview",

  [switch] $Pretty,
  [switch] $Raw,
  [switch] $ShowCurl,
  [string] $OutFile
)

# Safety net (avoid terminal closing silently)
$ErrorActionPreference = "Stop"
trap {
  Write-Host "`nSCRIPT FAILED" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  if ($_.ScriptStackTrace) {
    Write-Host "`nStackTrace:" -ForegroundColor Yellow
    Write-Host $_.ScriptStackTrace -ForegroundColor Yellow
  }
  Read-Host "`nPress ENTER to exit" | Out-Null
  exit 1
}

# Azure CLI login + subscription setup
Write-Host "Checking Azure CLI login..." -ForegroundColor Cyan
$azAccount = az account show 2>$null | Out-String
if (-not $azAccount) {
  Write-Host "Not logged in. Running az login..." -ForegroundColor Yellow
  az login | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "az login failed." }
}

Write-Host "Setting subscription: $SubscriptionId" -ForegroundColor Cyan
az account set --subscription $SubscriptionId | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription: $SubscriptionId" }

# Normalize host + build URI (NO code param)
$ArmHost = $ArmHost.Trim() -replace '^https?://',''
$baseUri = "https://$ArmHost"

$resourcePath =
  "/subscriptions/$SubscriptionId" +
  "/resourceGroups/$ResourceGroupName" +
  "/providers/Microsoft.Validate" +
  "/cloudValidations/$CloudValidationName" +
  "/validationExecutionPlans/$ValidationExecutionPlanName" +
  "/executionPlanRuns/$ExecutionPlanRunName"

$query = "?api-version=$ApiVersion"
$uri = "$baseUri$resourcePath$query"

# Guardrails
if ($uri -notmatch "subscriptions" -or $uri -notmatch "api-version=") {
  throw "Bad URI constructed: $uri"
}
if ($uri -match "\s") {
  throw "Bad URI constructed (contains whitespace): $uri"
}

Write-Host "Calling URI: $uri" -ForegroundColor Cyan

# Optional curl output (token via az)
if ($ShowCurl) {
  $tokOut = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>&1 | Out-String
  if ($LASTEXITCODE -eq 0 -and $tokOut -and $tokOut -notmatch "ERROR") {
    $token = $tokOut.Trim()
    $curl = "curl -sS -X GET `"$uri`" -H `"Authorization: Bearer $token`" -H `"Accept: application/json`""
    Write-Host "`nCURL:" -ForegroundColor Yellow
    Write-Host $curl -ForegroundColor DarkCyan
  } else {
    Write-Host "`n(ShowCurl) Failed to fetch token via az account get-access-token" -ForegroundColor Yellow
    Write-Host $tokOut -ForegroundColor Yellow
  }
}

# Call ARM via Azure CLI context
$out = az rest --method get --uri $uri --only-show-errors 2>&1 | Out-String
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
  Write-Host "`naz rest FAILED (exitCode $exitCode)" -ForegroundColor Red
  Write-Host $out -ForegroundColor Red
  Read-Host "`nPress ENTER to exit" | Out-Null
  exit $exitCode
}

# Save / print
if ($OutFile -and $OutFile.Trim().Length -gt 0) {
  $out | Set-Content -Path $OutFile -Encoding UTF8
  Write-Host "Saved response to $OutFile" -ForegroundColor Green
}

if ($Raw) {
  Write-Output $out
} elseif ($Pretty) {
  ($out | ConvertFrom-Json) | ConvertTo-Json -Depth 100
} else {
  Write-Output $out
}

Read-Host "`nDone. Press ENTER to close" | Out-Null
``