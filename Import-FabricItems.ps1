# Parameters for the script
param(
    [Parameter(Mandatory=$true)]
    [string]$FolderPath,
    
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceName,
    
    [Parameter(Mandatory=$false)]
    [string]$WorkspaceId = "",
    
    [Parameter(Mandatory=$false)]
    [string]$TenantId = "354ffbfb-e376-41b5-9059-522f3cdf73be",
    
    [Parameter(Mandatory=$false)]
    [string]$ClientId = "2d24131e-463a-41cb-9667-0edd2e20ef22",
    
    [Parameter(Mandatory=$false)]
    [string]$ClientSecret = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
    
    [Parameter(Mandatory=$false)]
    [switch]$UseUserLogin = $false
)

# Function to handle module loading and authentication
function Initialize-Environment {
    param(
        [bool]$UseUserLogin
    )
    
    try {
        # Load Az.Accounts module
        if (-not (Get-Module Az.Accounts -ListAvailable)) {
            Write-Host "Installing Az.Accounts module..."
            Install-Module Az.Accounts -Scope CurrentUser -Force -AllowClobber
        }

        # Import Az.Accounts with -Force
        Write-Host "Importing Az.Accounts module..."
        Import-Module Az.Accounts -Force -DisableNameChecking

        # Authenticate based on method chosen
        if ($UseUserLogin) {
            Write-Host "Authenticating with user login (interactive)..."
            Connect-AzAccount
        }
        else {
            Write-Host "Authenticating with service principal..."
            $secureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
            $credentials = New-Object System.Management.Automation.PSCredential($ClientId, $secureSecret)
            Connect-AzAccount -ServicePrincipal -TenantId $TenantId -Credential $credentials
        }
        
        # Download and import FabricPS-PBIP module
        $moduleFolder = "$PSScriptRoot\modules"
        New-Item -ItemType Directory -Path $moduleFolder -Force | Out-Null

        Write-Host "Downloading FabricPS-PBIP module..."
        @(
            "https://raw.githubusercontent.com/microsoft/Analysis-Services/master/pbidevmode/fabricps-pbip/FabricPS-PBIP.psm1",
            "https://raw.githubusercontent.com/microsoft/Analysis-Services/master/pbidevmode/fabricps-pbip/FabricPS-PBIP.psd1"
        ) | ForEach-Object {
            $fileName = Split-Path $_ -Leaf
            Invoke-WebRequest -Uri $_ -OutFile (Join-Path $moduleFolder $fileName)
        }

        Write-Host "Importing FabricPS-PBIP module..."
        Import-Module (Join-Path $moduleFolder "FabricPS-PBIP.psm1") -Force -DisableNameChecking
        
        return $true
    }
    catch {
        Write-Error "Failed to initialize environment: $_"
        return $false
    }
}

# Function to ensure and get workspace ID
function Get-FabricWorkspaceId {
    param(
        [string]$WorkspaceName,
        [string]$WorkspaceId
    )
    
    try {
        # If WorkspaceId is provided and not empty, try to use it
        if (![string]::IsNullOrEmpty($WorkspaceId)) {
            Write-Host "Using provided workspace ID: $WorkspaceId"
            
            # Verify the workspace exists
            try {
                $workspace = Get-FabricWorkspace -workspaceId $WorkspaceId
                Write-Host "Successfully accessed workspace: $($workspace.name)"
                return $WorkspaceId
            }
            catch {
                Write-Warning "Could not access workspace with ID $WorkspaceId. Will try to create/find by name."
            }
        }
        
        # Try to get or create workspace by name
        Write-Host "Creating/accessing workspace by name: $WorkspaceName"
        $workspaceId = New-FabricWorkspace -name $WorkspaceName -skipErrorIfExists
        
        if ($workspaceId) {
            Write-Host "Using workspace with ID: $workspaceId"
            return $workspaceId
        }
        
        throw "Failed to access or create workspace"
    }
    catch {
        Write-Error "Failed to get workspace: $_"
        throw "Could not access or create workspace. Please check permissions and try again."
    }
}

# Function to find files recursively
function Find-PbipFiles {
    param (
        [string]$Path
    )
    
    # Look for specific paths based on PBIP structure
    $semanticModels = Get-ChildItem -Path $Path -Filter "*.SemanticModel" -Recurse | 
                     Where-Object { $_.PSIsContainer }
    
    # Add this debug code to show all found semantic model folders
    Write-Host "All semantic model folders found:"
    $semanticModels | ForEach-Object { Write-Host "  - $($_.FullName)" }
    
    $reports = Get-ChildItem -Path $Path -Filter "*.Report" -Recurse | 
               Where-Object { $_.PSIsContainer }
    
    # Similarly, you can add this for reports if needed
    Write-Host "All report folders found:"
    $reports | ForEach-Object { Write-Host "  - $($_.FullName)" }
    
    return @{
        SemanticModels = $semanticModels
        Reports = $reports
    }
}

# Function to import items to Fabric
function Import-FabricItems {
    param (
        [string]$WorkspaceId,
        [System.IO.DirectoryInfo[]]$SemanticModels,
        [System.IO.DirectoryInfo[]]$Reports
    )

    # Store semantic model imports for binding
    $semanticModelMappings = @{}

# First import all semantic models
Write-Host "Starting to import $($SemanticModels.Count) semantic models"
foreach ($model in $SemanticModels) {
    Write-Host "Processing semantic model: $($model.FullName)"
    try {
        # Check for definition.pbism file
        $modelFile = Get-ChildItem -Path $model.FullName -Filter "definition.pbism" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if ($modelFile) {
            Write-Host "Found definition file: $($modelFile.FullName)"
            
            # Add verbose error handling
            try {
                Write-Host "Attempting to import semantic model to workspace ID: $WorkspaceId"
                $importedModel = Import-FabricItem -workspaceId $WorkspaceId -path $model.FullName -verbose -ErrorAction Stop
                
                if ($importedModel) {
                    $semanticModelMappings[$model.BaseName] = $importedModel.Id
                    Write-Host "Successfully imported semantic model: $($model.BaseName) with ID: $($importedModel.Id)" -ForegroundColor Green
                } else {
                    Write-Warning "Import-FabricItem returned null or empty for $($model.BaseName)"
                }
            } catch {
                Write-Error "Error during Import-FabricItem: $_"
                Write-Error "Error details: $($_.Exception.ToString())"
            }
        } else {
            Write-Warning "Cannot find valid item definitions (definition.pbism) in the '$($model.FullName)'"
        }
    }
    catch {
        Write-Error "Failed to import semantic model $($model.BaseName): $_"
        continue
    }
}

# After import, display summary
Write-Host "Summary of imported semantic models:"
foreach ($key in $semanticModelMappings.Keys) {
    Write-Host "  - $key : $($semanticModelMappings[$key])"
}

    # Then import and bind reports
    foreach ($report in $Reports) {
        Write-Host "Processing report: $($report.FullName)"

        $semanticModelName = $report.BaseName.Replace(".Report", ".SemanticModel")

        if ($semanticModelMappings.ContainsKey($semanticModelName)) {
            $semanticModelId = $semanticModelMappings[$semanticModelName]

            try {
                Write-Host "Importing report and binding to semantic model ID: $semanticModelId"
                # Check for definition.pbir file
                $reportFile = Get-ChildItem -Path $report.FullName -Filter "definition.pbir" -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($reportFile) {
                    Write-Host "Found definition file: $($reportFile.FullName)"
                    $reportImport = Import-FabricItem -workspaceId $WorkspaceId `
                                  -path $report.FullName `
                                  -itemProperties @{"semanticModelId" = $semanticModelId} `
                                  -verbose
                    Write-Host "Successfully imported report: $($report.BaseName)"
                } else {
                    Write-Warning "Cannot find valid item definitions (definition.pbir) in the '$($report.FullName)'"
                }
            }
            catch {
                Write-Error "Failed to import report $($report.BaseName): $_"
                continue
            }
        }
        else {
            Write-Warning "Could not find matching semantic model for report: $($report.BaseName)"
        }
    }
}

# Main script execution
try {
    # Initialize environment and authenticate
    Write-Host "Initializing environment and authenticating..."
    $initialized = Initialize-Environment -UseUserLogin $UseUserLogin
    if (-not $initialized) {
        throw "Failed to initialize environment and authenticate"
    }
    
    # Get workspace ID (from provided ID or by name)
    $activeWorkspaceId = Get-FabricWorkspaceId -WorkspaceName $WorkspaceName -WorkspaceId $WorkspaceId
    if ([string]::IsNullOrEmpty($activeWorkspaceId)) {
        throw "Failed to get a valid workspace ID"
    }
    
    # Verify folder exists
    if (-not (Test-Path -Path $FolderPath)) {
        throw "Specified folder path does not exist: $FolderPath"
    }

    # Find all PBIP files
    Write-Host "Searching for files in: $FolderPath"
    $files = Find-PbipFiles -Path $FolderPath

    # Check if files were found
    if ($files.SemanticModels.Count -eq 0) {
        Write-Warning "No semantic model folders found in the specified folder"
    }
    if ($files.Reports.Count -eq 0) {
        Write-Warning "No report folders found in the specified folder"
    }

    # Import files to Fabric
    if ($files.SemanticModels.Count -gt 0 -or $files.Reports.Count -gt 0) {
        Write-Host "Found $($files.SemanticModels.Count) semantic models and $($files.Reports.Count) reports"
        Import-FabricItems -WorkspaceId $activeWorkspaceId `
                          -SemanticModels $files.SemanticModels `
                          -Reports $files.Reports
        
        Write-Host "Import completed successfully" -ForegroundColor Green
    } else {
        Write-Host "No files to import" -ForegroundColor Yellow
    }
}
catch {
    Write-Error "Script execution failed: $_"
    exit 1
}
