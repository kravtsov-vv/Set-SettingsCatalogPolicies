<#
.SYNOPSIS
    Builds a single Intune Settings Catalog policy JSON by merging multiple
    Settings Catalog policy JSON files.

.DESCRIPTION
    This script reads multiple Intune Settings Catalog JSON files from an
    output directory, extracts their `settings` nodes, and assembles them
    into a single consolidated policy JSON file.

    The generated policy includes a common metadata header (name, description,
    platforms, technologies) and combines all settings into one policy
    suitable for import or further automation.

    The script provides structured logging with colored output and basic
    validation to ensure source JSON files exist before processing.

.PARAMETER OutputPolicy_Name
    The name of the resulting Intune Settings Catalog policy.
    This value is used both inside the JSON (`name`) and as the output file name.

.PARAMETER InputJSON_Names
    An array of JSON file names (located in the output folder) whose
    `settings` sections will be merged into the final policy.

.PARAMETER IntuneSettingsCatalog
    Path to the Intune Settings Catalog definition file.
    This parameter is currently reserved for future use.

.PARAMETER OutputFolder
    Directory containing the input JSON files and where the merged
    policy JSON will be saved.

.OUTPUTS
    System.Collections.IDictionary

    Returns the assembled policy object, including header metadata
    and merged settings.

.EXAMPLE
    .\Generate-PolicyJSON.ps1 -OutputPolicy_Name "MAIN_TEMPLATE" -InputJSON_Names @('IDENTITY_ACCESS.json','SECURITY_PROTECTION.json') -OutputFolder ".\output"

    Generates a merged Intune Settings Catalog policy JSON
    named `MAIN_TEMPLATE.json`.

.NOTES
    Author  : Viktor Kravtsov
    Purpose : Intune Settings Catalog policy automation
    Version : 2.0
    Date    : 2026-04-24

    Requires:
    - PowerShell 5.1 or later
    - Valid Intune Settings Catalog JSON input files

#>


param(
    [Parameter(Mandatory = $false)] [string]$OutputPolicy_Name,
    [Parameter(Mandatory = $false)] [string[]]$InputJSON_Names,
    [Parameter(Mandatory = $false)] [string]$IntuneSettingsCatalog = ".\SettingsCatalogWindows.json",
    [Parameter(Mandatory = $false)] [string]$OutputFolder = ".\output",
    [Parameter(Mandatory = $false)] [string]$Log = ".\Log\Generate-PolicyJSON.log"

)

# Log helper
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('SUCC','INFO','WARN','ERROR','DEBUG')] [string]$Level = "INFO"
    )
    
    $colorMap = @{
        SUCC  = 'Green'
        INFO  = 'Cyan'
        WARN  = 'Yellow'
        ERROR = 'Red'
        DEBUG = 'Gray'
    }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color     = $colorMap[$Level]
    $msg = "[$timestamp] [$Level] $Message"
    
    Write-Host $msg -ForegroundColor $color    
    if (-not [string]::IsNullOrWhiteSpace($Log)) {Add-Content -Path $Log -Value $msg}
}

function Get-Settings {
    param ([Parameter(Mandatory = $true)] [string[]]$Files)

    $JoinedSettings = @()
    $JSON_Paths = $Files | ForEach-Object {Join-Path -Path $OutputFolder -ChildPath $_}

    foreach ($JSON_Path in $JSON_Paths) {
        Write-Log "Read settings from: $JSON_Path"
        if (!(Test-Path $JSON_Path)) {Write-Log "File not found: $JSON_Path" -Level WARN;continue}
        $JoinedSettings += (Get-Content $JSON_Path -Raw | ConvertFrom-Json).settings
    }
    return $JoinedSettings
}


function Assemble-Settings_to_Json {
    param (
        [Parameter(Mandatory = $true)]        [object[]]$Settings,
        [Parameter(Mandatory = $true)]        [System.Collections.IDictionary]$JSON_Header,
        [Parameter(Mandatory = $true)]        [string]$OutputFolder
    )
    
    $JSON_Header.settings = $Settings
    $OutputFile = Join-Path $OutputFolder "$($JSON_Header.'name').json"
    $JSON_Header | ConvertTo-Json -Depth 50 |Out-File $OutputFile -Encoding utf8
    Write-Log "Generated policy saved to: $OutputFile" -Level SUCC
    return $JSON_Header
}

#######################################################################################
####################### MAIN  #########################################################
#######################################################################################

$OutputPolicy_Name        = "MAIN_TEMPLATE"
$InputJSON_Names = @(
'IDENTITY_ACCESS.json'
'NOT_DEFINED.json'
'SECURITY_PROTECTION.json'
'SYSTEM_HARDENING.json'
'USER_EXPERIENCE.json'
)

$OutputFolder=(Resolve-Path $OutputFolder).Path
$IntuneSettingsCatalog=(Resolve-Path $IntuneSettingsCatalog).Path

#Set logging files
If (-not [string]::IsNullOrWhiteSpace($Log)) {
    $DirectoryPath = Split-Path $Log -Parent
    New-Item -Path $DirectoryPath -ItemType Directory -Force| Out-Null
    $FileName = [System.IO.Path]::GetFileNameWithoutExtension($Log)
    $FileExtension = [System.IO.Path]::GetExtension($Log)
    $Log_old = Join-Path $DirectoryPath ($FileName + '_old' + $FileExtension)
    If (Test-Path -LiteralPath $Log) {
        $Size = [math]::round(((Get-Item $Log).Length) / 1MB, 5)
        If ($Size -gt 50.0) { Move-Item -Path $Log -Destination $Log_old -Force -ErrorAction Stop }
    }
}



try{
    Write-Log "Intune Settings Catalog Policy Builder started..." 
    Write-Log "----------------------------------------" 
    Write-Log "Initializing script with next params..." 
    Write-Log "-IntuneSettingsCatalog = $IntuneSettingsCatalog" -Level DEBUG
    Write-Log "-OutputFolder = $OutputFolder" -Level DEBUG
    Write-Log "-OutputPolicy_Name = $OutputPolicy_Name" -Level DEBUG
    Write-Log "-InputJSON_Names = $InputJSON_Names" -Level DEBUG
    Write-Log "----------------------------------------"
    Write-Log "Processing started..."

    $JSON_Header = [ordered]@{
        name         = $OutputPolicy_Name
        description  = "JoinedPolicy"
        platforms    = "windows10"
        technologies = "mdm"
        settings     = @()
    }

    $JoinedSettings = Get-Settings -Files $InputJSON_Names
    $NewJSON = Assemble-Settings_to_Json -Settings $JoinedSettings -JSON_Header $JSON_Header -OutputFolder $OutputFolder
    Write-log "Intune Settings Catalog Policy Builder finished."
    return $NewJSON
}
catch{Write-Log "Failed: $($_.Exception.Message)" -Level ERROR;Exit 100}

 