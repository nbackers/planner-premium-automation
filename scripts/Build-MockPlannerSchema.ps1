<#
  Build-MockPlannerSchema.ps1

  Creates mock tables in a Dataverse environment that mirror the Planner Premium
  (Project for the web) schema, so the escalation flow's logic can be built and
  tested where Project for the web is not / cannot be installed.

  Real table        -> Mock table
    msdyn_project     -> cra89_mockplan
    msdyn_projectbucket -> cra89_mockbucket
    msdyn_projecttask -> cra89_mocktask

  Column names deliberately mirror the real ones (subject / plan / bucket lookups)
  so the flow definition maps across with a find-and-replace.

  Idempotent: safe to re-run.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $OrgUrl,
    [string] $Prefix = 'cra89',
    [string] $SolutionName = 'PlannerEscalatePrototype',
    [string] $PublisherUniqueName = 'Cr96dd3'
)

$ErrorActionPreference = 'Stop'
$OrgUrl = $OrgUrl.TrimEnd('/')
$api = "$OrgUrl/api/data/v9.2"

$token = az account get-access-token --resource $OrgUrl --query accessToken -o tsv
if (-not $token) { throw 'Could not acquire token. Run: az login --allow-no-subscriptions' }

$script:Headers = @{
    Authorization           = "Bearer $token"
    Accept                  = 'application/json'
    'OData-Version'         = '4.0'
    'OData-MaxVersion'      = '4.0'
    'Content-Type'          = 'application/json; charset=utf-8'
    'MSCRM.SolutionUniqueName' = $SolutionName
}

function Invoke-Dv {
    param(
        [string] $Method,
        [string] $Path,
        $Body,
        [switch] $NoSolutionHeader
    )
    $h = $script:Headers.Clone()
    if ($NoSolutionHeader) { $h.Remove('MSCRM.SolutionUniqueName') }

    $args = @{ Uri = "$api/$Path"; Method = $Method; Headers = $h }
    if ($null -ne $Body) {
        $args.Body = ([System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20)))
    }
    Invoke-RestMethod @args
}

function New-Label([string] $Text) {
    @{
        '@odata.type'    = 'Microsoft.Dynamics.CRM.Label'
        LocalizedLabels = @(@{
                '@odata.type' = 'Microsoft.Dynamics.CRM.LocalizedLabel'
                Label         = $Text
                LanguageCode  = 1033
            })
    }
}

function Test-EntityExists([string] $LogicalName) {
    try {
        Invoke-Dv GET "EntityDefinitions(LogicalName='$LogicalName')?`$select=LogicalName" -NoSolutionHeader | Out-Null
        return $true
    }
    catch { return $false }
}

# ---------------------------------------------------------------------------
# Solution
# ---------------------------------------------------------------------------
Write-Host "`n=== Solution: $SolutionName ===" -ForegroundColor Green

$existing = (Invoke-Dv GET "solutions?`$select=uniquename&`$filter=uniquename eq '$SolutionName'" -NoSolutionHeader).value
if ($existing) {
    Write-Host "  exists"
}
else {
    $pub = (Invoke-Dv GET "publishers?`$select=publisherid,customizationprefix&`$filter=uniquename eq '$PublisherUniqueName'" -NoSolutionHeader).value

    if (-not $pub) {
        # Fall back to any publisher already using the requested prefix
        $pub = (Invoke-Dv GET "publishers?`$select=publisherid,customizationprefix&`$filter=customizationprefix eq '$Prefix'" -NoSolutionHeader).value
    }
    if (-not $pub) {
        Write-Host "  creating publisher (prefix '$Prefix')" -ForegroundColor Cyan
        Invoke-Dv POST 'publishers' @{
            uniquename          = "PlannerProtoPub$Prefix"
            friendlyname        = 'Planner Prototype Publisher'
            customizationprefix = $Prefix
        } -NoSolutionHeader | Out-Null

        # POST returns 204 with no body, so re-query for the id
        $pub = (Invoke-Dv GET "publishers?`$select=publisherid&`$filter=uniquename eq 'PlannerProtoPub$Prefix'" -NoSolutionHeader).value
        if (-not $pub) { throw "Publisher was created but could not be read back." }
    }

    Invoke-Dv POST 'solutions' @{
        uniquename            = $SolutionName
        friendlyname          = 'Planner Escalate Prototype'
        version               = '1.0.0.0'
        'publisherid@odata.bind' = "/publishers($($pub[0].publisherid))"
    } -NoSolutionHeader | Out-Null
    Write-Host "  created" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------
$tables = @(
    @{ Schema = "${Prefix}_MockPlan"; Logical = "${Prefix}_mockplan"; Display = 'Mock Plan'; Plural = 'Mock Plans' }
    @{ Schema = "${Prefix}_MockBucket"; Logical = "${Prefix}_mockbucket"; Display = 'Mock Bucket'; Plural = 'Mock Buckets' }
    @{ Schema = "${Prefix}_MockTask"; Logical = "${Prefix}_mocktask"; Display = 'Mock Task'; Plural = 'Mock Tasks' }
)

foreach ($t in $tables) {
    Write-Host "`n=== Table: $($t.Logical) ===" -ForegroundColor Green
    if (Test-EntityExists $t.Logical) { Write-Host '  exists'; continue }

    $body = @{
        '@odata.type'         = 'Microsoft.Dynamics.CRM.EntityMetadata'
        SchemaName            = $t.Schema
        DisplayName           = New-Label $t.Display
        DisplayCollectionName = New-Label $t.Plural
        OwnershipType         = 'UserOwned'
        HasActivities         = $false
        HasNotes              = $false
        IsActivity            = $false
        Attributes            = @(
            @{
                '@odata.type'  = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
                SchemaName     = "${Prefix}_Subject"
                DisplayName    = New-Label 'Subject'
                IsPrimaryName  = $true
                MaxLength      = 250
                FormatName     = @{ Value = 'Text' }
                RequiredLevel  = @{ Value = 'ApplicationRequired' }
            }
        )
    }
    Invoke-Dv POST 'EntityDefinitions' $body | Out-Null
    Write-Host '  created' -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Extra columns on Mock Task
# ---------------------------------------------------------------------------
function Test-AttrExists([string] $Entity, [string] $Attr) {
    try {
        Invoke-Dv GET "EntityDefinitions(LogicalName='$Entity')/Attributes(LogicalName='$Attr')?`$select=LogicalName" -NoSolutionHeader | Out-Null
        return $true
    }
    catch { return $false }
}

Write-Host "`n=== Columns on ${Prefix}_mocktask ===" -ForegroundColor Green

$cols = @(
    @{
        Logical = "${Prefix}_description"
        Body    = @{
            '@odata.type' = 'Microsoft.Dynamics.CRM.MemoAttributeMetadata'
            SchemaName    = "${Prefix}_Description"
            DisplayName   = New-Label 'Description'
            MaxLength     = 2000
            FormatName    = @{ Value = 'TextArea' }
            RequiredLevel = @{ Value = 'None' }
        }
    },
    @{
        # The dedupe key - mirrors the cr123_sourcetaskid recommendation in the guide
        Logical = "${Prefix}_sourcetaskid"
        Body    = @{
            '@odata.type' = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
            SchemaName    = "${Prefix}_SourceTaskId"
            DisplayName   = New-Label 'Source Task Id'
            MaxLength     = 100
            FormatName    = @{ Value = 'Text' }
            RequiredLevel = @{ Value = 'None' }
        }
    },
    @{
        # Option B from the guide - the explicit escalate flag
        Logical = "${Prefix}_escalate"
        Body    = @{
            '@odata.type' = 'Microsoft.Dynamics.CRM.BooleanAttributeMetadata'
            SchemaName    = "${Prefix}_Escalate"
            DisplayName   = New-Label 'Escalate'
            RequiredLevel = @{ Value = 'None' }
            DefaultValue  = $false
            OptionSet     = @{
                '@odata.type' = 'Microsoft.Dynamics.CRM.BooleanOptionSetMetadata'
                TrueOption    = @{ Value = 1; Label = (New-Label 'Yes') }
                FalseOption   = @{ Value = 0; Label = (New-Label 'No') }
            }
        }
    }
)

foreach ($c in $cols) {
    if (Test-AttrExists "${Prefix}_mocktask" $c.Logical) { Write-Host "  $($c.Logical) exists"; continue }
    Invoke-Dv POST "EntityDefinitions(LogicalName='${Prefix}_mocktask')/Attributes" $c.Body | Out-Null
    Write-Host "  $($c.Logical) created" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------
Write-Host "`n=== Lookups ===" -ForegroundColor Green

function New-Lookup {
    param(
        [string] $SchemaName,
        [string] $FromEntity,
        [string] $ToEntity,
        [string] $LookupSchema,
        [string] $LookupDisplay
    )
    $existingRel = (Invoke-Dv GET "RelationshipDefinitions?`$select=SchemaName&`$filter=SchemaName eq '$SchemaName'" -NoSolutionHeader).value
    if ($existingRel) { Write-Host "  $SchemaName exists"; return }

    $body = @{
        '@odata.type'          = 'Microsoft.Dynamics.CRM.OneToManyRelationshipMetadata'
        SchemaName             = $SchemaName
        ReferencedEntity       = $ToEntity
        ReferencingEntity      = $FromEntity
        CascadeConfiguration   = @{
            Assign = 'NoCascade'; Delete = 'RemoveLink'; Merge = 'NoCascade'
            Reparent = 'NoCascade'; Share = 'NoCascade'; Unshare = 'NoCascade'
        }
        Lookup                 = @{
            '@odata.type' = 'Microsoft.Dynamics.CRM.LookupAttributeMetadata'
            SchemaName    = $LookupSchema
            DisplayName   = New-Label $LookupDisplay
            RequiredLevel = @{ Value = 'None' }
        }
        AssociatedMenuConfiguration = @{
            Behavior = 'UseCollectionName'; Group = 'Details'; Order = 10000
        }
    }
    Invoke-Dv POST 'RelationshipDefinitions' $body | Out-Null
    Write-Host "  $SchemaName created" -ForegroundColor Cyan
}

New-Lookup -SchemaName "${Prefix}_mockplan_mockbucket" -FromEntity "${Prefix}_mockbucket" `
    -ToEntity "${Prefix}_mockplan" -LookupSchema "${Prefix}_Plan" -LookupDisplay 'Plan'

New-Lookup -SchemaName "${Prefix}_mockplan_mocktask" -FromEntity "${Prefix}_mocktask" `
    -ToEntity "${Prefix}_mockplan" -LookupSchema "${Prefix}_Plan" -LookupDisplay 'Plan'

New-Lookup -SchemaName "${Prefix}_mockbucket_mocktask" -FromEntity "${Prefix}_mocktask" `
    -ToEntity "${Prefix}_mockbucket" -LookupSchema "${Prefix}_Bucket" -LookupDisplay 'Bucket'

Write-Host "`nSchema build complete." -ForegroundColor Cyan
