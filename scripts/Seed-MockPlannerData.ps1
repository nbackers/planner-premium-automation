<#
  Seed-MockPlannerData.ps1

  Populates the mock Planner Premium tables with a two-plan escalation scenario:

    Plan  "Team backlog"             (SOURCE)
      Bucket "To discuss"
      Bucket "Escalate"              <- dragging a card here triggers the flow
      Bucket "Done"
    Plan  "Escalations"              (TARGET)
      Bucket "Escalated from team"

  Prints the GUIDs the flow needs. Idempotent: safe to re-run.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $OrgUrl,
    [string] $Prefix = 'nbp'
)

$ErrorActionPreference = 'Stop'
$OrgUrl = $OrgUrl.TrimEnd('/')
$api = "$OrgUrl/api/data/v9.2"

$token = az account get-access-token --resource $OrgUrl --query accessToken -o tsv
$headers = @{
    Authorization      = "Bearer $token"
    Accept             = 'application/json'
    'OData-Version'    = '4.0'
    'OData-MaxVersion' = '4.0'
}
# Content-Type must only be sent on requests that actually have a body -
# sending it on a GET makes IIS return a generic ASP.NET runtime error page.
$writeHeaders = $headers.Clone()
$writeHeaders['Content-Type'] = 'application/json; charset=utf-8'

$planSet = "${Prefix}_mockplans"
$bucketSet = "${Prefix}_mockbuckets"
$taskSet = "${Prefix}_mocktasks"
$subject = "${Prefix}_subject"

function Get-OrCreate {
    param([string] $EntitySet, [string] $IdField, [string] $Filter, [hashtable] $Body)

    # Spaces / colons in filter values must be encoded or IIS rejects the request    # NOTE: ${EntitySet} must be brace-delimited - "$EntitySet?" makes PowerShell
    # parse "EntitySet?" as the variable name, silently dropping the table and the '?'.
    $q = "$api/${EntitySet}?`$select=$IdField&`$filter=" + [uri]::EscapeDataString($Filter)

    $found = (Invoke-RestMethod -Uri $q -Headers $headers).value
    if ($found) { return $found[0].$IdField }

    $json = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10))
    $resp = Invoke-WebRequest -Uri "$api/$EntitySet" -Method Post -Headers $writeHeaders -Body $json -UseBasicParsing
    # Dataverse returns the new row's URI in the OData-EntityId header
    if ($resp.Headers['OData-EntityId'] -match '\(([0-9a-fA-F-]{36})\)') { return $Matches[1] }

    (Invoke-RestMethod -Uri $q -Headers $headers).value[0].$IdField
}

Write-Host "`n=== Plans ===" -ForegroundColor Green

$sourcePlanId = Get-OrCreate -EntitySet $planSet -IdField "${Prefix}_mockplanid" `
    -Filter "$subject eq 'Team backlog'" -Body @{ $subject = 'Team backlog' }
Write-Host "  SOURCE_PLAN_ID = $sourcePlanId"

$targetPlanId = Get-OrCreate -EntitySet $planSet -IdField "${Prefix}_mockplanid" `
    -Filter "$subject eq 'Escalations'" -Body @{ $subject = 'Escalations' }
Write-Host "  TARGET_PLAN_ID = $targetPlanId"

Write-Host "`n=== Buckets ===" -ForegroundColor Green

function New-Bucket([string] $Name, [string] $PlanId) {
    $id = Get-OrCreate -EntitySet $bucketSet -IdField "${Prefix}_mockbucketid" `
        -Filter "$subject eq '$Name' and _${Prefix}_plan_value eq $PlanId" `
        -Body @{ $subject = $Name; "${Prefix}_Plan@odata.bind" = "/$planSet($PlanId)" }
    Write-Host "  $Name = $id"
    return $id
}

$bucketToDiscuss = New-Bucket 'To discuss' $sourcePlanId
$bucketEscalate = New-Bucket 'Escalate' $sourcePlanId
$null = New-Bucket 'Done' $sourcePlanId
$bucketTarget = New-Bucket 'Escalated from team' $targetPlanId

Write-Host "`n=== Cards in source plan ===" -ForegroundColor Green

$cards = @(
    'Renew vendor contract',
    'Blocked on access request',
    'Capacity risk next sprint'
)
foreach ($c in $cards) {
    $id = Get-OrCreate -EntitySet $taskSet -IdField "${Prefix}_mocktaskid" `
        -Filter "$subject eq '$c'" `
        -Body @{
        $subject                   = $c
        "${Prefix}_Plan@odata.bind"   = "/$planSet($sourcePlanId)"
        "${Prefix}_Bucket@odata.bind" = "/$bucketSet($bucketToDiscuss)"
        "${Prefix}_escalate"          = $false
    }
    Write-Host "  $c = $id"
}

Write-Host @"

=== Copy these into the flow ===
  SOURCE_PLAN_ID      $sourcePlanId
  TARGET_PLAN_ID      $targetPlanId
  ESCALATE_BUCKET_ID  $bucketEscalate
  TARGET_BUCKET_ID    $bucketTarget

To test: move a card into the Escalate bucket, e.g.

  PATCH $api/$taskSet(<taskId>)
  { "${Prefix}_Bucket@odata.bind": "/$bucketSet($bucketEscalate)" }
"@ -ForegroundColor Cyan
