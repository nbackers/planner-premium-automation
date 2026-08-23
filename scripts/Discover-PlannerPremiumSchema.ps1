<#
  Discover-PlannerPremiumSchema.ps1

  Planner Premium plans are Project for the web plans, stored in Dataverse in the
  TENANT DEFAULT environment. This script dumps the exact table + column names you
  need to write OData queries in Power Automate's Dataverse connector.

  Prereq: Azure CLI logged in as a user who can read the environment.
      az login --allow-no-subscriptions

  Usage:
      .\Discover-PlannerPremiumSchema.ps1 -OrgUrl https://orgXXXXXXXX.crm.dynamics.com
      .\Discover-PlannerPremiumSchema.ps1 -OrgUrl https://... -PlanName "Team backlog"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $OrgUrl,
    [string] $PlanName
)

$ErrorActionPreference = 'Stop'
$OrgUrl = $OrgUrl.TrimEnd('/')

Write-Host "Acquiring token for $OrgUrl ..." -ForegroundColor Cyan
$token = az account get-access-token --resource $OrgUrl --query accessToken -o tsv
if (-not $token) { throw "Could not acquire a token. Run 'az login --allow-no-subscriptions' first." }

$headers = @{
    Authorization      = "Bearer $token"
    Accept             = 'application/json'
    'OData-Version'    = '4.0'
    'OData-MaxVersion' = '4.0'
}

function Invoke-Dv([string] $RelativeUrl) {
    Invoke-RestMethod -Uri "$OrgUrl/api/data/v9.2/$RelativeUrl" -Headers $headers -Method Get
}

# ---------------------------------------------------------------------------
# 1. Which Project / Planner tables actually exist in this environment?
# ---------------------------------------------------------------------------
Write-Host "`n=== 1. Project / Planner tables present ===" -ForegroundColor Green

$allEntities = (Invoke-Dv 'EntityDefinitions?$select=LogicalName,EntitySetName,DisplayName').value

$interesting = $allEntities | Where-Object {
    $_.LogicalName -like 'msdyn_project*' -or
    $_.LogicalName -like 'msdyn_task*' -or
    $_.LogicalName -like '*planner*' -or
    $_.LogicalName -like 'msdyn_resourceassignment*' -or
    $_.LogicalName -like '*label*'
} | Sort-Object LogicalName

$hasP4W = $allEntities.LogicalName -contains 'msdyn_projecttask'

if (-not $hasP4W) {
    Write-Warning "msdyn_projecttask was NOT found. This environment does not back Planner Premium."
    Write-Host  "Planner Premium data lives in your tenant's DEFAULT environment - run 'pac org list' and re-run against that URL." -ForegroundColor Yellow
    Write-Host  "(Any tables listed below are unrelated look-alikes.)`n"
}

$interesting | Format-Table @{n = 'LogicalName'; e = { $_.LogicalName } },
@{n = 'EntitySetName (use this in Flow)'; e = { $_.EntitySetName } },
@{n = 'Display'; e = { $_.DisplayName.UserLocalizedLabel.Label } } -AutoSize

# ---------------------------------------------------------------------------
# 2. Full column list for the two tables that matter
# ---------------------------------------------------------------------------
foreach ($table in @('msdyn_project', 'msdyn_projecttask', 'msdyn_projectbucket')) {

    if ($interesting.LogicalName -notcontains $table) { continue }

    Write-Host "`n=== 2. Columns on $table ===" -ForegroundColor Green

    $attrs = (Invoke-Dv "EntityDefinitions(LogicalName='$table')/Attributes?`$select=LogicalName,SchemaName,AttributeType,IsValidForCreate,IsValidForUpdate").value |
    Where-Object { $_.AttributeType -ne 'Virtual' } |
    Sort-Object LogicalName

    $attrs | Format-Table @{n = 'Column'; e = { $_.LogicalName } },
    @{n = 'Type'; e = { $_.AttributeType } },
    @{n = 'Create'; e = { $_.IsValidForCreate } },
    @{n = 'Update'; e = { $_.IsValidForUpdate } } -AutoSize

    # Anything that smells like a label / tag / category - this is the column
    # that Planner Premium's "escalate" tag most likely maps to.
    $tagish = $attrs | Where-Object {
        $_.LogicalName -match 'label|tag|categor|flag|escalat'
    }
    if ($tagish) {
        Write-Host "  >> Candidate label/tag columns on ${table}:" -ForegroundColor Yellow
        $tagish | ForEach-Object { Write-Host "     $($_.LogicalName)  [$($_.AttributeType)]" -ForegroundColor Yellow }
    }
}

# ---------------------------------------------------------------------------
# 3. Lookups on msdyn_projecttask (needed to build @odata.bind on create)
# ---------------------------------------------------------------------------
if ($interesting.LogicalName -contains 'msdyn_projecttask') {

    Write-Host "`n=== 3. Lookups on msdyn_projecttask (for @odata.bind) ===" -ForegroundColor Green

    $rels = (Invoke-Dv "EntityDefinitions(LogicalName='msdyn_projecttask')/ManyToOneRelationships?`$select=SchemaName,ReferencingAttribute,ReferencedEntity,ReferencingEntityNavigationPropertyName").value |
    Where-Object { $_.ReferencedEntity -like 'msdyn_*' -or $_.ReferencedEntity -in @('systemuser', 'team') } |
    Sort-Object ReferencingAttribute

    $rels | Format-Table @{n = 'Column'; e = { $_.ReferencingAttribute } },
    @{n = 'Points at'; e = { $_.ReferencedEntity } },
    @{n = 'Navigation property (use in @odata.bind)'; e = { $_.ReferencingEntityNavigationPropertyName } } -AutoSize
}

# ---------------------------------------------------------------------------
# 4. Sample data - the fastest way to see how a real "escalate" tag is stored
# ---------------------------------------------------------------------------
Write-Host "`n=== 4. Sample plans ===" -ForegroundColor Green

if (-not $hasP4W) {
    Write-Host "Skipped - msdyn_projecttask not present in this environment." -ForegroundColor Yellow
    Write-Host "`nDone." -ForegroundColor Cyan
    return
}

$planFilter = ''
if ($PlanName) { $planFilter = "&`$filter=contains(msdyn_subject,'$PlanName')" }

$plans = (Invoke-Dv "msdyn_projects?`$select=msdyn_projectid,msdyn_subject,createdon&`$top=20&`$orderby=createdon desc$planFilter").value
$plans | Format-Table msdyn_subject, msdyn_projectid -AutoSize

if ($plans) {
    $plan = $plans[0]
    Write-Host "`n=== 5. Raw JSON of tasks in plan '$($plan.msdyn_subject)' ===" -ForegroundColor Green
    Write-Host "Look here for how your 'escalate' tag is actually persisted." -ForegroundColor Yellow

    $tasks = (Invoke-Dv "msdyn_projecttasks?`$filter=_msdyn_project_value eq $($plan.msdyn_projectid)&`$top=5").value
    $tasks | ConvertTo-Json -Depth 6
}

Write-Host "`nDone." -ForegroundColor Cyan
