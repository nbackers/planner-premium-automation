<#
.SYNOPSIS
    Checks whether an environment can support Planner Premium automation.

.DESCRIPTION
    A go/no-go check to run before building anything. Answers, in order:

      1. Can I authenticate to this environment?
      2. Are the Project for the web tables present?
      3. Is there Planner Premium data in them?
      4. Does the identity I am running as have the licence to read and write?
      5. Which tables and columns will my flow actually use?

    Every check is read-only. Nothing is created or modified.

    Most Planner Premium automations fail at step 2 or 3, because Planner Premium
    data lives in the tenant's DEFAULT environment and people point at a dev
    environment where the tables simply are not present. That produces zero rows
    and no error, which is the usual dead end.

.PARAMETER OrgUrl
    Environment to check, e.g. https://orgXXXXXXXX.crm.dynamics.com

.PARAMETER Detailed
    Also list the columns and lookup navigation properties for the core tables.

.PARAMETER MockPrefix
    Check a mock schema instead of the real Project tables. Use this to rehearse the
    check, or to validate an automation pattern in an environment without a Planner
    Premium licence. Pass the publisher prefix used by Build-MockPlannerSchema.ps1.

.EXAMPLE
    .\Test-PlannerPremiumConnectivity.ps1 -OrgUrl https://orgXXXXXXXX.crm.dynamics.com

.EXAMPLE
    .\Test-PlannerPremiumConnectivity.ps1 -OrgUrl https://... -Detailed

.EXAMPLE
    .\Test-PlannerPremiumConnectivity.ps1 -OrgUrl https://... -MockPrefix cra89

.NOTES
    Requires Azure CLI: az login --allow-no-subscriptions
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $OrgUrl,

    [switch] $Detailed,

    [string] $MockPrefix
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$OrgUrl = $OrgUrl.TrimEnd('/')
$api = "$OrgUrl/api/data/v9.2"

$script:failed = 0
$script:warned = 0

function Write-Check {
    param(
        [Parameter(Mandatory)] [ValidateSet('PASS', 'FAIL', 'WARN', 'INFO')] [string] $Status,
        [Parameter(Mandatory)] [string] $Message,
        [string] $Detail
    )
    $colour = switch ($Status) {
        'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' }
    }
    Write-Host ("  [{0}] {1}" -f $Status, $Message) -ForegroundColor $colour
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }

    if ($Status -eq 'FAIL') { $script:failed++ }
    if ($Status -eq 'WARN') { $script:warned++ }
}

Write-Host ''
Write-Host "Planner Premium connectivity check" -ForegroundColor Cyan
Write-Host "Target: $OrgUrl"
Write-Host ''

# --- 1. Authentication ------------------------------------------------------

Write-Host '1. Authentication' -ForegroundColor White

$token = & az account get-access-token --resource $OrgUrl --query accessToken -o tsv 2>$null
if (-not $token) {
    Write-Check -Status FAIL -Message 'Could not acquire a token' -Detail "Run 'az login --allow-no-subscriptions' then retry."
    Write-Host ''
    exit 1
}
Write-Check -Status PASS -Message 'Token acquired'

$headers = @{
    Authorization      = "Bearer $token"
    Accept             = 'application/json'
    'OData-Version'    = '4.0'
    'OData-MaxVersion' = '4.0'
}

function Invoke-Dv {
    param([string] $RelativeUrl)
    Invoke-RestMethod -Uri "$api/$RelativeUrl" -Headers $headers -Method Get -ErrorAction Stop
}

try {
    $who = Invoke-Dv 'WhoAmI'
    Write-Check -Status PASS -Message 'Environment reachable' -Detail "UserId $($who.UserId)"
}
catch {
    Write-Check -Status FAIL -Message 'Could not reach the environment' -Detail $_.Exception.Message
    Write-Host ''
    exit 1
}

# --- 2. Are the tables present? --------------------------------------------

Write-Host ''

if ($MockPrefix) {
    Write-Host "2. Mock schema tables (prefix '$MockPrefix')" -ForegroundColor White
    $core = @("${MockPrefix}_mockplan", "${MockPrefix}_mocktask", "${MockPrefix}_mockbucket")
    $optional = @()
    $taskTable = "${MockPrefix}_mocktask"
    $planTable = "${MockPrefix}_mockplan"
}
else {
    Write-Host '2. Project for the web tables' -ForegroundColor White
    $core = @('msdyn_project', 'msdyn_projecttask', 'msdyn_projectbucket')
    $optional = @('msdyn_resourceassignment', 'msdyn_projectteam')
    $taskTable = 'msdyn_projecttask'
    $planTable = 'msdyn_project'
}

$present = @{}
foreach ($t in ($core + $optional)) {
    try {
        $meta = Invoke-Dv "EntityDefinitions(LogicalName='$t')?`$select=LogicalName,EntitySetName"
        $present[$t] = $meta.EntitySetName
    }
    catch {
        $present[$t] = $null
    }
}

$missingCore = $core | Where-Object { -not $present[$_] }

if ($missingCore) {
    Write-Check -Status FAIL -Message "Core tables missing: $($missingCore -join ', ')"
    Write-Host ''
    if ($MockPrefix) {
        Write-Host '  The mock schema is not present in this environment.' -ForegroundColor Yellow
        Write-Host '  Create it with:' -ForegroundColor Yellow
        Write-Host "      .\Build-MockPlannerSchema.ps1 -OrgUrl $OrgUrl" -ForegroundColor Yellow
    }
    else {
        Write-Host '  This environment does not back Planner Premium.' -ForegroundColor Yellow
        Write-Host '  Planner Premium writes to the tenant DEFAULT environment. Run:' -ForegroundColor Yellow
        Write-Host '      pac org list' -ForegroundColor Yellow
        Write-Host '  and retry against the default environment URL.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  If you are looking at the right environment, the Project app may not be' -ForegroundColor Yellow
        Write-Host '  installed. Entitlement alone does not provision the tables.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  To rehearse without a licence, build the mock schema and re-run with' -ForegroundColor Yellow
        Write-Host '  -MockPrefix. See docs/automation-patterns.md.' -ForegroundColor Yellow
    }
    Write-Host ''
    exit 1
}

foreach ($t in $core) {
    Write-Check -Status PASS -Message "$t present" -Detail "entity set: $($present[$t])"
}
foreach ($t in $optional) {
    if ($present[$t]) { Write-Check -Status PASS -Message "$t present" }
    else { Write-Check -Status WARN -Message "$t not present" -Detail 'Only needed for assignment or membership scenarios.' }
}

# --- 3. Is there data? ------------------------------------------------------

Write-Host ''
Write-Host '3. Plan and task data' -ForegroundColor White

$planSet = $present[$planTable]
$taskSet = $present[$taskTable]
$planNameCol = if ($MockPrefix) { "${MockPrefix}_subject" } else { 'msdyn_subject' }

try {
    $plans = (Invoke-Dv "$planSet`?`$top=5").value
    if ($plans.Count -eq 0) {
        Write-Check -Status WARN -Message 'No plans found' -Detail 'Tables exist but are empty. Create a plan, or seed the mock data.'
    }
    else {
        Write-Check -Status PASS -Message "$($plans.Count) plan(s) visible (showing up to 5)"
        foreach ($p in $plans) {
            $label = if ($p.PSObject.Properties.Name -contains $planNameCol) { $p.$planNameCol } else { '(unnamed)' }
            Write-Host "         - $label" -ForegroundColor DarkGray
        }
    }
}
catch {
    Write-Check -Status FAIL -Message "Could not read $planSet" -Detail $_.Exception.Message
}

try {
    $tasks = (Invoke-Dv "$taskSet`?`$top=1").value
    if ($tasks.Count -gt 0) { Write-Check -Status PASS -Message 'Tasks readable' }
    else { Write-Check -Status WARN -Message 'No tasks found' -Detail 'A trigger on this table will never fire until there are tasks.' }
}
catch {
    Write-Check -Status FAIL -Message "Could not read $taskSet" -Detail $_.Exception.Message
}

# --- 4. Licence and write capability ---------------------------------------

Write-Host ''
Write-Host '4. Write capability' -ForegroundColor White

if ($MockPrefix) {
    Write-Check -Status INFO -Message 'Mock tables accept direct creates' -Detail 'Real msdyn_projecttask and msdyn_projectbucket do not. See docs/automation-patterns.md.'
}
else {
    # msdyn_projecttask and msdyn_projectbucket reject direct creates by design.
    # Tasks must be created through the Project Schedule API operations.
    $scheduleApis = @('msdyn_CreateOperationSetV1', 'msdyn_PssCreateV1', 'msdyn_ExecuteOperationSetV1')
    $foundApis = @()

    foreach ($a in $scheduleApis) {
        try {
            Invoke-RestMethod -Uri "$api/$a" -Headers $headers -Method Get -ErrorAction Stop | Out-Null
            $foundApis += $a
        }
        catch {
            $code = $null
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                $code = $_.Exception.Response.StatusCode.value__
            }
            # A GET against an unbound action returns 405 when it exists, 404 when it does not.
            if ($code -eq 405) { $foundApis += $a }
        }
    }

    if ($foundApis.Count -eq $scheduleApis.Count) {
        Write-Check -Status PASS -Message 'Project Schedule API operations present' -Detail ($foundApis -join ', ')
    }
    elseif ($foundApis.Count -gt 0) {
        Write-Check -Status WARN -Message 'Project Schedule API only partially present' -Detail "Found: $($foundApis -join ', '). Creating tasks may fail."
    }
    else {
        Write-Check -Status WARN -Message 'Project Schedule API operations not detected' -Detail 'Reading will work. Creating tasks needs a full Project install.'
    }

    Write-Host ''
    Write-Host '  Licence note: reading and writing msdyn_* tables needs a Project Plan 3 or' -ForegroundColor DarkGray
    Write-Host '  Planner Premium licence on the identity the flow runs as. A Power Automate' -ForegroundColor DarkGray
    Write-Host '  licence alone is not enough. Check bundled service plans, not SKU names:' -ForegroundColor DarkGray
    Write-Host '      GET https://graph.microsoft.com/v1.0/subscribedSkus' -ForegroundColor DarkGray
}

# --- 5. What your flow will use --------------------------------------------

if ($Detailed) {
    Write-Host ''
    Write-Host '5. Columns and lookups' -ForegroundColor White

    foreach ($t in $core) {
        Write-Host ''
        Write-Host "  $t" -ForegroundColor Cyan
        $attrs = (Invoke-Dv "EntityDefinitions(LogicalName='$t')/Attributes?`$select=LogicalName,AttributeType,IsValidForCreate,IsValidForUpdate").value |
            Where-Object { $_.AttributeType -ne 'Virtual' } | Sort-Object LogicalName
        $attrs | Select-Object @{n='Column';e={$_.LogicalName}},
                               @{n='Type';e={$_.AttributeType}},
                               @{n='Create';e={$_.IsValidForCreate}},
                               @{n='Update';e={$_.IsValidForUpdate}} |
            Format-Table -AutoSize | Out-String | Write-Host
    }

    Write-Host "  Lookup navigation properties on $taskTable (for @odata.bind)" -ForegroundColor Cyan
    $rels = (Invoke-Dv "EntityDefinitions(LogicalName='$taskTable')/ManyToOneRelationships?`$select=ReferencingAttribute,ReferencedEntity,ReferencingEntityNavigationPropertyName").value |
        Sort-Object ReferencingAttribute
    $rels | Select-Object @{n='Column';e={$_.ReferencingAttribute}},
                          @{n='Points at';e={$_.ReferencedEntity}},
                          @{n='Navigation property';e={$_.ReferencingEntityNavigationPropertyName}} |
        Format-Table -AutoSize | Out-String | Write-Host
}

# --- Summary ----------------------------------------------------------------

Write-Host ''
Write-Host ('-' * 62)

if ($script:failed -gt 0) {
    Write-Host "NOT READY - $($script:failed) blocking issue(s)." -ForegroundColor Red
    Write-Host ''
    exit 1
}

if ($script:warned -gt 0) {
    Write-Host "READY WITH WARNINGS - $($script:warned) item(s) to check." -ForegroundColor Yellow
}
else {
    Write-Host 'READY - this environment can support Planner Premium automation.' -ForegroundColor Green
}

Write-Host ''
Write-Host 'Next: run Discover-PlannerPremiumSchema.ps1 for the full schema dump,' -ForegroundColor Cyan
Write-Host 'or see docs/automation-patterns.md to start building.' -ForegroundColor Cyan
Write-Host ''
exit 0
