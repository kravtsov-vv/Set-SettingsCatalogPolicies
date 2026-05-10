<#
.SYNOPSIS
    Generates Intune Settings Catalog policies from a reference policy.

.DESCRIPTION
    This script processes a reference Intune Settings Catalog policy JSON file and splits
    its settings into multiple new policies based on category mappings.

    It enriches each setting with category metadata retrieved from Microsoft Graph and
    matches categories to target policy names using a CSV mapping file. The result is a
    set of structured JSON policy files ready for import into Intune.

.PARAMETER ClientId
    Azure AD application (client) ID used for Microsoft Graph authentication.

.PARAMETER ClientSecret
    Path to a file containing the client secret.

.PARAMETER TenantId
    Azure AD tenant ID.

.PARAMETER InputJSONFile
    Path to the reference policy JSON file (exported from Intune).

.PARAMETER IntuneSettingsCatalog
    Path to the Settings Catalog reference JSON (definitions list exported from Intune).

.PARAMETER OutputFolder
    Directory where generated policy JSON files will be saved.

.PARAMETER CategoryToPolicy_mappingFile
    CSV file containing mapping between category names and target policy names.

.PARAMETER Policy_PrefixName
    Prefix added to all generated policy names.

.PARAMETER Log
    Path to the log file.

.NOTES
    Author  : Viktor Kravtsov
    Version : 1.0
    Created : 30.04.2026

    Requirements:
    - Microsoft Graph API permissions:
        DeviceManagementConfiguration.Read.All
    - Valid exported Intune Settings Catalog JSON
    - Category mapping CSV in format: CategoryName,PolicyName

.FUNCTIONALITY
    - Reads reference policy settings
    - Enriches settings with category information from Graph
    - Resolves full category path hierarchy
    - Maps categories to policy names via CSV
    - Splits settings into multiple grouped policies
    - Generates ready-to-import JSON policy files

.EXAMPLE
    .\Generate-Policies.ps1 `
        -InputJSONFile ".\policy.json" `
        -CategoryToPolicy_mappingFile ".\mapping.csv" `
        -Policy_PrefixName ".Automation_"

#>


param(
    [Parameter(Mandatory = $false)][string] $ClientId = 'xxxxxxxxx-xxxxxx-xxxxxxxx-xxxxxxx',
    [Parameter(Mandatory = $false)][string] $ClientSecret = ".\ClientId_xxxxxxxxx-xxxxxx-xxxxxxxx-xxxxxxx.txt",
    [Parameter(Mandatory = $false)][string] $TenantId = 'xxxxxxxx-xxxxxx-xxxxxxxx-xxxxxxx',
    [Parameter(Mandatory = $false)] [string]$InputJSONFile = '.\Exported_Policies\.AutomationTEST_MAIN_Reference_Policy_4.28.2026_10.14.36_AM.json',
    [Parameter(Mandatory = $false)] [string]$IntuneSettingsCatalog = ".\SettingsCatalogWindows.json",
    [Parameter(Mandatory = $false)] [string]$OutputFolder = ".\PoliciesToImport",
    [Parameter(Mandatory = $false)] [string]$CategoryToPolicy_mappingFile = ".\CategoryToPolicy_mapping.csv",
    [Parameter(Mandatory = $false)] [string]$Policy_PrefixName = ".AutomationTEST_",
    [Parameter(Mandatory = $false)] [string]$Log = ".\Log\Generate-PolicyFromReference.log"
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

# Get Graph API token/headers
function Get-Headers {
param(
    [string]$ClientId,
    [string]$ClientSecret,
    [string]$TenantId
)
    try {
        $Body = @{
            grant_type    = "client_credentials"
            scope         = "https://graph.microsoft.com/.default"
            client_id     = $ClientId
            client_secret = $ClientSecret
        }
        $TokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $Body -ErrorAction Stop
    }catch {throw "Failed to get Graph API token: $($_.Exception.Message)"}
    
    try{
        $token = $TokenResponse.access_token
        $headers = @{
            Authorization  = "Bearer $token"
            "Content-Type" = "application/json"
            }
        Write-Log "Graph API token obtained..." -Level INFO
        return $headers
    }catch {throw "Failed to generate API headers: $($_.Exception.Message)"}
}

function Get-AllGraphPages {
    param (
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers
    )
    $results = @()
    do {
        $response = Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop
        if ($response.value) {$results += $response.value}
        $Uri = $response.'@odata.nextLink'
    }while ($Uri)
    return $results
}

function Assemble-Settings_to_Json {
    param (
        [Parameter(Mandatory = $true)]        [object[]]$Settings,
        [Parameter(Mandatory = $true)]        [System.Collections.IDictionary]$JSON_Header,
        [Parameter(Mandatory = $true)]        [string]$OutputFolder
    )
    
    $JSON_Header.settings = $Settings | Select-Object id, settingInstance
    $OutputFile = Join-Path $OutputFolder "$($JSON_Header.'name').json"
    $JSON_Header | ConvertTo-Json -Depth 50 |Out-File $OutputFile -Encoding utf8
    Write-Log "Generated policy $($JSON_Header.'name') saved to: $OutputFile" -Level SUCC
    return $JSON_Header
}

function Set-JSONHeader {
    param (
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description
    )
    
    $JSON_Header = [ordered]@{
        name         = $Name
        description  = $Description
        platforms    = "windows10"
        technologies = "mdm"
        settings     = @()
    }

    Write-Log "Generated JSON_Header for policy $Name" -Level SUCC
    return $JSON_Header
}

function Get-CategoryPath {
    param (
        [string]$CategoryId,
        [hashtable]$CategoryLookup
    )

    $path = @()
    $currentId = $CategoryId

    while ($currentId -and $CategoryLookup.ContainsKey($currentId)) {

        $cat = $CategoryLookup[$currentId]

        # insert at beginning (so root comes first)
        $path = ,$cat.displayName + $path

        # stop if no parent (root reached)
        if ($cat.parentCategoryId -eq "00000000-0000-0000-0000-000000000000") {
            break
        }

        $currentId = $cat.parentCategoryId
    }

    return ,$path   # ✅ force array
}

function Set-CategoriesForPolicySettings {
    param (
        [string]$InputJSONFile,
        [string]$IntuneSettingsCatalog
    )
    try{
        Write-Log "Loading input-JSON and Intune-Settings-Catalog files..."
        try{
            $policyJson  = Get-Content $InputJSONFile -Raw  -ErrorAction Stop | ConvertFrom-Json
            $catalogJson = Get-Content $IntuneSettingsCatalog -Raw  -ErrorAction Stop| ConvertFrom-Json
        }
        catch{throw "Error loading JSON files: $($_.Exception.Message)"}
        # GET CATEGORY NAMES FROM GRAPH
        Write-Log "Fetching categories from Graph..."
        $categoryLookup = @{}

        $uri = "https://graph.microsoft.com/beta/deviceManagement/configurationCategories"

        $response = Get-AllGraphPages -Uri $uri -Headers $Headers  | Where-Object { $_.platforms -like "*windows10*" }

        foreach ($cat in $response) {
            $categoryLookup[$cat.id] = $cat
        }

        # BUILD DEFINITION LOOKUP
        Write-Log "Building definition lookup..."
        $definitionLookup = @{}

            foreach ($def in $catalogJson) {
                $definitionLookup[$def.id] = $def
            }

        # PROCESS SETTINGS
        Write-Log "Setting Categories For Policy settings..."

        $enrichedSettings = @()

        foreach ($setting in $policyJson.settings) {
            # Extract definitionId safely
            $definitionId = $null
            if ($setting.settingInstance.settingDefinitionId) {
                $definitionId = $setting.settingInstance.settingDefinitionId
            }
            elseif ($setting.settingDefinitionId) {
                $definitionId = $setting.settingDefinitionId
            }

            if (-not $definitionId) {$definitionId = 'definitionId_not_found'}

            if ($definitionLookup.ContainsKey($definitionId)) {
                $def = $definitionLookup[$definitionId]
                $categoryId = $def.categoryId
                $cat = $categoryLookup[$categoryId]

                # CATEGORY PATH 
                $fullPath = @()
                if ($cat) {$fullPath = Get-CategoryPath -CategoryId $categoryId -CategoryLookup $categoryLookup}

                # ENRICH SETTING
                $setting | Add-Member -NotePropertyName "_categoryId" -NotePropertyValue $categoryId -Force
                $setting | Add-Member -NotePropertyName "_categoryName" -NotePropertyValue $cat.displayName -Force
                $setting | Add-Member -NotePropertyName "_fullPath" -NotePropertyValue $fullPath -Force
                $setting | Add-Member -NotePropertyName "_maincategory" -NotePropertyValue 'UNDEFINE' -Force
                $setting | Add-Member -NotePropertyName "_toapply" -NotePropertyValue $true -Force
                $enrichedSettings += $setting
            }
            else{write-log " No definition found ($($definitionId))" -Level WARN}
        }
        return $enrichedSettings
    }catch{throw $($_.Exception.Message)}
}


#######################################################################################
####################### MAIN  #########################################################
#######################################################################################

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
    Write-Log "-------------------------------------------------" 
    Write-Log "Initializing script with next params:" 
    Write-Log "-ClientId =                       $ClientId" -Level DEBUG
    Write-Log "-ClientSecret =                   $ClientSecret" -Level DEBUG
    Write-Log "-TenantId =                       $TenantId" -Level DEBUG
    Write-Log "-InputJSONFile =                  $InputJSONFile" -Level DEBUG
    Write-Log "-IntuneSettingsCatalog =          $IntuneSettingsCatalog" -Level DEBUG
    Write-Log "-OutputFolder =                   $OutputFolder" -Level DEBUG
    Write-Log "-CategoryToPolicy_mappingFile =   $CategoryToPolicy_mappingFile" -Level DEBUG
    Write-Log "-Policy_PrefixName =              $Policy_PrefixName" -Level DEBUG
    Write-Log "-Log =                            $Log" -Level DEBUG
    Write-Log "-------------------------------------------------" 
    Write-Log "Processing started..."


    $OutputFolder=(Resolve-Path $OutputFolder).Path
    $IntuneSettingsCatalog=(Resolve-Path $IntuneSettingsCatalog).Path
    $headers = Get-Headers -ClientId $ClientId -ClientSecret (Get-Content $ClientSecret -Raw).Trim() -TenantId $TenantId


    ##1.1 Read settings from reference policy
    ##1.2. Get Categories info from SettingsCatalog for each setting
    ##1.3. Add categories definitions to settings

    $Categorized_Settings = Set-CategoriesForPolicySettings -InputJSONFile $InputJSONFile -IntuneSettingsCatalog $IntuneSettingsCatalog

    ##2. Split/filter settings by desired params
    $csv = Import-Csv $CategoryToPolicy_mappingFile

    # Build lookup: category -> policy
    $categoryToPolicy = @{}
    foreach ($row in $csv) {
        $category = $row.CategoryName.Trim()
        $policy   = $row.PolicyName.Trim()
        if (-not $categoryToPolicy.ContainsKey($category)) {$categoryToPolicy[$category] = $policy}
    }


    # ASSIGN _maincategory
    Write-Log "Assign main categories to each setting..."
    foreach ($setting in $Categorized_Settings) {
        $assigned = $false
        foreach ($cat in ($setting._fullPath | Select-Object -First 1)) {
            if ($categoryToPolicy.ContainsKey($cat)) {
                $setting._maincategory = $categoryToPolicy[$cat]
                $assigned = $true
                break
            }
        }
    }


    # split ADMINISTRATIVE TEMPLATES and customize categorization manually
    #$Categorized_Settings | ForEach-Object {If(($_._fullPath | Select-Object -First 1) -eq "Administrative Templates"){$_._maincategory = ($_._categoryName).replace(' ','_')}}
    #$Categorized_Settings | ForEach-Object {If(($_._fullPath | Select-Object -First 1) -eq "Administrative Templates"){$_._maincategory = ($_._fullPath | Select-Object -Skip 1 -First 1).replace(' ','_')}}

    
    foreach ($setting in $Categorized_Settings) {
        $TopCat = $setting._fullPath | Select-Object -First 1
        $Lev2Cat = $setting._fullPath | Select-Object -Skip 1 -First 1
        If ($TopCat -eq "Administrative Templates"){
            switch ($true) {
            <#
            MS Security Guide       --> SecurityHardening_ThreatProtection 
            MSS (Legacy)            --> SecurityHardening_MSS_(Legacy)
            Network                 --> NetworkHardening 
            Printers                --> PrintersHardening 
            Start Menu and Taskbar  --> UserExperience_Privacy_Connectivity 
            System                  --> CoreOS_Manageability_Servicing 
            Windows Components      --> CoreOS_Manageability_Servicing 
#>

                {($Lev2Cat -eq "MS Security Guide") }      {$setting._maincategory = "Security_ThreatProtection"}
                {($Lev2Cat -eq "MSS (Legacy)") }           {$setting._maincategory = "Security_MSS_Legacy"}
                {($Lev2Cat -eq "Network") }                {$setting._maincategory = "Network"}
                {($Lev2Cat -eq "Printers") }               {$setting._maincategory = "Printer"}
                {($Lev2Cat -eq "Start Menu and Taskbar") } {$setting._maincategory = "UserExperience_Privacy_Connectivity"}
                {($Lev2Cat -eq "System") }                 {$setting._maincategory = "CoreOS_Manageability_Servicing"}
                {($Lev2Cat -eq "Windows Components") }     {$setting._maincategory = "CoreOS_Manageability_Servicing"}
                default {Write-Log "customize categorization manually UNDEFINED" -Level ERROR}
            }
        }
    }



    # FILTER/GROUP SETTINGS (_toapply = true)
    Write-Log "Filter/group settings..."
    $filteredSettings = $Categorized_Settings | Where-Object {$_._toapply -eq $true} # -and $_._maincategory -ne "UNDEFINED"
    $splits = $filteredSettings | Group-Object -Property _maincategory

    ##3. Foreach split:
    ##3.1. generate Header for new policy
    ##3.2 Add filtered settings to new policy
    Write-Log "Generate JSON-files by category..."
    foreach ($split in $splits) {
        $settings = $split.Group
        $Desc = "This hardening policy include next categories: " + (($settings._categoryName | Select-Object -Unique | Sort-Object) -join ", ")
        $JSON_Header = Set-JSONHeader -Name "$Policy_PrefixName$($split.Name)" -Description $Desc
        $NewJSON = Assemble-Settings_to_Json -Settings $settings -JSON_Header $JSON_Header -OutputFolder $OutputFolder
    }
    Write-log "Generation Policies from Reference finished."
}
catch{Write-Log "Failed: $($_.Exception.Message)" -Level ERROR;Exit 100}

