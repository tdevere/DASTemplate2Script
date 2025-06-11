<#
.SYNOPSIS
    Automates the collection of escalation data for Azure DevOps pipeline issues using REST APIs.

.DESCRIPTION
    This script logs into Azure, verifies prerequisites, and gathers key escalation information:
     - Customer details (Azure DevOps Org, Subscription, AAD Tenant)
     - Lists available projects in the org and allows selection.
     - Gets Pipeline details (Name, URL, Type - YAML or Classic, Repository Info) using REST API.
     - Lists recent runs, recommends the latest failed and previous successful, warns about debug logs, and allows selection of MULTIPLE runs for investigation.
     - Downloads the *complete log archive* (zip file) for the selected run(s) using the correct REST API endpoint ('_apis/build/builds' for Classic, '_apis/pipelines' for YAML) and Invoke-WebRequest.
     - Retrieves the pipeline definition:
         - For YAML pipelines: Downloads the YAML file content using the REST API ('_apis/git/repositories/.../items').
         - For Classic pipelines: Exports the JSON definition using 'az pipelines build definition show'.
     - (Optional/Simulated) Gathers self-hosted agent details.
     - All collected data is compiled into a JSON report, including paths to downloaded artifacts.

.PARAMETER Org
    (Optional) Azure DevOps organization URL (e.g., https://dev.azure.com/Contoso).

.PARAMETER Project
    (Optional) The name of the Azure DevOps project. If provided, skips project selection prompt.

.PARAMETER PipelineIds
    (Optional) A comma-separated list of Pipeline IDs to process. If not provided, the script lists available pipelines and prompts for selection.

.PARAMETER OutputDir
    (Optional) Directory to store logs and report. Defaults to a folder named 'AdoPipelineEscalation_Output_YYYYMMDD-HHmm' in the current directory.

.EXAMPLE
    .\Collect-AdoPipelineEscalation_v6.ps1 -Org "https://dev.azure.com/Contoso" # Prompts for Project and Pipeline
.EXAMPLE
    .\Collect-AdoPipelineEscalation_v6.ps1 -Org "https://dev.azure.com/Contoso" -Project "ContosoProj" # Skips Project prompt
.EXAMPLE
    .\Collect-AdoPipelineEscalation_v6.ps1 # Prompts for Org, Project, and Pipeline selection
#>

[CmdletBinding()]
param(
    [string]$Org,
    [string]$Project, # Project parameter remains, allows skipping the prompt
    [string]$PipelineIds,
    [string]$OutputDir # Default value assigned later based on timestamp
)

# --- Functions ---
#region Functions
# ----------------------------
# Function: Write-Log
# Writes log messages to both console and a log file.
# ----------------------------
function Write-Log
{
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $logLine = "$timestamp [$Level] $Message"
    Write-Host $logLine
    # Ensure log file path is available globally before trying to write
    if ($Global:LogFile -and (Test-Path (Split-Path $Global:LogFile -Parent)))
    {
        Add-Content -Path $Global:LogFile -Value $logLine
    }
}

# ----------------------------
# Function: Get-AccessToken
# Retrieves an Azure DevOps access token using the Azure CLI.
# ----------------------------
function Get-AccessToken
{
    Write-Log 'Requesting Azure DevOps access token...'
    try
    {
        # Resource ID for Azure DevOps Services
        $adoResourceId = '499b84ac-1321-427f-aa17-267ca6975798'
        $tokenJson = az account get-access-token --resource $adoResourceId --output json | ConvertFrom-Json -ErrorAction Stop
        Write-Log 'Access token retrieved successfully.'
        return $tokenJson.accessToken
    }
    catch
    {
        Write-Log "Error retrieving Azure DevOps access token: $_" 'ERROR'
        Write-Log "Ensure you are logged in with 'az login' and have permissions." 'ERROR'
        return $null
    }
}

# ----------------------------
# Function: Download-AdoArtifact
# Downloads a file (like logs zip or YAML) using Invoke-WebRequest
# ----------------------------
function Download-AdoArtifact
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers, # Should include Authorization Bearer token
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [string]$ArtifactDescription = 'file' # For logging
    )
    Write-Log "Attempting to download $ArtifactDescription from:"
    Write-Log $Uri
    Write-Log "Output Path: $OutputPath"

    # Ensure parent directory exists
    $ParentDir = Split-Path -Path $OutputPath -Parent
    if (-not (Test-Path -Path $ParentDir))
    {
        Write-Log "Creating parent directory: $ParentDir"
        New-Item -ItemType Directory -Path $ParentDir -Force | Out-Null
    }

    try
    {
        Invoke-WebRequest -Uri $Uri -Headers $Headers -Method Get -OutFile $OutputPath -ErrorAction Stop
        $fileInfo = Get-Item -Path $OutputPath
        if ($fileInfo.Length -eq 0)
        {
            Write-Log "Downloaded $ArtifactDescription is 0 bytes. This might indicate an issue." 'WARN'
        }
        else
        {
            Write-Log "Successfully downloaded $ArtifactDescription ($($fileInfo.Length) bytes) to $OutputPath"
        }
        return $true # Indicate success
    }
    catch
    {
        $statusCode = ''
        $responseContent = ''
        if ($_.Exception.Response)
        {
            $statusCode = $_.Exception.Response.StatusCode.value__
            # Try to get error message from response body if available with Invoke-WebRequest exception
            try
            {
                $responseStream = $_.Exception.Response.GetResponseStream()
                $streamReader = New-Object System.IO.StreamReader($responseStream)
                $responseContent = $streamReader.ReadToEnd()
                $streamReader.Close()
                $responseStream.Close()
            }
            catch
            {
                # Fallback if reading stream fails
                $responseContent = "(Failed to read response stream: $($_.Exception.Message))"
            }
        }
        else
        {
            $responseContent = $_.Exception.Message
        }

        Write-Log "Error downloading $ArtifactDescription." 'ERROR'
        Write-Log "Status Code: $statusCode" 'ERROR'
        Write-Log "Response: $($responseContent | Out-String)" 'ERROR'

        # Clean up potentially incomplete file
        if (Test-Path $OutputPath)
        {
            Remove-Item $OutputPath -Force
            Write-Log "Removed potentially incomplete file: $OutputPath" 'WARN'
        }
        return $false # Indicate failure
    }
}
#endregion

# ----------------------------
# Setup output directories and log file (Unchanged)
# ----------------------------
#region Setup Dirs and LogFile
$timestampForFiles = (Get-Date).ToString('yyyyMMdd-HHmm')
if (-not $PSBoundParameters.ContainsKey('OutputDir'))
{
    # Set default output directory if not provided
    $OutputDir = ".\reports\AdoPipelineEscalation_Output_$timestampForFiles"
}
if (!(Test-Path $OutputDir))
{
    try
    {
        New-Item -ItemType Directory -Path $OutputDir -ErrorAction Stop | Out-Null 
    }
    catch
    {
        Write-Host "FATAL: Could not create output directory '$OutputDir'. Error: $_"; exit 1 
    }
}
$Global:LogFile = Join-Path $OutputDir "CollectionLog_$timestampForFiles.txt"
Write-Log 'Starting pipeline escalation data collection.'
Write-Log "Output will be stored in: $OutputDir"
Write-Log "Detailed log file: $Global:LogFile"
#endregion

# ----------------------------
# Step 1: Azure Login Verification (Unchanged)
# ----------------------------
#region Step 1: Azure Login
Write-Log 'Verifying Azure CLI login status...'
try
{
    $accountInfo = az account show --output json | ConvertFrom-Json -ErrorAction Stop
    if (-not $accountInfo.id)
    {
        throw 'Invalid account info returned.' 
    }
    Write-Log "Azure login successful. Subscription: $($accountInfo.name) ($($accountInfo.id)), Tenant: $($accountInfo.tenantId)"
}
catch
{
    Write-Log "Azure login check failed. Run 'az login' first. Error: $_" 'ERROR'; exit 1 
}
#endregion

# ----------------------------
# Step 2: Check Azure DevOps CLI Extension (Unchanged)
# ----------------------------
#region Step 2: Check ADO Extension
Write-Log 'Checking for Azure DevOps CLI extension...'
try
{
    $adoExtension = az extension show --name azure-devops --output json | ConvertFrom-Json -ErrorAction Stop
    Write-Log "Azure DevOps CLI extension version $($adoExtension.version) found."
}
catch
{
    Write-Log 'Azure DevOps CLI extension not found. Attempting to install...' 'WARN'
    try
    {
        az extension add --name azure-devops --output none --verbose; Write-Log 'Azure DevOps CLI extension installed.' 
    }
    catch
    {
        Write-Log "Failed to install Azure DevOps CLI extension ('az extension add --name azure-devops'). Error: $_" 'ERROR'; exit 1 
    }
}
#endregion

# ----------------------------
# Step 3: Collect Required Information (Org, Project, Pipeline IDs) (Unchanged)
# ----------------------------
#region Step 3: Collect Org/Project/Pipeline Info
# 3a. Get Org
if (-not $Org)
{
    $Org = Read-Host 'Enter Azure DevOps Organization URL (e.g., https://dev.azure.com/Contoso)' 
}
if (-not $Org -or $Org -notmatch '^https://dev\.azure\.com/.+')
{
    Write-Log 'Valid Organization URL required.' 'ERROR'; exit 1 
}
$Org = $Org.TrimEnd('/')
Write-Log "Using Azure DevOps Org: $Org"
az devops configure --defaults organization=$Org | Out-Null
$uri = [System.Uri]$Org; $orgPart = $uri.Segments[-1].Trim('/')
Write-Log "Extracted Organization Name: $orgPart"

# 3b. Get Project
if (-not $Project)
{
    Write-Log "Retrieving list of projects in organization '$orgPart'..."
    try
    {
        $projectsList = az devops project list --organization $Org --output json --query 'sort_by(value,&name)[].{name:name, id:id}' | ConvertFrom-Json -ErrorAction Stop
        if ($projectsList.Count -eq 0)
        {
            Write-Log "No projects found in organization '$Org'." 'ERROR'; exit 1 
        }
        Write-Host "`nAvailable Projects in '$orgPart':"; for ($i = 0; $i -lt $projectsList.Count; $i++)
        {
            Write-Host "[$($i+1)] $($projectsList[$i].name)" 
        }
        $projectChoiceInput = ''; $selectedIndex = -1
        while ($selectedIndex -eq -1)
        {
            $projectChoiceInput = Read-Host 'Enter the number for the project'
            if ($projectChoiceInput -match '^\d+$' -and [int]$projectChoiceInput -ge 1 -and [int]$projectChoiceInput -le $projectsList.Count)
            {
                $selectedIndex = [int]$projectChoiceInput - 1; $Project = $projectsList[$selectedIndex].name
            }
            else
            {
                Write-Warning "Invalid input: '$projectChoiceInput'." 
            }
        }
        Write-Log "User selected project: $Project"
    }
    catch
    {
        Write-Log "Error retrieving projects list. Error: $_" 'ERROR'; exit 1 
    }
}
else
{
    Write-Log "Using project '$Project' provided via parameter." 
}
try
{
    # Verify final project
    Write-Log "Verifying access to project '$Project'..."; az devops project show --project $Project --organization $Org -o none --only-show-errors; Write-Log "Project '$Project' verified."
    az devops configure --defaults project=$Project | Out-Null
}
catch
{
    Write-Log "Failed to verify project '$Project'. Error: $_" 'ERROR'; exit 1 
}

# 3c. Store Customer Details
$SubscriptionId = $accountInfo.id; $SubscriptionName = $accountInfo.name; $AADTenantId = $accountInfo.tenantId
Write-Log "Subscription: $SubscriptionName ($SubscriptionId), Tenant: $AADTenantId"

# 3d. Get Pipeline IDs
$PipelineIdList = @()
if (-not $PipelineIds)
{
    Write-Log "Retrieving list of available pipelines in project '$Project'..."
    try
    {
        $pipelinesList = az pipelines list --project $Project --output json --query 'sort_by([], &name)' | ConvertFrom-Json -ErrorAction Stop
        if ($pipelinesList.Count -eq 0)
        {
            Write-Log "No pipelines found in project '$Project'." 'ERROR'; exit 1 
        }
        Write-Host "`nAvailable Pipelines in '$Project':"; for ($i = 0; $i -lt $pipelinesList.Count; $i++)
        {
            Write-Host "[$($i+1)] ID: $($pipelinesList[$i].id) Name: $($pipelinesList[$i].name) Path: $($pipelinesList[$i].folder)" 
        }
        $selectedIndicesInput = ''; $indices = @()
        while ($indices.Count -eq 0)
        {
            $selectedIndicesInput = Read-Host 'Enter the number(s) of the pipeline(s) (e.g., 1 or 1,3)'
            $indices = $selectedIndicesInput -split ',' | ForEach-Object { $num = $_.Trim(); if ($num -match '^\d+$' -and [int]$num -ge 1 -and [int]$num -le $pipelinesList.Count)
                {
                    [int]$num - 1 
                }
                else
                {
                    Write-Warning "Invalid: '$num'"; $null 
                } } | Where-Object { $_ -ne $null }
            if ($indices.Count -eq 0 -and $selectedIndicesInput)
            {
                Write-Warning 'No valid pipeline numbers.'
            }
        }
        $PipelineIdList = foreach ($index in $indices)
        {
            $pipelinesList[$index].id 
        }
    }
    catch
    {
        Write-Log "Error retrieving pipelines list: $_" 'ERROR'; exit 1 
    }
}
else
{
    $PipelineIdList = $PipelineIds -split ',' | ForEach-Object { $_.Trim() }; Write-Log 'Using provided Pipeline IDs.' 
}
if ($PipelineIdList.Count -eq 0)
{
    Write-Log 'No pipeline IDs selected/provided.' 'ERROR'; exit 1 
}
Write-Log "Pipeline IDs to process: $($PipelineIdList -join ', ')"
#endregion

# ----------------------------
# Step 4: Process each Pipeline
# ----------------------------
$Report = @{
    CollectionTimestamp      = (Get-Date -Format 'o')
    CollectedByScriptVersion = '1.5-REST' # Indicate version using REST
    CustomerDetails          = @{
        OrganizationUrl = $Org; OrganizationName = $orgPart; ProjectName = $Project
        SubscriptionId = $SubscriptionId; SubscriptionName = $SubscriptionName; AADTenantId = $AADTenantId
    }
    PipelinesProcessed       = @()
    AllArtifacts             = @()
}

# Get access token ONCE for all REST calls
$Global:AdoAccessToken = Get-AccessToken
if (-not $Global:AdoAccessToken)
{
    Write-Log 'Failed to obtain access token. Cannot proceed with API calls.' 'FATAL'
    exit 1
}
# Prepare Auth Headers
$Global:AdoHeaders = @{ Authorization = "Bearer $Global:AdoAccessToken" }
# Standard API Version
$Global:ApiVersion = '7.0'

# --- Pipeline Processing Loop ---
#region Pipeline Processing Loop
foreach ($pipelineId in $PipelineIdList)
{
    Write-Log "================ Processing Pipeline ID: $pipelineId ================" -Level 'HEADER'
    $pipelineData = @{
        PipelineId = $pipelineId; PipelineName = 'Unknown'; PipelineUrl = 'N/A'
        DefinitionType = 'Unknown'; RepositoryInfo = $null; DefinitionFilePath = 'N/A'
        Logs = @(); AgentInfo = $null; Errors = @()
    }
    $pipelineFolder = Join-Path $OutputDir "Pipeline_$pipelineId"
    New-Item -ItemType Directory -Path $pipelineFolder -Force | Out-Null

    # 4a. Get Pipeline Definition Details using REST API
    #region Step 4a: Get Pipeline Definition
    Write-Log "Fetching details for pipeline ID $pipelineId via REST API..."
    $pipelineDetail = $null
    $pipelineDetailUrl = "https://dev.azure.com/$orgPart/$Project/_apis/pipelines/$pipelineId`?api-version=$Global:ApiVersion"
    try
    {
        $pipelineDetail = Invoke-RestMethod -Uri $pipelineDetailUrl -Headers $Global:AdoHeaders -Method Get -ErrorAction Stop
        $pipelineData.PipelineName = $pipelineDetail.name
        $pipelineData.PipelineUrl = $pipelineDetail._links.web.href
        Write-Log "Pipeline Name: $($pipelineData.PipelineName)"
        Write-Log "Pipeline URL: $($pipelineData.PipelineUrl)"

        # Check for configuration block existence before accessing properties
        if ($null -ne $pipelineDetail.configuration)
        {
            $pipelineData.RepositoryInfo = $pipelineDetail.configuration.repository # Store the whole repo block
            if ($null -ne $pipelineData.RepositoryInfo)
            {
                Write-Log "Repository Type: $($pipelineData.RepositoryInfo.type), Name: $($pipelineData.RepositoryInfo.name), ID: $($pipelineData.RepositoryInfo.id)"
            }
            else
            {
                Write-Log 'Repository information not found in pipeline configuration.' 'WARN' 
            }

            # Determine Definition Type and Retrieve Definition File
            $definitionFile = $null
            if ($pipelineDetail.configuration.type -eq 'yaml')
            {
                $pipelineData.DefinitionType = 'YAML'
                Write-Log 'Pipeline type: YAML'
                $yamlFilePath = $pipelineDetail.configuration.path
                $repoType = $pipelineData.RepositoryInfo.type
                $repoId = $pipelineData.RepositoryInfo.id
                Write-Log "YAML Path: $yamlFilePath"

                if ($repoType -eq 'azureReposGit' -or $repoType -eq 'TfsGit')
                {
                    # TfsGit for older responses, azureReposGit common now
                    Write-Log 'Attempting to download YAML file from Azure Repos Git...'
                    $safeYamlPath = $yamlFilePath.TrimStart('/') # API path shouldn't start with /
                    $yamlFileNameSafe = ($safeYamlPath -split '[\\/]')[-1]
                    $yamlOutputPath = Join-Path $pipelineFolder "$($pipelineId)_$($yamlFileNameSafe).yaml"

                    # Use Git Items API with Accept header for raw content
                    $yamlFileUrl = "https://dev.azure.com/$orgPart/$Project/_apis/git/repositories/$repoId/items`?path=$([uri]::EscapeDataString($safeYamlPath))&api-version=$Global:ApiVersion&download=true" # Try download=true parameter
                    # $yamlHeaders = $Global:AdoHeaders.Clone()
                    # $yamlHeaders.Add('Accept', 'application/octet-stream') # Alternative: Request octet-stream

                    if (Download-AdoArtifact -Uri $yamlFileUrl -Headers $Global:AdoHeaders -OutputPath $yamlOutputPath -ArtifactDescription 'YAML definition')
                    {
                        $definitionFile = $yamlOutputPath
                        # Optional: Verify content isn't JSON error message
                        $downloadedContent = Get-Content -Path $yamlOutputPath -Raw
                        if ($downloadedContent -match '^{\s*".*\s*}$')
                        {
                            # Basic JSON check
                            Write-Log 'Downloaded YAML file appears to be JSON error content. Removing.' 'WARN'
                            Remove-Item $yamlOutputPath -Force
                            $definitionFile = $null
                            $pipelineData.Errors += 'Failed to download valid YAML content (got JSON error).'
                            $pipelineData.DefinitionFilePath = 'Error downloading YAML (JSON error received)'
                        }
                    }
                    else
                    {
                        $errMsg = "Failed to download YAML definition '$safeYamlPath' from repo '$repoId'." # Error logged in function
                        $pipelineData.Errors += $errMsg
                        $pipelineData.DefinitionFilePath = "Error downloading YAML: $errMsg"
                    }
                }
                else
                {
                    $errMsg = "YAML definition retrieval currently only supports Azure Repos Git. Repository type '$repoType' not supported."
                    Write-Log $errMsg 'WARN'; $pipelineData.Errors += $errMsg; $pipelineData.DefinitionFilePath = "Unsupported repository type: $repoType"
                }

            }
            elseif ($pipelineDetail.configuration.type -eq 'designer' -or $pipelineDetail.type -eq 'build')
            {
                # Check older 'type' property too for Classic
                $pipelineData.DefinitionType = 'Classic (Designer)'
                Write-Log 'Pipeline type: Classic (Designer)'
                Write-Log "Attempting to export Classic definition as JSON using 'az pipelines build definition show'..."
                $jsonOutputPath = Join-Path $pipelineFolder "$($pipelineId)_$($pipelineData.PipelineName -replace '[^\w\.]', '_')_classic_definition.json"
                try
                {
                    # Use 'az pipelines build definition show' for classic - it's reliable for this part.
                    $defJson = az pipelines build definition show --id $pipelineId --project $Project --organization $Org --output json --only-show-errors
                    $defJson | Set-Content -Path $jsonOutputPath -Encoding UTF8
                    $definitionFile = $jsonOutputPath
                    Write-Log "Classic definition exported to: $definitionFile"
                }
                catch
                {
                    $errMsg = "Failed to export Classic definition using az cli. Error: $_"; Write-Log $errMsg 'ERROR'; $pipelineData.Errors += $errMsg; $pipelineData.DefinitionFilePath = "Error exporting Classic: $errMsg"
                }
            }
            else
            {
                # Unknown type
                $errMsg = "Unknown pipeline configuration type: $($pipelineDetail.configuration.type)"; Write-Log $errMsg 'WARN'; $pipelineData.Errors += $errMsg; $pipelineData.DefinitionType = "Unknown ($($pipelineDetail.configuration.type))"; $pipelineData.DefinitionFilePath = 'Unknown definition type.'
            }
        }
        else
        {
            # No configuration block found
            $errMsg = "Pipeline configuration details not found in API response for ID $pipelineId. Cannot determine type or definition path."; Write-Log $errMsg 'ERROR'; $pipelineData.Errors += $errMsg; $pipelineData.DefinitionType = 'Unknown (No Config)'; $pipelineData.DefinitionFilePath = 'Configuration details missing.'
        }

        # Update report if definition was saved
        if ($definitionFile -and (Test-Path $definitionFile))
        {
            $pipelineData.DefinitionFilePath = $definitionFile
            $Report.AllArtifacts += @{ PipelineId = $pipelineId; ArtifactType = "Pipeline Definition ($($pipelineData.DefinitionType))"; FilePath = $definitionFile }
        }

    }
    catch
    {
        $errMsg = "Failed to fetch details via REST for pipeline ID $pipelineId. Error: $_"; Write-Log $errMsg 'ERROR'; $pipelineData.Errors += $errMsg
        $Report.PipelinesProcessed += $pipelineData; Write-Log "================ Skipping further processing for Pipeline ID: $pipelineId ================" -Level 'HEADER'; continue
    }
    #endregion

    # 4b. List Recent Runs, Recommend, and Select MULTIPLE (Unchanged logic)
    #region Step 4b: Select Runs for Log Download
    Write-Log "Fetching recent runs for pipeline ID $pipelineId..."
    $selectedRunIds = @()
    $runs = @()
    try
    {
        # Get top 20 runs using 'az pipelines runs list' (reliable for listing)
        $runs = az pipelines runs list --pipeline-id $pipelineId --project $Project --top 20 --output json --query 'sort_by([], &finishTime || startTime || queueTime)[].{id:id, name:name, result:result, status:status, queuedTime:queuedTime, startTime:startTime, finishTime:finishTime, sourceBranch:sourceBranch, sourceVersion:sourceVersion, url:_links.web.href}' | ConvertFrom-Json -ErrorAction Stop

        if ($runs.Count -eq 0)
        {
            Write-Log "No runs found for Pipeline ID $pipelineId." 'WARN'; $pipelineData.Errors += 'No runs found for this pipeline.' 
        }
        else
        {
            Write-Host "`nRecent Runs for Pipeline '$($pipelineData.PipelineName)' (ID: $pipelineId):"
            Write-Host ('{0,-5} {1,-15} {2,-12} {3,-10} {4,-25} {5}' -f '#', 'Run ID', 'Result', 'Status', 'Finished/Started', 'Branch'); Write-Host ('-' * 80)
            $latestFailedRun = $runs | Where-Object { $_.result -eq 'failed' } | Sort-Object { [datetime]$_.finishTime } -Descending | Select-Object -First 1
            $lastSuccessfulBeforeFailure = $null
            if ($latestFailedRun)
            {
                $failureTime = if ($latestFailedRun.startTime)
                {
                    [datetime]$latestFailedRun.startTime 
                }
                else
                {
                    [datetime]$latestFailedRun.queuedTime 
                }; $lastSuccessfulBeforeFailure = $runs | Where-Object { $_.result -eq 'succeeded' -and ($_.finishTime -ne $null) -and ([datetime]$_.finishTime -lt $failureTime) } | Sort-Object { [datetime]$_.finishTime } -Descending | Select-Object -First 1 
            }
            $latestFailedIndex = -1; $lastSuccessfulIndex = -1
            for ($i = 0; $i -lt $runs.Count; $i++)
            {
                $run = $runs[$i]; if ($latestFailedRun -and $run.id -eq $latestFailedRun.id)
                {
                    $latestFailedIndex = $i + 1 
                }; if ($lastSuccessfulBeforeFailure -and $run.id -eq $lastSuccessfulBeforeFailure.id)
                {
                    $lastSuccessfulIndex = $i + 1 
                }
                $displayTime = if ($run.finishTime)
                {
                    [datetime]$run.finishTime
                }
                elseif ($run.startTime)
                {
                    [datetime]$run.startTime
                }
                else
                {
                    [datetime]$run.queuedTime
                }; Write-Host ('[{0,-3}] {1,-15} {2,-12} {3,-10} {4,-25:yyyy-MM-dd HH:mm:ss} {5}' -f ($i + 1), $run.id, ($run.result | Out-String).Trim(), ($run.status | Out-String).Trim(), $displayTime.ToLocalTime(), $run.sourceBranch)
            }
            Write-Host "`n--- Recommendations ---" -ForegroundColor Yellow
            if ($latestFailedIndex -gt 0)
            {
                Write-Host "Latest failed run: [$latestFailedIndex] (ID: $($latestFailedRun.id))" -ForegroundColor Yellow 
            }
            else
            {
                Write-Host 'No recent failed run found.' -ForegroundColor Green 
            }
            if ($lastSuccessfulIndex -gt 0)
            {
                Write-Host "Last successful run before failure: [$lastSuccessfulIndex] (ID: $($lastSuccessfulBeforeFailure.id))" -ForegroundColor Yellow 
            }
            elseif ($latestFailedIndex -gt 0)
            {
                Write-Host 'No successful run found before latest failure.' -ForegroundColor Yellow 
            }
            Write-Host 'Consider re-running with System.Debug = true for verbose logs.' -ForegroundColor Cyan; Write-Host '-----------------------' -ForegroundColor Yellow
            $runChoiceInput = ''; while ($selectedRunIds.Count -eq 0)
            {
                $runChoiceInput = Read-Host "Enter number(s) [#,#] for logs (e.g., $latestFailedIndex or '$latestFailedIndex,$lastSuccessfulIndex' or 'skip')"
                if ($runChoiceInput -eq 'skip')
                {
                    Write-Log 'Skipping log download.'; break 
                }
                
                $choices = $runChoiceInput -split ',' | ForEach-Object { $_.Trim() }; $validChoices = @(); $invalidInput = $false
                
                foreach ($choice in $choices)
                {
                    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $runs.Count)
                    {
                        $validChoices += $runs[[int]$choice - 1].id 
                    }
                    else
                    {
                        Write-Warning "Invalid: '$choice'"; $invalidInput = $true; break 
                    } 
                }
                if (-not $invalidInput -and $validChoices.Count -gt 0)
                {
                    $selectedRunIds = $validChoices | Select-Object -Unique 
                }
                elseif (-not $invalidInput -and $runChoiceInput)
                {
                    Write-Warning 'No valid run numbers entered.' 
                }
            }
            if ($selectedRunIds.Count -gt 0)
            {
                Write-Log "Selected Run ID(s) for log download: $($selectedRunIds -join ', ')" 
            }
        }
    }
    catch
    {
        $errMsg = "Error fetching/processing runs for Pipeline ID $pipelineId $_"; Write-Log $errMsg 'ERROR'; $pipelineData.Errors += $errMsg 
    }
    #endregion

    # 4c. Download Logs for selected runs using REST API and Invoke-WebRequest
    #region Step 4c: Download Logs via REST (Enumerate logs and download each)
    if ($selectedRunIds.Count -gt 0)
    {
        Write-Log 'Attempting to download logs for selected runs via REST API (individual logs)...'
        foreach ($runId in $selectedRunIds)
        {
            Write-Log "Processing log download for Run ID: $runId"
            # Determine logs listing endpoint URL based on pipeline definition type
            if ($pipelineData.DefinitionType -eq 'Classic (Designer)')
            {
                # Classic pipelines use the Build API logs endpoint (no preview required)
                $logsListUrl = "https://dev.azure.com/$orgPart/$Project/_apis/build/builds/$runId/logs?api-version=7.2-preview"
                Write-Log 'Using Build API logs endpoint for Classic pipeline logs.'
            }
            elseif ($pipelineData.DefinitionType -eq 'YAML')
            {
                # YAML pipelines use the Pipelines API logs endpoint with preview version
                $logsListUrl = "https://dev.azure.com/$orgPart/$Project/_apis/pipelines/$pipelineId/runs/$runId/logs?api-version=7.2-preview"
                Write-Log 'Using Pipelines API logs endpoint for YAML pipeline logs.'
            }
            else
            {
                Write-Log "Unknown pipeline definition type '$($pipelineData.DefinitionType)' for Pipeline ID $pipelineId. Skipping log download for run $runId." 'ERROR'
                continue
            }

            # Get the list of log items for the run
            Write-Log "Fetching log list from: $logsListUrl"
            try
            {
                $logsResponse = Invoke-RestMethod -Uri $logsListUrl -Headers $Global:AdoHeaders -Method Get -ErrorAction Stop
                if (-not $logsResponse.logs -or $logsResponse.count -eq 0)
                {
                    Write-Log "No logs found for run $runId." 'WARN'
                    continue
                }
                Write-Log "Retrieved $($logsResponse.count) log(s) for run $runId."
            }
            catch
            {
                Write-Log "Error retrieving log list for run $runId $_" 'ERROR'
                continue
            }

            # Enumerate each log and download it
            foreach ($log in $logsResponse.logs)
            {
                $logId = $log.id
                $logOutputPath = Join-Path $pipelineFolder "Run${runId}_Log${logId}.txt"
                Write-Log "Downloading log ID $logId. Expected line count: $($log.lineCount)"
                # Use the 'url' field from the log item directly
                $logUri = $log.url
                if (Download-AdoArtifact -Uri $logUri -Headers $Global:AdoHeaders -OutputPath $logOutputPath -ArtifactDescription "Log $logId for Run $runId")
                {
                    Write-Log "Downloaded log ID $logId to $logOutputPath"
                    $pipelineData.Logs += @{ RunId = $runId; LogId = $logId; FilePath = $logOutputPath; SizeBytes = (Get-Item $logOutputPath).Length }
                    $Report.AllArtifacts += @{ PipelineId = $pipelineId; RunId = $runId; ArtifactType = "Log $logId"; FilePath = $logOutputPath }
                }
                else
                {
                    Write-Log "Failed to download log ID $logId for run $runId." 'ERROR'
                    $pipelineData.Errors += "Failed to download log ID $logId for run $runId."
                }
            }
        }
    }
    else
    {
        Write-Log "No runs selected for log download, or an error occurred during run listing/selection for pipeline $pipelineId."
    }
    #endregion


    # 4d. (Optional/Placeholder) Gather agent information (Unchanged)
    #region Step 4d: Agent Info
    try
    {
        Write-Log 'Gathering agent information (Simulated)...'
        $agentInfo = @{ Pool = 'Azure Pipelines'; AgentName = 'Hosted Agent (Simulated)'; AgentOS = 'Linux/Windows/macOS (Simulated)'; AgentVersion = 'Latest (Simulated)'; IsSelfHosted = $false }
        $pipelineData.AgentInfo = $agentInfo
    }
    catch
    {
        $errMsg = "Error during simulated agent detail gathering: $_"; Write-Log $errMsg 'ERROR'; $pipelineData.Errors += $errMsg 
    }
    #endregion

    # Add processed pipeline data to the main report
    $Report.PipelinesProcessed += $pipelineData
    Write-Log "================ Finished Processing Pipeline ID: $pipelineId ================" -Level 'HEADER'
} # End foreach pipelineId
#endregion

# ----------------------------
# Step 5: Save JSON Report (Unchanged)
# ----------------------------
#region Step 5: Save Report
$reportFile = Join-Path $OutputDir "PipelineEscalationReport_$timestampForFiles.json"
Write-Log 'Compiling final JSON report...'
try
{
    $Report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFile -Encoding UTF8 -ErrorAction Stop
    Write-Log "JSON report saved successfully: $reportFile"
    $Report.AllArtifacts += @{ PipelineId = 'N/A'; ArtifactType = 'JSON Summary Report'; FilePath = $reportFile }
}
catch
{
    Write-Log "FATAL: Error saving JSON report to '$reportFile'. Error: $_" 'ERROR' 
}
#endregion

# ----------------------------
# Step 6: Final Summary (Unchanged)
# ----------------------------
#region Step 6: Final Summary
Write-Log 'Script execution completed.'
Write-Log 'Collected Artifacts Summary:'
if ($Report.AllArtifacts.Count -gt 0)
{
    $Report.AllArtifacts | ForEach-Object { Write-Log " - Type: $($_.ArtifactType), Path: $($_.FilePath)" } 
}
else
{
    Write-Log ' - No artifacts were successfully collected.' 
}
Write-Log "Please review the JSON report '$reportFile' and the contents of the '$OutputDir' directory."
Write-Log 'End of script.'
#endregion

# ----------------------------
# Function: Save-IcMReport
# Creates a Markdown file based on a template and data from the $Report.
# ----------------------------
function Save-IcMReport {
    param (
        [hashtable]$Report,
        [string]$OutputDir
    )

    # Define the output Markdown file name
    $timestampForMd = (Get-Date -Format 'yyyyMMdd-HHmm')
    $mdFile = Join-Path $OutputDir "IcM_Report_$timestampForMd.md"

    # Build the Markdown content using here-string and inline expressions.
    $mdContent = @"
# Incident (IcM) Report

**Collection Timestamp:** $($Report.CollectionTimestamp)

## Customer Details:
======================================
- **AzDev Services Org URL:** $($Report.CustomerDetails.OrganizationUrl)
- **Organization Name:** $($Report.CustomerDetails.OrganizationName)
- **Project Name:** $($Report.CustomerDetails.ProjectName)
- **Subscription ID:** $($Report.CustomerDetails.SubscriptionId)
- **Subscription Name:** $($Report.CustomerDetails.SubscriptionName)
- **AAD Tenant ID:** $($Report.CustomerDetails.AADTenantId)

## Issue:
======================================
*(Clear description of the issue, including any error messages the customer receives)*

## Troubleshooting:
======================================
The following details were collected:
"@

    # Append details from each processed pipeline.
    foreach ($pipeline in $Report.PipelinesProcessed) {
        $mdContent += "`n### Pipeline: $($pipeline.PipelineName) (ID: $($pipeline.PipelineId))`n"
        $mdContent += "- **Pipeline URL:** $($pipeline.PipelineUrl)`n"
        $mdContent += "- **Definition Type:** $($pipeline.DefinitionType)`n"
        $mdContent += "- **Definition File Path:** $($pipeline.DefinitionFilePath)`n"
        if ($pipeline.Errors -and $pipeline.Errors.Count -gt 0) {
            $mdContent += "- **Errors:** $([string]::Join('; ', $pipeline.Errors))`n"
        }
        else {
            $mdContent += "- **Errors:** None`n"
        }
        if ($pipeline.Logs -and $pipeline.Logs.Count -gt 0) {
            $mdContent += "- **Number of Logs Downloaded:** $($pipeline.Logs.Count)`n"
        }
        else {
            $mdContent += "- **Number of Logs Downloaded:** 0`n"
        }
    }

    $mdContent += @"

## Debugging Done:
======================================
- *(Include all the details of the troubleshooting performed, analysis of logs, Kusto queries, etc.)*

## Ask:
======================================
- *(Specify what you need from the escalation team or further instructions.)*
"@

    # Save the markdown content to the file
    try {
        $mdContent | Set-Content -Path $mdFile -Encoding UTF8 -ErrorAction Stop
        Write-Log "IcM Markdown report saved successfully: $mdFile"
    }
    catch {
        Write-Log "Error saving IcM Markdown report to '$mdFile'. Error: $_" 'ERROR'
    }
}

# ----------------------------
# Step 6: Final Summary (Unchanged)
# ----------------------------
#region Step 6: Final Summary
Write-Log 'Script execution completed.'
Write-Log 'Collected Artifacts Summary:'
if ($Report.AllArtifacts.Count -gt 0)
{
    $Report.AllArtifacts | ForEach-Object { Write-Log " - Type: $($_.ArtifactType), Path: $($_.FilePath)" }
}
else
{
    Write-Log ' - No artifacts were successfully collected.'
}
Write-Log "Please review the JSON report '$reportFile' and the contents of the '$OutputDir' directory."
Write-Log 'End of script.'
#endregion

# ----------------------------
# Step 7: Save IcM Markdown Report (New)
# ----------------------------
Save-IcMReport -Report $Report -OutputDir $OutputDir
