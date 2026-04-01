<#
.SYNOPSIS
  Combined Compute Validation for VM Image prerequisites:
   - Microsoft.Validate 
   - Managed RG creation + RBAC for Validate RP SP
   - Linux Advanced Test prereqs (Microsoft.AzureImageTestingForLinux + Compute/Network/Storage)
   - Optional: run Linux Advanced Test permissions bootstrap script (CustomScriptLinuxAdvanced-powershell.ps1)

.DESCRIPTION
  This consolidates functionality from:
   - SelfServeOnBoardingScript.ps1
   - CustomScriptLinxTest-powershell.ps1
  and shares common functions (no duplication).

.EXAMPLE
  pwsh -ExecutionPolicy Bypass -File .\SelfServeOnBoardingScript.ps1 `
    -SubscriptionId 184cdb00-9604-4154-ba2f-0c89a10710c3 `
    -DeploymentLocation southcentralus `
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string] $SubscriptionId,

  # Validate RP appId used by Linux Advanced Test permissions bootstrap (Linux Advanced Test doc default)
  [Parameter(Mandatory=$false)]
  [string] $ValidateRpAppIdForLinuxTest = 'f877b90d-59ee-40e3-8d2c-215dae4c80d8',

  [Parameter(Mandatory=$false)]
  [string] $LinuxSpDisplayName = 'AzureImageTestingForLinux',

  [Parameter(Mandatory=$false)]
  [switch] $RunLinuxPrereqs = $true,

  [Parameter(Mandatory=$false)]
  [switch] $RunLinuxAdvancedTestPermissionsScript = $true,

  # Optional: enable Defender for Servers P2 + Agentless scanning + MDVM VA at subscription level
  [Parameter(Mandatory=$false)]
  [switch] $EnableDefender = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------- Common Helpers --------------------

function Write-Log {
  param(
    [Parameter(Mandatory=$true)][ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level,
    [Parameter(Mandatory=$true)][string]$Message
  )
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "$ts[$Level] $Message"
}

function Assert-Exe {
  param([Parameter(Mandatory=$true)][string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required executable not found: $Name"
  }
}

# Avoid CLI session folder permission issues on some machines/agents
function Initialize-AzureCliConfigDir {
  if (-not $env:AZURE_CONFIG_DIR -or $env:AZURE_CONFIG_DIR.Trim().Length -eq 0) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("azure-config-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $env:AZURE_CONFIG_DIR = $tmp
    Write-Log DEBUG "Using AZURE_CONFIG_DIR=$env:AZURE_CONFIG_DIR"
  } else {
    New-Item -ItemType Directory -Path $env:AZURE_CONFIG_DIR -Force | Out-Null
    Write-Log DEBUG "Using existing AZURE_CONFIG_DIR=$env:AZURE_CONFIG_DIR"
  }
}

# Robust AZ invocation (NO -split; supports quoted args correctly)
function Invoke-Az {
  param(
    [Parameter(Mandatory=$true)][string[]]$Args,
    [switch] $NoThrow,
    [Parameter(Mandatory=$false)][string]$StdinInput
  )

  Write-Log DEBUG ("Running: az " + ($Args -join ' '))
  if ($StdinInput) {
    Write-Log DEBUG ("Stdin input: $StdinInput")
  }

  # Prevent stderr warnings from becoming terminating errors under strict environments
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($StdinInput) {
      $raw = $StdinInput | & az @Args 2>&1
    } else {
      $raw = & az @Args 2>&1
    }
    $exit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prevEap
  }

  $out = ($raw | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { $_ }
  } | Out-String).Trim()

  if ($exit -ne 0) {
    if (-not $NoThrow) {
      throw "az failed (exit=$exit): az $($Args -join ' ')`n$out"
    }
  }

  return $out
}

function Ensure-AzLogin {
  try {
    Invoke-Az -Args @('account','show','-o','none') | Out-Null
  } catch {
    Write-Log INFO "Not logged into Azure CLI. Launching 'az login'..."
    Invoke-Az -Args @('login','-o','none') | Out-Null
  }
}

function Set-AzSubscription {
  param([Parameter(Mandatory=$true)][string]$SubId)
  Invoke-Az -Args @('account','set','--subscription', $SubId) | Out-Null
  $sub = Invoke-Az -Args @('account','show','--query','name','-o','tsv')
  Write-Log INFO "Using subscription: $sub ($SubId)"
}

function Wait-Feature {
  param(
    [Parameter(Mandatory=$true)][string]$Ns,
    [Parameter(Mandatory=$true)][string]$Name,
    [int]$Timeout = 1800
  )
  $deadline = (Get-Date).AddSeconds($Timeout)
  while ((Get-Date) -lt $deadline) {
    $state = (Invoke-Az -Args @('feature','show','--namespace',$Ns,'--name',$Name,'--query','properties.state','-o','tsv')).Trim()
    if ($state -eq 'Registered') {
      Write-Log INFO "Feature $Ns/$Name Registered"
      return
    }
    Write-Log INFO "Feature $Ns/$Name state=$state; waiting..."
    Start-Sleep -Seconds 10
  }
  throw "Timeout waiting feature $Ns/$Name"
}

function Wait-Provider {
  param(
    [Parameter(Mandatory=$true)][string]$Ns,
    [int]$Timeout = 1800
  )
  $deadline = (Get-Date).AddSeconds($Timeout)
  while ((Get-Date) -lt $deadline) {
    $state = (Invoke-Az -Args @('provider','show','--namespace',$Ns,'--query','registrationState','-o','tsv')).Trim()
    if ($state -eq 'Registered') {
      Write-Log INFO "Provider $Ns Registered"
      return
    }
    Write-Log INFO "Provider $Ns state=$state; waiting..."
    Start-Sleep -Seconds 10
  }
  throw "Timeout waiting provider $Ns"
}

function Resolve-SpObjectIdByAppId {
  param([Parameter(Mandatory=$true)][string]$AppId)
  # More reliable than az ad sp list --filter (and avoids quoting issues)
  $id = (Invoke-Az -Args @('ad','sp','show','--id',$AppId,'--query','id','-o','tsv')).Trim()
  if (-not $id) { throw "Could not resolve service principal objectId for appId=$AppId" }
  $id
}

function Resolve-SpObjectIdByDisplayName {
  param([Parameter(Mandatory=$true)][string]$Name)
  $id = (Invoke-Az -Args @('ad','sp','list','--display-name',$Name,'--query','[0].id','-o','tsv')).Trim()
  if (-not $id) { throw "Could not resolve service principal objectId for displayName=$Name" }
  $id
}

function Ensure-ResourceGroup {
  param(
    [Parameter(Mandatory=$true)][string]$RgName,
    [Parameter(Mandatory=$true)][string]$Location
  )
  Invoke-Az -Args @('group','create','--name',$RgName,'--location',$Location,'-o','none') | Out-Null
  Write-Log INFO "Resource group ensured: $RgName ($Location)"
}

function Ensure-RoleAssignment {
  param(
    [Parameter(Mandatory=$true)][string]$Scope,
    [Parameter(Mandatory=$true)][string]$AssigneeObjectId,
    [Parameter(Mandatory=$true)][string]$RoleName,
    [Parameter(Mandatory=$false)][string]$PrincipalType = 'ServicePrincipal'
  )

  # First check (avoids noisy failures)
  $existing = Invoke-Az -Args @(
    'role','assignment','list',
    '--assignee-object-id',$AssigneeObjectId,
    '--scope',$Scope,
    '--query', "[?roleDefinitionName=='$RoleName'] | [0].id",
    '-o','tsv'
  ) -NoThrow

  if ($existing -and $existing.Trim().Length -gt 0) {
    Write-Log INFO "Role already assigned: '$RoleName' -> $AssigneeObjectId on $Scope"
    return
  }

  # Create
  Invoke-Az -Args @(
    'role','assignment','create',
    '--assignee-object-id',$AssigneeObjectId,
    '--assignee-principal-type',$PrincipalType,
    '--role',$RoleName,
    '--scope',$Scope,
    '--only-show-errors',
    '-o','none'
  ) | Out-Null

  Write-Log INFO "Role assigned: '$RoleName' -> $AssigneeObjectId on $Scope"
}

function Resolve-LinuxPermissionsScript {
  # Run the PowerShell permissions script
  $candidate = Join-Path $PSScriptRoot 'CustomScriptLinuxTest-powershell.ps1'
  if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
  throw "Missing Linux advanced test permissions script: $candidate"
}

# -------------------- MAIN --------------------

Assert-Exe az
Initialize-AzureCliConfigDir
Ensure-AzLogin
Set-AzSubscription -SubId $SubscriptionId

# --------- RP prereqs (Microsoft.Validate + Microsoft.Resources) ---------

Write-Log INFO "Registering Microsoft.Validate feature + provider..."
Invoke-Az -Args @('feature','register','--namespace','Microsoft.Validate','--name','SelfServeVMImageValidation','--only-show-errors') | Out-Null
Wait-Feature -Ns 'Microsoft.Validate' -Name 'SelfServeVMImageValidation'
Invoke-Az -Args @('provider','register','--namespace','Microsoft.Validate') | Out-Null
Wait-Provider -Ns 'Microsoft.Validate'

Invoke-Az -Args @('provider','register','--namespace','Microsoft.Resources') | Out-Null
Wait-Provider -Ns 'Microsoft.Resources'


# --------- Linux Advanced Test prereqs ---------

if ($RunLinuxPrereqs) {
  Write-Log INFO "Registering linuxAdvancedTestSp feature + provider..."
  Invoke-Az -Args @('feature','register','--namespace','Microsoft.AzureImageTestingForLinux','--name','JobandJobTemplateCrud','--only-show-errors') | Out-Null
  Wait-Feature -Ns 'Microsoft.AzureImageTestingForLinux' -Name 'JobandJobTemplateCrud'

  Invoke-Az -Args @('provider','register','--namespace','Microsoft.AzureImageTestingForLinux','--only-show-errors') | Out-Null
  Wait-Provider -Ns 'Microsoft.AzureImageTestingForLinux'

  Write-Log INFO "Registering dependent providers: Microsoft.Compute, Microsoft.Network, Microsoft.Storage..."
  foreach ($ns in @('Microsoft.Compute','Microsoft.Network','Microsoft.Storage')) {
    Invoke-Az -Args @('provider','register','--namespace',$ns) | Out-Null
    Wait-Provider -Ns $ns
  }

  Write-Log INFO "Linux prerequisites completed."
} else {
  Write-Log INFO "Skipping Linux prereqs (RunLinuxPrereqs not set)."
}

# --------- Linux Advanced Test permissions bootstrap (Custom roles + assignments) ---------

if ($RunLinuxAdvancedTestPermissionsScript) {
  $validateSp = Resolve-SpObjectIdByAppId -AppId $ValidateRpAppIdForLinuxTest
  $linuxAdvancedTestSp     = Resolve-SpObjectIdByDisplayName -Name $LinuxSpDisplayName

  Write-Log INFO "Validate RP SP objectId (Linux Advanced Test script): $validateSp"
  Write-Log INFO "Linux Advanced Test RP SP objectId: $linuxAdvancedTestSp"

  $permScript = Resolve-LinuxPermissionsScript
  Write-Log INFO "Running Linux Advanced Test Validation permissions bootstrap: $permScript"

  # Run the PowerShell permissions script
  & $permScript -SubscriptionId $SubscriptionId -ValidateSpnObjectId $validateSp -LinuxAdvancedTestSpnObjectId $linuxAdvancedTestSp
  if ($LASTEXITCODE -ne 0) { throw "Linux Advanced Test permissions script failed (exit=$LASTEXITCODE)" }

  Write-Log INFO "Linux Advanced Test permissions bootstrap completed."
} else {
  Write-Log INFO "Skipping Linux Advanced Test permissions permissions bootstrap (RunLinuxAdvancedTestPermissionsScript not set)."
}

# --------- Defender for Cloud: Servers P2 + Agentless scanning + MDVM VA (Subscription scope) ---------
if ($EnableDefender) {
  try {
    Write-Log INFO "EnableDefender=true -> Enabling Microsoft Defender for Servers Plan 2 + Agentless scanning + MDVM Vulnerability Assessment (subscription-level)..."

    # 1) Enable Defender for Servers Plan 2 AND Agentless scanning extension on VirtualMachines plan
    $pricingUrl = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Security/pricings/VirtualMachines?api-version=2024-01-01"

    $pricingBody = @'
{
  "properties": {
    "pricingTier": "Standard",
    "subPlan": "P2",
    "extensions": [
      {
        "name": "AgentlessVmScanning",
        "isEnabled": "True"
      }
    ]
  }
}
'@

    Invoke-Az -Args @(
      'rest',
      '--method','put',
      '--url', $pricingUrl,
      '--headers','Content-Type=application/json',
      '--body','@-',
      '-o','none'
    ) -StdinInput $pricingBody | Out-Null

    Write-Log INFO "Defender for Servers Plan2 enabled and Agentless VM scanning enabled on VirtualMachines plan."

    # 2) Enable Vulnerability Assessment provider (MDVM) at subscription scope
    $vaUrl = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Security/serverVulnerabilityAssessmentsSettings/azureServersSetting?api-version=2023-05-01"

    $vaBody = @'
{
  "kind": "AzureServersSetting",
  "properties": {
    "selectedProvider": "MdeTvm"
  }
}
'@

    Invoke-Az -Args @(
      'rest',
      '--method','put',
      '--url', $vaUrl,
      '--headers','Content-Type=application/json',
      '--body','@-',
      '-o','none'
    ) -StdinInput $vaBody | Out-Null

    Write-Log INFO "MDVM Vulnerability Assessment provider enabled (selectedProvider=MdeTvm)."

    # # Optional verification (non-fatal)
    # Write-Log INFO "Verifying Defender pricing + VA settings (best effort)..."
    # $pricingCheck = Invoke-Az -Args @('rest','--method','get','--url',$pricingUrl,'-o','json') -NoThrow
    # if ($pricingCheck) { Write-Log DEBUG "VirtualMachines pricing response: $pricingCheck" }

    # $vaCheck = Invoke-Az -Args @('rest','--method','get','--url',$vaUrl,'-o','json') -NoThrow
    # if ($vaCheck) { Write-Log DEBUG "VA settings response: $vaCheck" }

    Write-Log INFO "Defender enablement completed ✅"
  }
  catch {
    Write-Log WARN "Defender enablement failed (continuing script): $($_.Exception.Message)"
  }
} else {
  Write-Log INFO "EnableDefender=false -> Skipping Defender enablement."
}
# --------- End Defender for Cloud section ---------


Write-Log INFO "All prerequisites completed successfully ✅"