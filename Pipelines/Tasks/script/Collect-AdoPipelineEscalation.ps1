<#
.SYNOPSIS
    Collect escalation data for Azure DevOps pipelines via REST APIs.
#>

[CmdletBinding()]
param(
    [string]$Org,
    [string]$Project,
    [string]$PipelineIds,
    [string]$OutputDir
)

###────────────────────
# 1) LOGGING SETUP
###────────────────────
# Always place reports next to this script, not in your current folder.
$scriptDir = $PSScriptRoot
$ts = Get-Date -Format 'yyyyMMdd-HHmm'

if (-not $OutputDir)
{
    $OutputDir = Join-Path $scriptDir "reports\AdoPipelineEscalation_Output_$ts"
}

if (-not (Test-Path $OutputDir))
{
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$Global:LogFile = Join-Path $OutputDir "CollectionLog_$ts.txt"


function Write-Log
{
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$time [$Level] $Message"
    Write-Host $line
    Add-Content -Path $Global:LogFile -Value $line
}

Write-Log '=== Starting pipeline escalation collection ==='

###────────────────────
# 2) HELPER FUNCTIONS
###────────────────────
function Get-AccessToken
{
    Write-Log 'Requesting Azure DevOps AAD token...'
    try
    {
        $resId = '499b84ac-1321-427f-aa17-267ca6975798'
        $tok = az account get-access-token --resource $resId --output json |
        ConvertFrom-Json
        Write-Log 'Token acquired.'
        return $tok.accessToken
    }
    catch
    {
        Write-Log "Failed to get token: $_" 'ERROR'
        return $null
    }
}

function Download-AdoArtifact
{
    param(
        [string]  $Uri,
        [hashtable]$Headers,
        [string]  $OutFile,
        [string]  $Desc = 'artifact'
    )
    Write-Log "Downloading $Desc from $Uri"
    try
    {
        Invoke-WebRequest -Uri $Uri -Headers $Headers -OutFile $OutFile -ErrorAction Stop
        Write-Log "Saved $Desc → $OutFile"
        return $true
    }
    catch
    {
        Write-Log "Error downloading $Desc $_" 'ERROR'
        return $false
    }
}

###────────────────────
# 3) AUTHENTICATE
###────────────────────
# 3a) Azure CLI login
Write-Log 'Verifying Azure CLI login...'
try
{
    Write-Log 'Ensuring you are signed in to Azure…'
    az login --use-device-code --only-show-errors
    if ($LASTEXITCODE -ne 0)
    {
        Write-Log 'Interactive login failed.' 'ERROR'
        exit 1
    }
    $account = az account show --output json | ConvertFrom-Json
    Write-Log "Azure CLI logged in: $($account.name) ($($account.id))"
}
catch
{
    Write-Log 'az login required.' 'ERROR'
    exit 1
}

# 3b) ADO AAD token for REST
$AdoToken = Get-AccessToken
if (-not $AdoToken)
{
    Write-Log 'Cannot proceed without ADO token.' 'FATAL'
    exit 1
}
$Headers = @{ Authorization = "Bearer $AdoToken" }
$ApiVersion = '7.0'

###────────────────────
# 4) COLLECT PARAMETERS
###────────────────────
# Org
if (-not $Org)
{
    $Org = Read-Host 'Enter ADO Org URL (e.g. https://dev.azure.com/Contoso)'
}
if ($Org -notmatch '^https://')
{
    Write-Log 'Invalid Org URL.' 'ERROR'; exit 1
}
$Org = $Org.TrimEnd('/')
$orgName = ($Org -split '/')[ -1 ]
Write-Log "Using Org: $Org"

# Project (optional; list & select when not provided)
if (-not $Project)
{
    Write-Log 'Retrieving list of projects via REST...'
    $resp = Invoke-RestMethod `
        -Uri "https://dev.azure.com/$orgName/_apis/projects?stateFilter=all&api-version=$ApiVersion" `
        -Headers $Headers -Method Get
    $projects = $resp.value | Sort-Object name
    if ($projects.Count -eq 0)
    {
        Write-Log 'No projects found.' 'ERROR'; exit 1
    }
    for ($i = 0; $i -lt $projects.Count; $i++)
    {
        Write-Host "[$($i+1)] $($projects[$i].name)"
    }
    do
    {
        $choice = Read-Host 'Enter the number for the project'
    } until ($choice -match '^[0-9]+$' -and ([int]$choice -ge 1 -and [int]$choice -le $projects.Count))
    $Project = $projects[[int]$choice - 1].name
}
Write-Log "Using Project: $Project"

###────────────────────
# 4.1) Set DevOps CLI defaults
###────────────────────
Write-Log 'Configuring Azure DevOps defaults'
az devops configure --defaults organization=$Org project=$Project --only-show-errors

# Project
if (-not $Project)
{
    Write-Log 'Listing projects via REST...'
    $resp = Invoke-RestMethod `
        -Uri "https://dev.azure.com/$orgName/_apis/projects?api-version=$ApiVersion" `
        -Headers $Headers
    $projects = $resp.value | Sort-Object name
    if ($projects.Count -eq 0)
    {
        Write-Log 'No projects found.' 'ERROR'; exit 1
    }
    for ($i = 0; $i -lt $projects.Count; $i++)
    {
        Write-Host "[$($i+1)] $($projects[$i].name)"
    }
    $sel = Read-Host 'Select project number'
    $Project = $projects[ ([int]$sel - 1) ].name
}
Write-Log "Selected Project: $Project"

# Pipeline IDs
if (-not $PipelineIds)
{
    Write-Log 'Listing pipelines via REST...'

    # 1) Fetch YAML pipelines, tag type
    $yamlResp = Invoke-RestMethod `
        -Uri "https://dev.azure.com/$orgName/$Project/_apis/pipelines?api-version=$ApiVersion" `
        -Headers $Headers -Method Get
    $yamlList = $yamlResp.value | ForEach-Object {
        $_ | Add-Member -NotePropertyName PipelineType -NotePropertyValue 'YAML' -PassThru
    }

    # 2) Fetch Classic build definitions, tag type
    $buildResp = Invoke-RestMethod `
        -Uri "https://dev.azure.com/$orgName/$Project/_apis/build/definitions?api-version=$ApiVersion" `
        -Headers $Headers -Method Get
    $buildList = $buildResp.value | ForEach-Object {
        $_ | Add-Member -NotePropertyName PipelineType -NotePropertyValue 'Classic' -PassThru
    }

    # 3) Combine + dedupe by ID
    $combined = $yamlList + $buildList
    $unique = $combined | Sort-Object id -Unique

    # 4) Annotate with last run result and display
    for ($i = 0; $i -lt $unique.Count; $i++)
    {
        $p = $unique[$i]

        if ($p.PipelineType -eq 'YAML')
        {
            $runsUrl = "https://dev.azure.com/$orgName/$Project/_apis/pipelines/$($p.id)/runs?api-version=$ApiVersion&`$top=1"
        }
        else
        {
            $runsUrl = "https://dev.azure.com/$orgName/$Project/_apis/build/builds?definitions=$($p.id)&api-version=$ApiVersion&`$top=1"
        }

        # Get most recent run
        $runsResp = Invoke-RestMethod -Uri $runsUrl -Headers $Headers -Method Get -ErrorAction SilentlyContinue
        $lastRun = if ($runsResp.value)
        {
            $runsResp.value[0] 
        }
        else
        {
            $null 
        }
        $status = if ($lastRun)
        {
            $lastRun.result 
        }
        else
        {
            'None' 
        }

        Write-Host ('[{0}] ID:{1}  Name:{2}  Type:{3}  LastResult:{4}' -f `
            ($i + 1), $p.id, $p.name, $p.PipelineType, $status)
    }

    # 5) Prompt for choice
    $sel = Read-Host 'Select pipeline number(s) (e.g. 1,3)'
    $PipelineIds = ($sel -split ',') | ForEach-Object {
        $idx = [int]$_.Trim() - 1
        if ($idx -ge 0 -and $idx -lt $unique.Count)
        {
            $unique[$idx].id
        }
    }
}
Write-Log "Pipeline IDs to process: $($PipelineIds -join ', ')"


###────────────────────
# 5) PROCESS EACH PIPELINE
###────────────────────
# Prepare report object
$Report = @{
    CollectedOn  = (Get-Date).ToString('o')
    Organization = $Org
    Project      = $Project
    Pipelines    = @()
    Artifacts    = @()
}

foreach ($pipelineId in $PipelineIds)
{
    
    $pipeUrl = 'https://dev.azure.com/{0}/{1}/_apis/pipelines/{2}?api-version={3}' -f `
        $orgName, $Project, $pipelineId, $ApiVersion
    
    Write-Log "→ Processing Pipeline ID: $pipelineId and URL: $pipeUrl"

    # Create the pipeline-specific folder
    $pipelineFolder = Join-Path $OutputDir "Pipeline_$pipelineId"
    if (-not (Test-Path $pipelineFolder))
    {
        New-Item -ItemType Directory -Path $pipelineFolder -Force | Out-Null
    }


    $pipeInfo = Invoke-RestMethod -Uri $pipeUrl -Headers $Headers
    $pName = $pipeInfo.name
    $pLink = $pipeInfo._links.web.href
    Write-Log "Name: $pName; Link: $pLink"

    # Definition download
    if ($pipeInfo.configuration.type -eq 'yaml')
    {
        $defType = 'YAML'
        $path = $pipeInfo.configuration.path.TrimStart('/')
        $repoId = $pipeInfo.configuration.repository.id
        $url = "https://dev.azure.com/$orgName/$Project/_apis/git/repositories/$repoId/items?path=$([uri]::EscapeDataString($path))&api-version=$ApiVersion&download=true"
        $outFile = Join-Path $OutputDir "$pid-$($path -replace '/','_')"
        Download-AdoArtifact -Uri $url -Headers $Headers -OutFile $outFile -Desc 'YAML definition'
        $defFile = $outFile
    }
    else
    {
        $defType = 'Classic'
        $outFile = Join-Path $OutputDir "$pid-$pName-definition.json"
        az pipelines build definition show --id $pipelineId --project $Project --organization $Org --output json |
        Out-File -FilePath $outFile -Encoding utf8
        Write-Log "Exported Classic definition → $outFile"
        $defFile = $outFile
    }

    # List recent runs (top 10)
    Write-Log 'Listing recent runs via REST...'

    if ($defType -eq 'YAML')
    {
        $runsUrl = "https://dev.azure.com/$orgName/$Project/_apis/pipelines/$pipelineId/runs?api-version=$ApiVersion&`$top=10"
    }
    else
    {
        $runsUrl = "https://dev.azure.com/$orgName/$Project/_apis/build/builds?definitions=$pipelineId&api-version=$ApiVersion&`$top=10"
    }

    $runsResp = Invoke-RestMethod `
        -Uri $runsUrl `
        -Headers $Headers `
        -Method Get `
        -ErrorAction Stop

    $runs = $runsResp.value

    for ($i = 0; $i -lt $runs.Count; $i++)
    {
        $r = $runs[$i]

        # Pick the right timestamp field
        $timeRaw = if ($r.finishedDate)
        {
            $r.finishedDate
        }
        elseif ($r.createdDate)
        {
            $r.createdDate
        }
        else
        {
            $null
        }

        # Convert to local time only if we have one
        if ($timeRaw)
        {
            $t = ([datetime]$timeRaw).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
        }
        else
        {
            $t = 'N/A'
        }

        Write-Host "[$($i+1)] ID:$($r.id)  Result:$($r.result)  Time:$t"
    }

    $selRuns = Read-Host 'Select run(s) to download logs (e.g. 1,2 or skip)'
    if ($selRuns -ne 'skip')
    {
        $chosen = ($selRuns -split ',') | ForEach-Object { [int]$_.Trim() - 1 }
        foreach ($idx in $chosen)
        {
            $runId = $runs[$idx].id

            Write-Log "Downloading full logs ZIP for run $runId..."
            $zipUrl = "https://dev.azure.com/$orgName/$Project/_apis/build/builds/$runId/logs?api-version=$ApiVersion&`$format=zip"
            $zipFile = Join-Path $pipelineFolder ('run{0}_logs.zip' -f $runId)

            Invoke-WebRequest `
                -Uri $zipUrl `
                -Headers $Headers `
                -OutFile $zipFile `
                -ErrorAction Stop

            Write-Log "Saved full logs ZIP → $zipFile"

            # Write-Log "Downloading logs for run $runId..."

            # if ($defType -eq 'YAML')
            # {
            #     $logsUrl = "https://dev.azure.com/$orgName/$Project/_apis/pipelines/$pipelineId/runs/$runId/logs?api-version=$ApiVersion&`$expand=signedContent"
            # }
            # else
            # {
            #     $logsUrl = "https://dev.azure.com/$orgName/$Project/_apis/build/builds/$runId/logs?api-version=$ApiVersion&`$expand=signedContent"
            # }

            # # Fetch the list of logs with signedContent in one call
            # $logs = Invoke-RestMethod -Uri $logsUrl -Headers $Headers -Method Get

            # # Sort by log ID so they stay in the right order
            # $sortedLogs = $logs.logs | Sort-Object id
            # $counter = 1

            # foreach ($logItem in $sortedLogs)
            # {
            #     $logId = $logItem.id
            #     $signedUrl = $logItem.signedContent.url

            #     # Zero-padded prefix to keep filename order
            #     $prefix = '{0:000}' -f $counter
            #     $logFile = Join-Path $pipelineFolder ('{0}_log{1}.txt' -f $prefix, $logId)

            #     Download-AdoArtifact `
            #         -Uri $signedUrl `
            #         -Headers @{ } `
            #         -OutFile $logFile `
            #         -Desc "Log $logId"

            #     $counter++
            # }
        }

    }

    # Add to report
    $Report.Pipelines += @{
        Id         = $pipelineId
        Name       = $pName
        Type       = $defType
        Definition = $defFile
    }
}

###────────────────────
# 6) SAVE JSON REPORT
###────────────────────
$reportFile = Join-Path $OutputDir "EscalationReport_$ts.json"
$Report | ConvertTo-Json -Depth 5 | Out-File -FilePath $reportFile -Encoding utf8
Write-Log "Saved JSON report → $reportFile"

###────────────────────
# 7) PACKAGE REPORT FOR SUPPORT
###────────────────────
# Zip the entire output folder into one archive
$zipFileAll = Join-Path $scriptDir ("EscalationReport_$ts.zip")
Compress-Archive -Path (Join-Path $OutputDir '*') -DestinationPath $zipFileAll -Force
Write-Log "Packaged full report into: $zipFileAll"

# Tell the customer what to do with it
Write-Log "Please upload '$zipFileAll' to your secure workspace and attach it to your Microsoft support case."

Write-Log '=== Script complete ==='