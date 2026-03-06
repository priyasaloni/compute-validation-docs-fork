<#
.SYNOPSIS
  Setup AITL roles + assignments (no Graph) - PowerShell port of CustomerScriptAITL.py

.DESCRIPTION
  Creates two custom roles with a unique suffix:
    - AITL Delegator_<guid>
    - AITL Jobs Access_<guid>
  Assigns:
    - Delegator role -> AITL SPN ObjectId
    - Jobs Access role -> Validate RP SPN ObjectId
  Uses Azure CLI (az) + az rest (ARM) to avoid Graph.

.PARAMETER SubscriptionId
  Subscription ID (GUID)

.PARAMETER ValidateSpnObjectId
  ObjectId of the Validate RP service principal

.PARAMETER LinuxAdvancedTestSpnObjectId
  ObjectId of the AzureImageTestingForLinux service principal

.EXAMPLE
  .\CustomerScriptAITL.ps1 -SubscriptionId <sub> -ValidateSpnObjectId <obj> -LinuxAdvancedTestSpnObjectId <obj>
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $true)]
  [string]$ValidateSpnObjectId,

  [Parameter(Mandatory = $true)]
  [string]$LinuxAdvancedTestSpnObjectId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
  param(
    [Parameter(Mandatory=$true)][string]$Level,
    [Parameter(Mandatory=$true)][string]$Message
  )
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "$ts[$Level] setup_aitl_no_graph $Message"
}

function Assert-Exe {
  param([Parameter(Mandatory=$true)][string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required executable not found: $Name"
  }
}


function Invoke-Az {
  param(
    [Parameter(Mandatory=$true)][string[]]$Args,
    [switch]$NoThrow
  )

  Write-Log "DEBUG" ("Running: az " + ($Args -join " "))

  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $raw  = & az @Args 2>&1
    $exit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prevEap
  }

  $out = ($raw | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { $_ }
  } | Out-String).Trim()

  if ($exit -eq 0 -and $out -match '(^|\r?\n)\s*(az\.cmd\s*:)?\s*WARNING:') {
    Write-Log "WARN" ("az warning (non-fatal): " + $out)
  }

  if ($exit -ne 0) {
    Write-Log "ERROR" ("Command failed: az " + ($Args -join " "))
    Write-Log "ERROR" ("Output: " + $out)
    if (-not $NoThrow) { throw "Azure CLI failed (exit=$exit)" }
  }

  return $out
}


function Invoke-AzRest {
  param(
    [Parameter(Mandatory=$true)][ValidateSet('GET','PUT','POST','DELETE','PATCH')][string]$Method,
    [Parameter(Mandatory=$true)][string]$Uri,
    [Parameter(Mandatory=$false)][string]$BodyJson
  )

  $args = @('rest', '--method', $Method, '--uri', $Uri, '--headers', 'Content-Type=application/json')

  if ($BodyJson -and $BodyJson.Trim().Length -gt 0) {
    $args += @('--body', $BodyJson)
  }

  return Invoke-Az -Args $args
}


function New-RoleDefinitionObject {
  param(
    [Parameter(Mandatory=$true)]
    [string]$RoleName,
    [Parameter(Mandatory=$true)]
    [string]$Description,
    [Parameter(Mandatory=$true)]
    [string[]]$Actions,

    [Parameter(Mandatory=$true)]
    [AllowEmptyCollection()]
    [string[]]$DataActions,

    [Parameter(Mandatory=$true)]
    [string]$AssignableScope
  )
  return @{
    Name             = $RoleName
    IsCustom         = $true
    Description      = $Description
    Actions          = $Actions
    NotActions       = @()
    DataActions      = $DataActions
    NotDataActions   = @()
    AssignableScopes = @($AssignableScope)
  }
}

function Ensure-Role {
  param(
    [Parameter(Mandatory=$true)][hashtable]$RoleDef,
    [Parameter(Mandatory=$true)][string]$RoleName,
    [Parameter(Mandatory=$true)][string]$Scope,
    [int]$Retries = 5,
    [int]$DelaySeconds = 15,
    [int]$ReadyTimeoutSeconds = 600
  )
  $roleDefinitionId = $null

  for ($attempt=1; $attempt -le $Retries; $attempt++) {
    $tmpPath = $null
    try {
      # 1) Check if role already exists
      $existingJson = Invoke-Az -Args @("role","definition","list","--custom-role-only","true","-o","json")
      $roles = @()
      if ($existingJson) { $roles = $existingJson | ConvertFrom-Json }
      $match = $roles | Where-Object { $_.roleName -eq $RoleName } | Select-Object -First 1

      if ($match) {
        Write-Log "INFO" "Role $RoleName already exists."
        $roleDefinitionId = $match.id
        break
      }

      # 2) Create role if not found
      Write-Log "INFO" "Role $RoleName does not exist. Creating..."
      $tmpPath = Join-Path $env:TEMP ("roledef_{0}.json" -f ([guid]::NewGuid().ToString()))
      ($RoleDef | ConvertTo-Json -Depth 50) | Set-Content -Path $tmpPath -Encoding UTF8
      Invoke-Az -Args @("role","definition","create","--role-definition",$tmpPath) | Out-Null

      # 3) Poll for visibility (same spirit as python: ~20 tries, 30s each)
      for ($i=0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 30
        $existingJson = Invoke-Az -Args @("role","definition","list","--custom-role-only","true","-o","json") -NoThrow
        if ($existingJson) {
          $roles = $existingJson | ConvertFrom-Json
          $match = $roles | Where-Object { $_.roleName -eq $RoleName } | Select-Object -First 1
          if ($match) {
            Write-Log "INFO" "Role $RoleName successfully created and visible."
            $roleDefinitionId = $match.id
            break
          }
        }
        Write-Log "INFO" "Waiting for role $RoleName to propagate..."
      }

      if (-not $roleDefinitionId) {
        throw "Role $RoleName not visible after create/update"
      }

      break
    }
    catch {
      Write-Log "WARN" ("Attempt {0}/{1}: Failed to ensure role {2} (reason: {3})" -f $attempt,$Retries,$RoleName,$_.Exception.Message)
      if ($attempt -lt $Retries) {
        Write-Log "INFO" "Retrying in $DelaySeconds seconds..."
        Start-Sleep -Seconds $DelaySeconds
      } else {
        throw
      }
    }
    finally {
      if ($tmpPath -and (Test-Path $tmpPath)) { Remove-Item -Force $tmpPath }
    }
  }

  # Extra check: assignment-ready (python does az role assignment list loop) [1](https://microsoft.sharepoint.com/teams/AzureIDC/AzureIDC_CRP/Shared%20Documents/AzCertify/SelfServiceValidation/CustomerScriptAITL.py)
  Write-Log "INFO" "Verifying role $RoleName is assignment-ready..."
  $start = Get-Date
  while (((Get-Date) - $start).TotalSeconds -lt $ReadyTimeoutSeconds) {
    try {
      Invoke-Az -Args @("role","assignment","list","--role",$RoleName,"--scope",$Scope,"-o","json") | Out-Null
      Write-Log "INFO" "Role $RoleName is assignment-ready."
      return $roleDefinitionId
    } catch {
      Write-Log "INFO" "Role $RoleName not yet assignment-ready, retrying..."
      Start-Sleep -Seconds $DelaySeconds
    }
  }
  throw "Role $RoleName not assignment-ready after $ReadyTimeoutSeconds seconds"
}

function Get-RoleAssignments {
  param(
    [Parameter(Mandatory=$true)][string]$PrincipalId,
    [Parameter(Mandatory=$true)][string]$RoleDefinitionId, # full ARM id
    [Parameter(Mandatory=$true)][string]$Scope
  )

  # az role assignment list is ARM-based and supports object id filtering (no Graph)
  $json = Invoke-Az -Args @(
    "role","assignment","list",
    "--assignee-object-id",$PrincipalId,
    "--scope",$Scope,
    "--role",$RoleDefinitionId,
    "-o","json"
  ) -NoThrow

  if (-not $json) { return @() }
  try { return ($json | ConvertFrom-Json) } catch { return @() }
}

function New-RoleAssignment {
  param(
    [Parameter(Mandatory=$true)][string]$PrincipalId,
    [Parameter(Mandatory=$true)][string]$RoleDefinitionId,
    [Parameter(Mandatory=$true)][string]$Scope,
    [Parameter(Mandatory=$false)][string]$PrincipalType = "ServicePrincipal"
  )

  # Create assignment with explicit object id and principal type (no Graph resolution)
  Invoke-Az -Args @(
    "role","assignment","create",
    "--assignee-object-id",$PrincipalId,
    "--assignee-principal-type",$PrincipalType,
    "--role",$RoleDefinitionId,
    "--scope",$Scope,
    "--only-show-errors",
    "-o","none"
  ) | Out-Null
}

function Ensure-Assignment {
  param(
    [Parameter(Mandatory=$true)][string]$RoleDefinitionId,
    [Parameter(Mandatory=$true)][string]$RoleName,
    [Parameter(Mandatory=$true)][string]$AssigneeObjectId,
    [Parameter(Mandatory=$true)][string]$Scope,
    [string]$PrincipalType = "ServicePrincipal",
    [int]$Retries = 7,
    [int]$DelaySeconds = 10,
    [int]$VerifyAttempts = 10,
    [int]$VerifyDelaySeconds = 15
  )

  Write-Log "INFO" "Step: Ensuring role assignment of $RoleName to $AssigneeObjectId"

  for ($attempt=1; $attempt -le $Retries; $attempt++) {
    try {
      $existing = Get-RoleAssignments -PrincipalId $AssigneeObjectId -RoleDefinitionId $RoleDefinitionId -Scope $Scope
      if ($existing -and $existing.Count -gt 0) {
        Write-Log "INFO" "Role $RoleName already assigned to $AssigneeObjectId"
        return
      }

      New-RoleAssignment -PrincipalId $AssigneeObjectId -RoleDefinitionId $RoleDefinitionId -Scope $Scope -PrincipalType $PrincipalType
      Write-Log "INFO" "Created role assignment for $RoleName on $AssigneeObjectId"

      for ($i=0; $i -lt $VerifyAttempts; $i++) {
        Start-Sleep -Seconds $VerifyDelaySeconds
        $check = Get-RoleAssignments -PrincipalId $AssigneeObjectId -RoleDefinitionId $RoleDefinitionId -Scope $Scope
        Write-Log "INFO" "value for Get-RoleAssignment is $check"
         
        if ($check) {
          Write-Log "INFO" "Role $RoleName assignment verified for $AssigneeObjectId"
          return
        }
        Write-Log "INFO" "Waiting for assignment of $RoleName to propagate..."
      }

      throw "Assignment of $RoleName not visible after $($VerifyAttempts * $VerifyDelaySeconds) seconds"
    }
    catch {
      Write-Log "ERROR" ("Attempt {0}/{1}: Failed to assign role {2} to {3} (reason: {4})" -f $attempt,$Retries,$RoleName,$AssigneeObjectId,$_.Exception.Message)
      if ($attempt -lt $Retries) {
        Write-Log "INFO" "Retrying in $DelaySeconds seconds..."
        Start-Sleep -Seconds $DelaySeconds
      } else {
        throw
      }
    }
  }
}

# -------------------- MAIN --------------------
Assert-Exe -Name "az"

# Resolve az path and detect if it's a batch file (az.cmd/az.bat)
$script:AzPath  = (Get-Command az).Source
$script:IsAzCmd = ($script:AzPath -match '\.(cmd|bat)$')
Write-Log "DEBUG" ("az resolved to: {0} (IsAzCmd={1})" -f $script:AzPath, $script:IsAzCmd)


$subscriptionScope = "/subscriptions/$SubscriptionId"
$suffix = [guid]::NewGuid().ToString()

$aitlRoleName     = "AITL Delegator_$suffix"
$aitlJobsRoleName = "AITL Jobs Access_$suffix"

Write-Log "INFO" "Script parameters:"
Write-Log "INFO" " AITL Role Name: $aitlRoleName"
Write-Log "INFO" " AITL Jobs Role Name: $aitlJobsRoleName"
Write-Log "INFO" " AITL SPN ObjectId: $LinuxAdvancedTestSpnObjectId"
Write-Log "INFO" " Validate SPN ObjectId: $ValidateSpnObjectId"
Write-Log "INFO" " Subscription scope: $subscriptionScope"

# Ensure correct subscription context (Python prints info; this makes it deterministic) [1](https://microsoft.sharepoint.com/teams/AzureIDC/AzureIDC_CRP/Shared%20Documents/AzCertify/SelfServiceValidation/CustomerScriptAITL.py)
Invoke-Az -Args @("account","set","--subscription",$SubscriptionId) | Out-Null

$whoami = Invoke-Az -Args @("account","show","-o","json")
$whoObj = $whoami | ConvertFrom-Json
Write-Log "INFO" ("Logged in as: {0}" -f $whoObj.user.name)

$subInfo = Invoke-Az -Args @("account","show","--subscription",$SubscriptionId,"-o","json")
$subObj = $subInfo | ConvertFrom-Json
Write-Log "INFO" ("Current subscription: {0}" -f $subObj.name)
Write-Log "INFO" ("=" * 60)

# ---- AITL Delegator role (actions list ported as-is) [1](https://microsoft.sharepoint.com/teams/AzureIDC/AzureIDC_CRP/Shared%20Documents/AzCertify/SelfServiceValidation/CustomerScriptAITL.py)
$delegatorActions = @(
  "Microsoft.Resources/subscriptions/resourceGroups/read",
  "Microsoft.Resources/subscriptions/resourceGroups/write",
  "Microsoft.Resources/subscriptions/resourceGroups/delete",
  "Microsoft.Resources/deployments/read",
  "Microsoft.Resources/deployments/write",
  "Microsoft.Resources/deployments/validate/action",
  "Microsoft.Resources/deployments/operationStatuses/read",
  "Microsoft.Compute/virtualMachines/read",
  "Microsoft.Compute/virtualMachines/write",
  "Microsoft.Compute/virtualMachines/retrieveBootDiagnosticsData/action",
  "Microsoft.Compute/availabilitySets/write",
  "Microsoft.Compute/virtualMachines/start/action",
  "Microsoft.Compute/virtualMachines/restart/action",
  "Microsoft.Compute/virtualMachines/deallocate/action",
  "Microsoft.Compute/virtualMachines/powerOff/action",
  "Microsoft.Compute/disks/read",
  "Microsoft.Compute/disks/write",
  "Microsoft.Compute/disks/delete",
  "Microsoft.Compute/images/read",
  "Microsoft.Compute/images/write",
  "Microsoft.Compute/galleries/images/read",
  "Microsoft.Compute/galleries/images/write",
  "Microsoft.Compute/galleries/images/delete",
  "Microsoft.Compute/galleries/images/versions/read",
  "Microsoft.Compute/galleries/images/versions/write",
  "Microsoft.Compute/galleries/images/versions/delete",
  "Microsoft.Compute/galleries/read",
  "Microsoft.Compute/galleries/write",
  "Microsoft.Compute/virtualMachines/extensions/read",
  "Microsoft.Compute/virtualMachines/extensions/write",
  "Microsoft.Compute/virtualMachines/extensions/delete",
  "Microsoft.Compute/virtualMachines/assessPatches/action",
  "Microsoft.Compute/virtualMachines/vmSizes/read",
  "Microsoft.Compute/restorePointCollections/write",
  "Microsoft.Compute/restorePointCollections/restorePoints/read",
  "Microsoft.Compute/restorePointCollections/restorePoints/write",
  "Microsoft.ManagedIdentity/userAssignedIdentities/write",
  "Microsoft.ManagedIdentity/userAssignedIdentities/assign/action",
  "Microsoft.Network/virtualNetworks/read",
  "Microsoft.Network/virtualNetworks/write",
  "Microsoft.Network/virtualNetworks/subnets/join/action",
  "Microsoft.Network/publicIPAddresses/read",
  "Microsoft.Network/publicIPAddresses/write",
  "Microsoft.Network/publicIPAddresses/join/action",
  "Microsoft.Network/networkInterfaces/read",
  "Microsoft.Network/networkInterfaces/write",
  "Microsoft.Network/networkInterfaces/join/action",
  "Microsoft.Network/routeTables/read",
  "Microsoft.Network/routeTables/write",
  "Microsoft.Network/privateEndpoints/write",
  "Microsoft.Network/privateLinkServices/PrivateEndpointConnectionsApproval/action",
  "Microsoft.SerialConsole/serialPorts/write",
  "Microsoft.Network/networkSecurityGroups/write",
  "Microsoft.Network/networkSecurityGroups/read",
  "Microsoft.Network/networkSecurityGroups/join/action",
  "Microsoft.Storage/storageAccounts/read",
  "Microsoft.Storage/storageAccounts/write",
  "Microsoft.Storage/storageAccounts/listKeys/action",
  "Microsoft.Storage/storageAccounts/blobServices/containers/delete",
  "Microsoft.Storage/storageAccounts/blobServices/containers/read",
  "Microsoft.Storage/storageAccounts/blobServices/containers/write",
  "Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action"
)

$delegatorDataActions = @(
  "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete",
  "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",
  "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write",
  "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action"
)

$delegatorRoleDef = New-RoleDefinitionObject `
  -RoleName $aitlRoleName `
  -Description "Delegation role is to run test cases and upload logs in Azure Image Testing for Linux (AITL)." `
  -Actions $delegatorActions `
  -DataActions $delegatorDataActions `
  -AssignableScope $subscriptionScope

$delegatorRoleId = Ensure-Role -RoleDef $delegatorRoleDef -RoleName $aitlRoleName -Scope $subscriptionScope
Ensure-Assignment -RoleDefinitionId $delegatorRoleId -RoleName $aitlRoleName -AssigneeObjectId $LinuxAdvancedTestSpnObjectId -Scope $subscriptionScope

# ---- AITL Jobs Access role [1](https://microsoft.sharepoint.com/teams/AzureIDC/AzureIDC_CRP/Shared%20Documents/AzCertify/SelfServiceValidation/CustomerScriptAITL.py)
$jobsActions = @(
  "Microsoft.AzureImageTestingForLinux/jobTemplates/read",
  "Microsoft.AzureImageTestingForLinux/jobTemplates/write",
  "Microsoft.AzureImageTestingForLinux/jobTemplates/delete",
  "Microsoft.AzureImageTestingForLinux/jobs/read",
  "Microsoft.AzureImageTestingForLinux/jobs/write",
  "Microsoft.AzureImageTestingForLinux/jobs/delete",
  "Microsoft.AzureImageTestingForLinux/operations/read",
  "Microsoft.Resources/subscriptions/read",
  "Microsoft.Resources/subscriptions/operationresults/read",
  "Microsoft.Resources/subscriptions/resourcegroups/write",
  "Microsoft.Resources/subscriptions/resourcegroups/read",
  "Microsoft.Resources/subscriptions/resourcegroups/delete"
)

$jobsRoleDef = New-RoleDefinitionObject `
  -RoleName $aitlJobsRoleName `
  -Description "Job access role for Azure Image Testing for Linux (AITL)." `
  -Actions $jobsActions `
  -DataActions @() `
  -AssignableScope $subscriptionScope

$jobsRoleId = Ensure-Role -RoleDef $jobsRoleDef -RoleName $aitlJobsRoleName -Scope $subscriptionScope
Ensure-Assignment -RoleDefinitionId $jobsRoleId -RoleName $aitlJobsRoleName -AssigneeObjectId $ValidateSpnObjectId -Scope $subscriptionScope

Write-Log "INFO" "Script completed successfully"