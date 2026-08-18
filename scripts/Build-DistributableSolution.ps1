<#
  Build-DistributableSolution.ps1

  Builds a hand-over-ready solution for the Planner Premium "escalate a 1:1 card
  to my manager's 1:1" automation.

  Design goals:
    * The recipient configures it by typing PLAIN TEXT NAMES, not GUIDs.
    * Everything environment-specific is an environment variable, prompted at import.
    * No flow editing required, so a non-developer can set it up.

  Pipeline: ensure components -> export -> swap in the real definition -> repack.

  The definition swap is necessary because msdyn_projecttask rows can only be
  created through the Project Schedule API, and those actions are not present in
  every environment, so the flow cannot always be saved directly.

  Usage:
      .\Build-DistributableSolution.ps1 -OrgUrl https://orgXXXX.crm.dynamics.com
      .\Build-DistributableSolution.ps1 -OrgUrl https://orgXXXX.crm.dynamics.com -ImportTest
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $OrgUrl,
    [string] $Prefix = 'backers',
    [string] $PublisherUniqueName = 'Backers',
    [string] $SolutionName = 'PlannerPremiumEscalate',
    # Power Automate connection id for the Dataverse connection the flow runs as.
    # Find it in the URL when you open the connection in make.powerautomate.com.
    [Parameter(Mandatory = $true)]
    [string] $ConnectionId,
    [string] $WorkDir = "$PSScriptRoot\build",
    [string] $OutZip = "$PSScriptRoot\PlannerPremiumEscalate_2_0_0_0.zip",
    [switch] $ImportTest
)

$ErrorActionPreference = 'Stop'
$OrgUrl = $OrgUrl.TrimEnd('/')
$api = "$OrgUrl/api/data/v9.2"

$token = az account get-access-token --resource $OrgUrl --query accessToken -o tsv
if (-not $token) { throw 'Run: az login --allow-no-subscriptions' }

$hg = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
$hw = @{ Authorization = "Bearer $token"; Accept = 'application/json'; 'Content-Type' = 'application/json; charset=utf-8' }
$hs = $hw.Clone(); $hs['MSCRM.SolutionUniqueName'] = $SolutionName

function Get1([string] $Path) { (Invoke-RestMethod -Uri "$api/$Path" -Headers $hg).value }
function Post([string] $Path, $Body, $Headers) {
    $json = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 40))
    $r = Invoke-WebRequest -Uri "$api/$Path" -Method Post -Headers $Headers -Body $json -UseBasicParsing
    if ($r.Headers['OData-EntityId'] -match '\(([0-9a-fA-F-]{36})\)') { return $Matches[1] }
    return $null
}
function Lbl([string] $Text) {
    @{ '@odata.type' = 'Microsoft.Dynamics.CRM.Label'
       LocalizedLabels = @(@{ '@odata.type' = 'Microsoft.Dynamics.CRM.LocalizedLabel'; Label = $Text; LanguageCode = 1033 }) }
}

try { Invoke-RestMethod -Uri "$api/EntityDefinitions(LogicalName='msdyn_projecttask')?`$select=LogicalName" -Headers $hg | Out-Null }
catch { throw 'msdyn_projecttask not found - build against an environment that has Project for the web.' }

# ---------------------------------------------------------------------------
# Solution
# ---------------------------------------------------------------------------
Write-Host "`n=== Solution ===" -ForegroundColor Green
$sol = Get1 "solutions?`$select=solutionid&`$filter=uniquename eq '$SolutionName'"
if ($sol) { Write-Host '  exists' }
else {
    $pub = Get1 "publishers?`$select=publisherid&`$filter=uniquename eq '$PublisherUniqueName'"
    if (-not $pub) { throw "Publisher '$PublisherUniqueName' not found." }
    Post 'solutions' @{
        uniquename = $SolutionName; friendlyname = 'Planner Premium - Escalate to manager 1:1'
        version = '2.0.0.0'; 'publisherid@odata.bind' = "/publishers($($pub[0].publisherid))"
    } $hw | Out-Null
    Write-Host '  created' -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Dedupe column - stops repeated edits creating repeated copies
# ---------------------------------------------------------------------------
Write-Host "`n=== Dedupe column ===" -ForegroundColor Green
$col = "${Prefix}_escalatesourceid"
try {
    Invoke-RestMethod -Uri "$api/EntityDefinitions(LogicalName='msdyn_projecttask')/Attributes(LogicalName='$col')?`$select=LogicalName" -Headers $hg | Out-Null
    Write-Host '  exists'
}
catch {
    Post "EntityDefinitions(LogicalName='msdyn_projecttask')/Attributes" @{
        '@odata.type' = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
        SchemaName    = "${Prefix}_EscalateSourceId"
        DisplayName   = (Lbl 'Escalate Source Task Id')
        Description   = (Lbl 'Id of the originating card. Used by the escalation flow to avoid duplicates.')
        MaxLength     = 100; FormatName = @{ Value = 'Text' }; RequiredLevel = @{ Value = 'None' }
    } $hs | Out-Null
    Write-Host "  $col created" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Environment variables - PLAIN TEXT NAMES so a non-developer can fill them in
# ---------------------------------------------------------------------------
Write-Host "`n=== Environment variables ===" -ForegroundColor Green

# NOTE: the v1 GUID-based variables are retired *after* the flow is reset to a
# placeholder further down. Deleting them while a flow still references them
# fails with a dependency error.

$envVars = [ordered]@{
    "${Prefix}_SourcePlanName"     = @{ d = 'Watch this plan'; h = 'The exact name of the plan you keep your team 1:1 cards in. Example: 1:1s with my team' }
    "${Prefix}_EscalateBucketName" = @{ d = 'Escalate bucket'; h = 'The exact name of the bucket that means "raise this with my manager". Example: Escalate' }
    "${Prefix}_TargetPlanName"     = @{ d = 'Copy into this plan'; h = 'The exact name of your 1:1 plan with your manager. Example: 1:1 with my manager' }
    "${Prefix}_TargetBucketName"   = @{ d = 'Bucket for copies'; h = 'The exact name of the bucket in the manager plan where copies should land. Example: Escalated from team' }
}
foreach ($k in $envVars.Keys) {
    if (Get1 "environmentvariabledefinitions?`$select=schemaname&`$filter=schemaname eq '$k'") { Write-Host "  $k exists"; continue }
    Post 'environmentvariabledefinitions' @{
        schemaname = $k; displayname = $envVars[$k].d; description = $envVars[$k].h
        type = 100000000; isrequired = $true
    } $hs | Out-Null
    Write-Host "  $k created" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Connection reference
# ---------------------------------------------------------------------------
Write-Host "`n=== Connection reference ===" -ForegroundColor Green
$connRefName = "${Prefix}_dataverseescalate"
if (Get1 "connectionreferences?`$select=connectionreferencelogicalname&`$filter=connectionreferencelogicalname eq '$connRefName'") { Write-Host '  exists' }
else {
    Post 'connectionreferences' @{
        connectionreferencelogicalname = $connRefName
        connectionreferencedisplayname = 'Dataverse (Planner Premium)'
        connectorid  = '/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps'
        connectionid = $ConnectionId
    } $hs | Out-Null
    Write-Host '  created' -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Flow record - a minimal placeholder; the real definition is injected later
# ---------------------------------------------------------------------------
Write-Host "`n=== Flow record ===" -ForegroundColor Green
$flowName = 'Escalate 1-1 card to manager 1-1'

$placeholder = @{
    schemaVersion = '1.0.0.0'
    properties    = @{
        connectionReferences = @{ shared_commondataserviceforapps = @{
                runtimeSource = 'embedded'
                connection    = @{ connectionReferenceLogicalName = $connRefName }
                api           = @{ name = 'shared_commondataserviceforapps' } } }
        definition           = @{
            '$schema'      = 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
            contentVersion = '1.0.0.0'
            parameters     = @{ '$connections' = @{ defaultValue = @{}; type = 'Object' }; '$authentication' = @{ defaultValue = @{}; type = 'SecureObject' } }
            triggers       = @{ manual = @{ type = 'Request'; kind = 'Button'; inputs = @{} } }
            actions        = @{}
        }
    }
}
$placeholderJson = $placeholder | ConvertTo-Json -Depth 40 -Compress

$wf = Get1 "workflows?`$select=workflowid&`$filter=name eq '$flowName' and category eq 5"
if ($wf) {
    # Reset to the placeholder so it no longer references the v1 variables
    $flowId = $wf[0].workflowid
    $b = @{ clientdata = $placeholderJson } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Uri "$api/workflows($flowId)" -Method Patch -Headers $hs -Body ([Text.Encoding]::UTF8.GetBytes($b)) | Out-Null
    Write-Host '  reset to placeholder' -ForegroundColor Cyan
}
else {
    $flowId = Post 'workflows' @{
        name = $flowName; category = 5; type = 1; primaryentity = 'none'
        description = 'When a card in your team 1:1 plan is moved into the Escalate bucket, a matching card is created in your 1:1 with your manager.'
        statecode = 0; statuscode = 1
        clientdata = $placeholderJson
    } $hs
    Write-Host '  created' -ForegroundColor Cyan
}
Write-Host "  flowId = $flowId"

# Now that nothing references them, retire the v1 GUID-based variables
foreach ($old in 'SourcePlanId', 'EscalateBucketId', 'TargetPlanId', 'TargetBucketId') {
    $d = Get1 "environmentvariabledefinitions?`$select=environmentvariabledefinitionid&`$filter=schemaname eq '${Prefix}_$old'"
    if (-not $d) { continue }
    $vals = Get1 "environmentvariablevalues?`$select=environmentvariablevalueid&`$filter=_environmentvariabledefinitionid_value eq $($d[0].environmentvariabledefinitionid)"
    foreach ($v in $vals) { Invoke-RestMethod -Uri "$api/environmentvariablevalues($($v.environmentvariablevalueid))" -Method Delete -Headers $hg | Out-Null }
    try {
        Invoke-RestMethod -Uri "$api/environmentvariabledefinitions($($d[0].environmentvariabledefinitionid))" -Method Delete -Headers $hg | Out-Null
        Write-Host "  retired old ${Prefix}_$old" -ForegroundColor DarkYellow
    }
    catch { Write-Host "  could not retire ${Prefix}_$old (still referenced)" -ForegroundColor DarkYellow }
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
Write-Host "`n=== Export ===" -ForegroundColor Green
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$raw = Join-Path $WorkDir 'export.zip'
$body = @{ SolutionName = $SolutionName; Managed = $false } | ConvertTo-Json
$r = Invoke-RestMethod -Uri "$api/ExportSolution" -Method Post -Headers $hw -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 900
[IO.File]::WriteAllBytes($raw, [Convert]::FromBase64String($r.ExportSolutionFile))
Write-Host "  exported $((Get-Item $raw).Length) bytes" -ForegroundColor Cyan

$ex = Join-Path $WorkDir 'unpacked'
Remove-Item $ex -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -Path $raw -DestinationPath $ex

# ---------------------------------------------------------------------------
# Inject the real definition
# ---------------------------------------------------------------------------
Write-Host "`n=== Injecting flow definition ===" -ForegroundColor Green

function P([string] $Name) { "$Name ($Name)" }              # parameter key
function PRef([string] $Name) { "@parameters('$Name ($Name)')" }   # whole-value reference
function PIn([string] $Name) { "@{parameters('$Name ($Name)')}" }  # inside a string

$dvApi = '/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps'
function DvHost([string] $Op) { [ordered]@{ apiId = $dvApi; connectionName = 'shared_commondataserviceforapps'; operationId = $Op } }
function DvAction([string] $Op, $Params, $RunAfter) {
    $a = [ordered]@{ type = 'OpenApiConnection'; inputs = [ordered]@{
            authentication = "@parameters('`$authentication')"; host = (DvHost $Op); parameters = $Params } }
    if ($RunAfter) { $a.runAfter = $RunAfter }
    $a
}

$srcPlan = P "${Prefix}_SourcePlanName"
$escBkt  = P "${Prefix}_EscalateBucketName"
$tgtPlan = P "${Prefix}_TargetPlanName"
$tgtBkt  = P "${Prefix}_TargetBucketName"

# Ids resolved at run time from the names the recipient typed in
$tgtPlanId = "@{first(outputs('Find_the_target_plan')?['body/value'])?['msdyn_projectid']}"
$tgtBktId  = "@{first(outputs('Find_the_target_bucket')?['body/value'])?['msdyn_projectbucketid']}"

$entityJson = @"
{
  "@odata.type": "Microsoft.Dynamics.CRM.msdyn_projecttask",
  "msdyn_projecttaskid": "@{guid()}",
  "msdyn_subject": "@{triggerOutputs()?['body/msdyn_subject']}",
  "msdyn_project@odata.bind": "/msdyn_projects($tgtPlanId)",
  "msdyn_projectbucket@odata.bind": "/msdyn_projectbuckets($tgtBktId)",
  "${Prefix}_escalatesourceid": "@{triggerOutputs()?['body/msdyn_projecttaskid']}",
  "msdyn_start": "@{utcNow()}",
  "msdyn_scheduledstart": "@{utcNow()}",
  "msdyn_scheduledend": "@{addDays(utcNow(),5)}",
  "msdyn_LinkStatus": 192350000
}
"@

$createSteps = [ordered]@{
    'Create_operation_set'  = DvAction 'PerformUnboundAction' ([ordered]@{
            actionName = 'msdyn_CreateOperationSetV1'
            item = [ordered]@{ Description = 'Escalate 1:1 card to manager 1:1'; Project = $tgtPlanId } }) $null
    'Queue_the_new_card'    = DvAction 'PerformUnboundAction' ([ordered]@{
            actionName = 'msdyn_PssCreateV1'
            item = [ordered]@{ Entity = $entityJson; OperationSetId = "@outputs('Create_operation_set')?['body/OperationSetId']" } }) @{ 'Create_operation_set' = @('Succeeded') }
    'Execute_operation_set' = DvAction 'PerformUnboundAction' ([ordered]@{
            actionName = 'msdyn_ExecuteOperationSetV1'
            item = [ordered]@{ OperationSetId = "@outputs('Create_operation_set')?['body/OperationSetId']" } }) @{ 'Queue_the_new_card' = @('Succeeded') }
}

$definition = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
    contentVersion = '1.0.0.0'
    parameters     = [ordered]@{
        '$connections'   = @{ defaultValue = @{}; type = 'Object' }
        '$authentication' = @{ defaultValue = @{}; type = 'SecureObject' }
        $srcPlan = @{ defaultValue = ''; type = 'String'; metadata = @{ schemaName = "${Prefix}_SourcePlanName" } }
        $escBkt  = @{ defaultValue = ''; type = 'String'; metadata = @{ schemaName = "${Prefix}_EscalateBucketName" } }
        $tgtPlan = @{ defaultValue = ''; type = 'String'; metadata = @{ schemaName = "${Prefix}_TargetPlanName" } }
        $tgtBkt  = @{ defaultValue = ''; type = 'String'; metadata = @{ schemaName = "${Prefix}_TargetBucketName" } }
    }
    triggers       = [ordered]@{
        'When_a_card_changes' = [ordered]@{
            type   = 'OpenApiConnectionWebhook'
            inputs = [ordered]@{
                authentication = "@parameters('`$authentication')"
                host           = (DvHost 'SubscribeWebhookTrigger')
                parameters     = [ordered]@{
                    'subscriptionRequest/entityname'          = 'msdyn_projecttask'
                    'subscriptionRequest/scope'               = 4
                    'subscriptionRequest/message'             = 4
                    'subscriptionRequest/filteringattributes' = 'msdyn_subject,msdyn_projectbucket'
                }
            }
        }
    }
    actions        = [ordered]@{
        'Is_this_an_escalated_card' = [ordered]@{
            type       = 'If'
            runAfter   = @{}
            # Compares the friendly names carried on the changed row, so no GUIDs
            # and no extra lookups are needed just to decide whether to act.
            expression = @{ and = @(
                    @{ equals = @("@triggerOutputs()?['body/msdyn_projectname']", (PRef "${Prefix}_SourcePlanName")) },
                    @{ equals = @("@triggerOutputs()?['body/msdyn_projectbucketname']", (PRef "${Prefix}_EscalateBucketName")) }
                ) }
            actions    = [ordered]@{
                'Look_for_an_existing_copy' = DvAction 'ListRecords' ([ordered]@{
                        entityName = 'msdyn_projecttasks'
                        '$select'  = 'msdyn_projecttaskid'
                        '$top'     = 1
                        '$filter'  = "${Prefix}_escalatesourceid eq '@{triggerOutputs()?['body/msdyn_projecttaskid']}'"
                    }) $null
                'Only_if_there_is_no_copy_yet' = [ordered]@{
                    type       = 'If'
                    runAfter   = @{ 'Look_for_an_existing_copy' = @('Succeeded') }
                    expression = @{ equals = @("@length(outputs('Look_for_an_existing_copy')?['body/value'])", 0) }
                    actions    = [ordered]@{
                        'Find_the_target_plan'   = DvAction 'ListRecords' ([ordered]@{
                                entityName = 'msdyn_projects'
                                '$select'  = 'msdyn_projectid'
                                '$top'     = 1
                                '$filter'  = "msdyn_subject eq '$(PIn "${Prefix}_TargetPlanName")'"
                            }) $null
                        'Find_the_target_bucket' = DvAction 'ListRecords' ([ordered]@{
                                entityName = 'msdyn_projectbuckets'
                                '$select'  = 'msdyn_projectbucketid'
                                '$top'     = 1
                                '$filter'  = "msdyn_name eq '$(PIn "${Prefix}_TargetBucketName")' and _msdyn_project_value eq $tgtPlanId"
                            }) @{ 'Find_the_target_plan' = @('Succeeded') }
                        'Check_the_names_matched' = [ordered]@{
                            type       = 'If'
                            runAfter   = @{ 'Find_the_target_bucket' = @('Succeeded') }
                            expression = @{ and = @(
                                    @{ greater = @("@length(outputs('Find_the_target_plan')?['body/value'])", 0) },
                                    @{ greater = @("@length(outputs('Find_the_target_bucket')?['body/value'])", 0) }
                                ) }
                            actions    = $createSteps
                            # A wrong name is the most likely setup mistake, so fail
                            # loudly with an instruction rather than silently doing nothing.
                            else       = @{ actions = [ordered]@{
                                    'Stop_and_explain' = [ordered]@{
                                        type     = 'Terminate'
                                        runAfter = @{}
                                        inputs   = @{ runStatus = 'Failed'; runError = @{
                                                code    = 'SetupNameNotFound'
                                                message = "Could not find a plan called '$(PIn "${Prefix}_TargetPlanName")' with a bucket called '$(PIn "${Prefix}_TargetBucketName")'. Open Solutions > Planner Premium - Escalate to manager 1:1 and check the four name settings match your plans and buckets exactly, including capitals and spacing."
                                            } }
                                    } } }
                        }
                    }
                    else       = @{ actions = @{} }
                }
            }
            else       = @{ actions = @{} }
        }
    }
}

$wfFile = Get-ChildItem (Join-Path $ex 'Workflows') -Filter *.json | Select-Object -First 1
$flow = Get-Content $wfFile.FullName -Raw | ConvertFrom-Json
$flow.properties.definition = $definition

# Must be BOM-free. Set-Content -Encoding UTF8 writes a BOM, which makes import
# fail with "Flow clientdata is in invalid format ... Unexpected character".
[IO.File]::WriteAllText($wfFile.FullName, ($flow | ConvertTo-Json -Depth 60), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  definition written to $($wfFile.Name)" -ForegroundColor Cyan

Get-ChildItem (Join-Path $ex 'environmentvariabledefinitions') -Recurse -Filter environmentvariablevalues.json |
    ForEach-Object { Remove-Item $_.FullName -Force; Write-Host "  cleared build value for $($_.Directory.Name)" -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
# Repack
# ---------------------------------------------------------------------------
Write-Host "`n=== Repack ===" -ForegroundColor Green
if (Test-Path $OutZip) { Remove-Item $OutZip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
# CreateFromDirectory writes backslash separators on .NET Framework, which is
# invalid per the ZIP spec, so entries are added by hand with forward slashes.
$zipOut = [IO.Compression.ZipFile]::Open($OutZip, [IO.Compression.ZipArchiveMode]::Create)
try {
    $root = (Resolve-Path $ex).Path.TrimEnd('\')
    Get-ChildItem -Path $root -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
        $entry = $zipOut.CreateEntry($rel, [IO.Compression.CompressionLevel]::Optimal)
        $s = $entry.Open(); $bytes = [IO.File]::ReadAllBytes($_.FullName)
        $s.Write($bytes, 0, $bytes.Length); $s.Close()
    }
}
finally { $zipOut.Dispose() }
Write-Host "  $OutZip ($((Get-Item $OutZip).Length) bytes)" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
Write-Host "`n=== Verify ===" -ForegroundColor Green
$zip = [IO.Compression.ZipFile]::OpenRead($OutZip)
$ok = $true
try {
    foreach ($req in 'solution.xml', 'customizations.xml', '[Content_Types].xml') {
        if ($zip.Entries.FullName -contains $req) { Write-Host "  OK   $req" -ForegroundColor Cyan }
        else { Write-Host "  FAIL $req missing" -ForegroundColor Red; $ok = $false }
    }
    foreach ($e in $zip.Entries) {
        if ($e.FullName -like '*\*') { Write-Host "  FAIL backslash entry $($e.FullName)" -ForegroundColor Red; $ok = $false }
        if ($e.FullName -like '*environmentvariablevalues.json') { Write-Host '  FAIL build value leaked' -ForegroundColor Red; $ok = $false }
        # A BOM anywhere except Microsoft's own [Content_Types].xml breaks import
        if ($e.FullName -ne '[Content_Types].xml') {
            $st = $e.Open(); $b = New-Object byte[] 3; $n = $st.Read($b, 0, 3); $st.Close()
            if ($n -eq 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
                Write-Host "  FAIL BOM in $($e.FullName)" -ForegroundColor Red; $ok = $false }
        }
    }
    $we = $zip.Entries | Where-Object { $_.FullName -like 'Workflows/*.json' }
    if (-not $we) { Write-Host '  FAIL no workflow' -ForegroundColor Red; $ok = $false }
    else {
        $sr = New-Object IO.StreamReader($we.Open()); $txt = $sr.ReadToEnd(); $sr.Close()
        $p = $txt | ConvertFrom-Json
        $steps = $p.properties.definition.actions.Is_this_an_escalated_card.actions.Only_if_there_is_no_copy_yet.actions.Check_the_names_matched.actions.PSObject.Properties.Name
        Write-Host "  OK   workflow parses; create path = $($steps -join ' -> ')" -ForegroundColor Cyan
        if ($txt -match '"operationId":\s*"CreateRecord"') { Write-Host '  FAIL uses blocked CreateRecord' -ForegroundColor Red; $ok = $false }
        else { Write-Host '  OK   no direct CreateRecord' -ForegroundColor Cyan }
        $pc = ($p.properties.definition.parameters.PSObject.Properties.Name | Where-Object { $_ -notlike '$*' }).Count
        Write-Host "  OK   $pc configurable name settings" -ForegroundColor Cyan
    }
}
finally { $zip.Dispose() }
if (-not $ok) { throw 'Verification failed.' }

# ---------------------------------------------------------------------------
# Optional import test
# ---------------------------------------------------------------------------
if ($ImportTest) {
    Write-Host "`n=== Import test ===" -ForegroundColor Green
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($OutZip))
    $ib = @{ OverwriteUnmanagedCustomizations = $true; PublishWorkflows = $false
             CustomizationFile = $b64; ImportJobId = [guid]::NewGuid().ToString() } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri "$api/ImportSolution" -Method Post -Headers $hw -Body ([Text.Encoding]::UTF8.GetBytes($ib)) -TimeoutSec 1800 | Out-Null
        Write-Host '  IMPORT SUCCEEDED' -ForegroundColor Green
    }
    catch {
        Write-Host '  IMPORT FAILED' -ForegroundColor Red
        Start-Sleep 10
        $j = (Get1 "importjobs?`$select=progress,data&`$orderby=createdon desc&`$top=1")
        Write-Host "  progress=$($j.progress)"
        [regex]::Matches($j.data, 'errortext="[^"]{5,400}"') | Select-Object -First 5 | ForEach-Object { Write-Host "  $($_.Value)" -ForegroundColor Red }
        throw
    }
}

Write-Host "`nDone." -ForegroundColor Cyan
