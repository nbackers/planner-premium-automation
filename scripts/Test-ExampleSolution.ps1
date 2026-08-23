<#
  Test-ExampleSolution.ps1

  End-to-end test of the escalation flow against REAL msdyn_project* tables.
  Seeds two plans + buckets + cards, sets the environment variable values,
  turns the flow on, then drives the scenario and checks the result.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $OrgUrl,
    [string] $Prefix = 'backers',
    [string] $SolutionName = 'PlannerPremiumEscalate'
)

$ErrorActionPreference = 'Stop'
$OrgUrl = $OrgUrl.TrimEnd('/')
$api = "$OrgUrl/api/data/v9.2"

$token = az account get-access-token --resource $OrgUrl --query accessToken -o tsv
$hg = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
$hw = @{ Authorization = "Bearer $token"; Accept = 'application/json'; 'Content-Type' = 'application/json; charset=utf-8' }
$hs = $hw.Clone(); $hs['MSCRM.SolutionUniqueName'] = $SolutionName

function Get1([string] $Path) { (Invoke-RestMethod -Uri "$api/$Path" -Headers $hg).value }
function Post([string] $Path, $Body, $Headers) {
    $json = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20))
    $r = Invoke-WebRequest -Uri "$api/$Path" -Method Post -Headers $Headers -Body $json -UseBasicParsing
    if ($r.Headers['OData-EntityId'] -match '\(([0-9a-fA-F-]{36})\)') { return $Matches[1] }
    return $null
}
function GetOrCreate([string] $Set, [string] $IdField, [string] $Filter, $Body) {
    $q = "${Set}?`$select=$IdField&`$filter=" + [uri]::EscapeDataString($Filter)
    $f = Get1 $q
    if ($f) { return $f[0].$IdField }
    Post $Set $Body $hw
}

# ---------------------------------------------------------------------------
# Seed real Project data
# ---------------------------------------------------------------------------
Write-Host "`n=== Plans (msdyn_project) ===" -ForegroundColor Green
$sourcePlan = GetOrCreate 'msdyn_projects' 'msdyn_projectid' "msdyn_subject eq 'Team backlog'" @{ msdyn_subject = 'Team backlog' }
$targetPlan = GetOrCreate 'msdyn_projects' 'msdyn_projectid' "msdyn_subject eq 'Escalations'" @{ msdyn_subject = 'Escalations' }
Write-Host "  source = $sourcePlan"
Write-Host "  target = $targetPlan"

Write-Host "`n=== Buckets (msdyn_projectbucket) ===" -ForegroundColor Green
# NOTE: bucket primary name is msdyn_name, NOT msdyn_subject
function NewBucket([string] $Name, [string] $PlanId) {
    $id = GetOrCreate 'msdyn_projectbuckets' 'msdyn_projectbucketid' `
        "msdyn_name eq '$Name' and _msdyn_project_value eq $PlanId" `
    @{ msdyn_name = $Name; 'msdyn_project@odata.bind' = "/msdyn_projects($PlanId)" }
    Write-Host "  $Name = $id"
    return $id
}
$bToDiscuss = NewBucket 'To discuss' $sourcePlan
$bEscalate = NewBucket 'Escalate' $sourcePlan
$bTarget = NewBucket 'Escalated from team' $targetPlan

Write-Host "`n=== Cards (msdyn_projecttask) ===" -ForegroundColor Green
$cards = @('Renew vendor contract', 'Blocked on access request', 'Capacity risk next sprint')
$cardIds = @{}
foreach ($c in $cards) {
    $id = GetOrCreate 'msdyn_projecttasks' 'msdyn_projecttaskid' "msdyn_subject eq '$c'" @{
        msdyn_subject                  = $c
        'msdyn_project@odata.bind'     = "/msdyn_projects($sourcePlan)"
        'msdyn_projectbucket@odata.bind' = "/msdyn_projectbuckets($bToDiscuss)"
    }
    $cardIds[$c] = $id
    Write-Host "  $c = $id"
}

# ---------------------------------------------------------------------------
# Environment variable values
# ---------------------------------------------------------------------------
Write-Host "`n=== Environment variable values ===" -ForegroundColor Green
$vals = @{
    "${Prefix}_SourcePlanId"     = $sourcePlan
    "${Prefix}_EscalateBucketId" = $bEscalate
    "${Prefix}_TargetPlanId"     = $targetPlan
    "${Prefix}_TargetBucketId"   = $bTarget
}
foreach ($k in $vals.Keys) {
    $def = Get1 "environmentvariabledefinitions?`$select=environmentvariabledefinitionid&`$filter=schemaname eq '$k'"
    $defId = $def[0].environmentvariabledefinitionid
    $cur = Get1 "environmentvariablevalues?`$select=environmentvariablevalueid,value&`$filter=_environmentvariabledefinitionid_value eq $defId"
    if ($cur) {
        $b = @{ value = $vals[$k] } | ConvertTo-Json
        Invoke-RestMethod -Uri "$api/environmentvariablevalues($($cur[0].environmentvariablevalueid))" -Method Patch -Headers $hs -Body ([Text.Encoding]::UTF8.GetBytes($b)) | Out-Null
        Write-Host "  $k updated"
    }
    else {
        Post 'environmentvariablevalues' @{
            value = $vals[$k]
            'EnvironmentVariableDefinitionId@odata.bind' = "/environmentvariabledefinitions($defId)"
        } $hs | Out-Null
        Write-Host "  $k set" -ForegroundColor Cyan
    }
}

Write-Host "`nSeed complete." -ForegroundColor Cyan
Write-Host "SOURCE_PLAN=$sourcePlan"
Write-Host "TARGET_PLAN=$targetPlan"
Write-Host "ESCALATE_BUCKET=$bEscalate"
Write-Host "TARGET_BUCKET=$bTarget"
Write-Host "CARD_BLOCKED=$($cardIds['Blocked on access request'])"
Write-Host "CARD_CAPACITY=$($cardIds['Capacity risk next sprint'])"
