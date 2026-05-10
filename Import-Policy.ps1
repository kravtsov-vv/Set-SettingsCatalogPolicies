<#
.SYNOPSIS
    Intune Settings Catalog Policy Importer via Microsoft Graph API.

.DESCRIPTION
    This script imports Intune configuration policies from JSON files into Microsoft Intune
    using the Microsoft Graph API. It supports validation of individual policy settings,
    optional overwrite of existing policies, and detailed logging.

.PARAMETER ClientId
    Azure AD application (client) ID used for authentication.

.PARAMETER ClientSecret
    Path to file containing the client secret used for authentication.

.PARAMETER TenantId
    Azure AD tenant ID.

.PARAMETER InputFolder
    Directory containing JSON policy files to import.

.PARAMETER Log
    Path to the log file where execution details will be written.

.PARAMETER Override
    If specified, existing policies with the same name will be replaced.

.PARAMETER RunTests
    If specified, each policy setting is validated individually before import.
    Results are split into PASS/FAIL JSON files.

.NOTES
    Author  : Viktor Kravtsov
    Version : 1.0
    Created : 30.04.2026
    Requires: Microsoft Graph API access (DeviceManagementConfiguration.ReadWrite.All)

.EXAMPLE
    .\Import-Policies.ps1 -ClientSecret ".\secret.txt" -RunTests

.EXAMPLE
    .\Import-Policies.ps1 -Override

#>

param(

    [Parameter(Mandatory = $false)][string] $ClientId = 'xxxxxxxxx-xxxxxx-xxxxxxxx-xxxxxxx',
    [Parameter(Mandatory = $false)][string] $ClientSecret = ".\ClientId_xxxxxxxxx-xxxxxx-xxxxxxxx-xxxxxxx.txt",
    [Parameter(Mandatory = $false)][string] $TenantId = 'xxxxxxxxx-xxxxxx-xxxxxxxx-xxxxxxx',
    [Parameter(Mandatory = $false)][string] $InputFolder = ".\PoliciesToImport",
    [Parameter(Mandatory = $false)][string] $Log = ".\Log\Import-Policy.log",
    [Parameter(Mandatory = $false)][switch] $Override,
    [Parameter(Mandatory = $false)][switch] $RunTests
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
# Graph helper
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

#Upload to graph single policy from JSON-file
function Import-PolicyJson {
    param (
        [Parameter(Mandatory)]$JsonPath
    )

    $result = $null
    $jsonObject = $null

    try {
        $jsonObject = Get-Content $JsonPath -Raw
        $NewPolicy = $jsonObject | ConvertFrom-Json
        #$NewPolicyName = $NewPolicy.Name
        $SamePolicyNameFound=$false

        Write-Log "Processing file: $((Get-Item $JsonPath).BaseName)" 
        
        
        if ($NewPolicy.Name -in $existingPolicies.Name){$SamePolicyNameFound=$true}
                    
        if ($SamePolicyNameFound) {
                #get same existing policy
                $SamePolicy = $existingPolicies | Where-Object { $_.Name -eq $NewPolicy.Name } | Select-Object -First 1
                $SamePolicyID = $SamePolicy.Id
                $SamePolicyName = $SamePolicy.Name

            If($Override){Write-Log "Replacing $($SamePolicyName)($SamePolicyID)" "WARN"}
            else{
                $datastamp = Get-Date -Format "yyyyMMdd_HHmmss"
                #$NewPolicyName = "$NewPolicyName`_$datastamp"
                $NewPolicy.Name = "$($NewPolicy.Name)"+"_$datastamp"
                
                Write-Log "Same Policy Name found, New policy name : $($NewPolicy.Name)" "WARN"
             }

        }
        #else{$NewjsonObject = $jsonObject}

        $NewjsonObject = $NewPolicy | ConvertTo-Json -Depth 100
        try{
            $result = Invoke-RestMethod `
            -Method POST `
            -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies" `
            -Headers $headers `
            -Body $NewjsonObject `
            -ContentType "application/json" `
            -ErrorAction Stop
            
            #remove Existing policy with the same name if needed
            If($Override -and $SamePolicyNameFound){Remove-IntunePolicy -PolicyId $SamePolicyID}   
            
            Write-Log "Policy created: $($NewPolicy.Name)" -Level SUCC
            $global:counter++
        }
        catch{throw "Upload policy $($NewPolicy.Name) to MS Graph failed: $($_.Exception.Message)"}


        
    }
    catch {throw "ERROR creating policy: $($_.Exception.Message)"}
    
    return $result
}

function New-CheckPolicyJson {
    param (
        [psobject]$BasePolicy,
        [psobject]$SingleSetting,
        [string]$PolicyName
    )

    $policy = [ordered]@{
        name         = $PolicyName
        description  = "Temporary validation policy"
        platforms    = $BasePolicy.platforms
        technologies = $BasePolicy.technologies
        settings     = @($SingleSetting)
    }

    return ($policy | ConvertTo-Json -Depth 50)
}

function Remove-IntunePolicy {
    param (
        [Parameter(Mandatory)][string]$PolicyId
    )
    try {Invoke-RestMethod -Method DELETE -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$PolicyId" -Headers $Headers -ErrorAction Stop}
    catch {throw "ERROR removing existing policy $PolicyId : $($_.Exception.Message)"}
}

function Test-IntunePolicySettings {
    param (
        [Parameter(Mandatory)][string]$JsonPath
        #[Parameter(Mandatory)][hashtable]$Headers
    )
    $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($JsonPath)
    $basePolicy      = Get-Content $JsonPath -Raw | ConvertFrom-Json
    $policyName      = $basePolicy.name
    $successSettings = @()
    $failedSettings  = @()

    foreach ($setting in $basePolicy.settings) {

        $settingId = $setting.settingInstance.settingDefinitionId
        Write-Host "`n▶ Testing setting: $settingId" -ForegroundColor Cyan

        $checkPolicyName = "CHECK_$($policyName)_$(Get-Random)"

        $checkJson = New-CheckPolicyJson `
            -BasePolicy $basePolicy `
            -SingleSetting $setting `
            -PolicyName $checkPolicyName

        try {
            # CREATE CHECK POLICY
            $createdPolicy = Invoke-RestMethod `
                -Method POST `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies" `
                -Headers $Headers `
                -Body $checkJson `
                -ContentType "application/json" `
                -ErrorAction Stop

            # DELETE CHECK POLICY
            Remove-IntunePolicy -PolicyId $createdPolicy.id
            Write-Host "✔ SUCCESS" -ForegroundColor Green
            $successSettings += $setting
        }
        catch {
            Write-Host "✖ FAILED: $settingId" -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor DarkRed
            $failedSettings += $setting
        }
    }

    # ===== EXPORT RESULTS =====

    $successPolicy = [ordered]@{
        name         = $basePolicy.name
        description  = $basePolicy.description
        platforms    = $basePolicy.platforms
        technologies = $basePolicy.technologies
        settings     = $successSettings
    }

    $failedPolicy = [ordered]@{
        name         = $basePolicy.name
        description  = $basePolicy.description
        platforms    = $basePolicy.platforms
        technologies = $basePolicy.technologies
        settings     = $failedSettings
    }
    
    If ($successSettings.Count -gt 0) {$successPolicy | ConvertTo-Json -Depth 50 | Out-File "$InputFolder\$($BaseName)_PASS.json" -Encoding utf8}
    If ($failedSettings.Count -gt 0) {$failedPolicy | ConvertTo-Json -Depth 50 | Out-File "$InputFolder\$($BaseName)_FAIL.json" -Encoding utf8}

    Write-Host "`n✅ Validation completed" -ForegroundColor Green
    Write-Host "Importable settings : $($successSettings.Count)"
    Write-Host "Failed settings     : $($failedSettings.Count)"
    
    return [pscustomobject]@{
        SuccessCount = $successSettings.Count
        FailedCount  = $failedSettings.Count
    }

}


# Import all JSON files in input folder
function UploadToMSGraph-Policies {
    try{
        Write-Log "Importing all JSON files from $InputFolder..." 
        #$Policies = Get-ChildItem -Path $InputFolder -Filter *.json
        #ForEach ($Policy in $Policies) {        Test-IntunePolicySettings -JsonPath "$($Policy.Fullname)" -Headers $Headers    }

        If($RunTests){
            $Files = Get-ChildItem -Path $InputFolder -Filter *.json
            ForEach ($file in $files) {
                Write-Log "Testing $($file.Fullname) file..."
                $TestResults = Test-IntunePolicySettings -JsonPath "$($file.Fullname)" 
                switch ($true) {
                    {($TestResults.SuccessCount -eq 0) -and($TestResults.FailedCount -eq 0)} {throw "Settings Test result: PASS_$($TestResults.SuccessCount)|FAIL_$($TestResults.FailedCount)"}    
                    {($TestResults.SuccessCount -gt 0) -and($TestResults.FailedCount -eq 0)} {Write-Log "Settings Test result: PASS_$($TestResults.SuccessCount)|FAIL_$($TestResults.FailedCount)" -Level SUCC}
                    {($TestResults.SuccessCount -eq 0) -and($TestResults.FailedCount -gt 0)} {throw "Settings Test result: PASS_$($TestResults.SuccessCount)|FAIL_$($TestResults.FailedCount)"}
                    {($TestResults.SuccessCount -gt 0) -and($TestResults.FailedCount -gt 0)} {Write-Log "Settings Test result: PASS_$($TestResults.SuccessCount)|FAIL_$($TestResults.FailedCount)"-Level WARN}
                    default                                               {throw "Settings Test result: UNDEFINED"}
                }
                If ($TestResults.SuccessCount -gt 0) {$result=$null;$PASS_File = Join-Path $file.DirectoryName "$($file.BaseName)_PASS$($file.Extension)";$result = Import-PolicyJson -JsonPath $PASS_File}
            }
        }
        else {Get-ChildItem -Path $InputFolder -Filter *.json | ForEach-Object {$result=$null;$result = Import-PolicyJson -JsonPath "$($_.Fullname)"}}
    }
    catch{throw "$($_.Exception.Message)"}
}


#######################################################################################
####################### MAIN  #########################################################
#######################################################################################
$global:counter=0

$Override=$true
$RunTests=$true

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
    Write-Log "-TenantId = $TenantId" -Level DEBUG
    Write-Log "-ClientId = $ClientId" -Level DEBUG
    Write-Log "-ClientSecret = $ClientSecret" -Level DEBUG
    Write-Log "-InputFolder = $InputFolder" -Level DEBUG
    Write-Log "-Override = $Override" -Level DEBUG
    Write-Log "-RunTests = $RunTests" -Level DEBUG
    Write-Log "-log = $log" -Level DEBUG
    Write-Log "----------------------------------------"
    Write-Log "Processing started..."
    Write-Log "Importing policies to Intune from JSON files..."

    # Validate authentification
    Write-Log "Validating authentification..."
    if (-not (Test-Path $ClientSecret)) {throw "File with ClientSecret not found: $ClientSecret"}
    $ClientSecret=(Resolve-Path $ClientSecret).Path

    # Validate input files
    Write-Log "Validating Input folder content..."
    if (!(Test-Path $InputFolder)) {throw "Input folder with JSON files not found: $InputFolder"}
    $InputFolder=(Resolve-Path $InputFolder).Path
    $jsonFiles = Get-ChildItem -Path $InputFolder -Filter *.json -File -ErrorAction SilentlyContinue
    if (!($jsonFiles)) {throw "No JSON files in input folder: $InputFolder"}

    #Getting GRAPH API token/headers
    $headers = Get-Headers -ClientId $ClientId -ClientSecret (Get-Content $ClientSecret -Raw).Trim() -TenantId $TenantId

    # Fetch existing configuration policies once
    Write-Log "Fetching existing configuration policies from Intune..."
    $existingPolicies = (Get-AllGraphPages -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies" -Headers $headers) | Select-Object Name,Id
    #$existingPolicies =
    
    
    $result = UploadToMSGraph-Policies
    Write-Log "Import completed. $($global:counter) imported policies" -Level INFO;Exit 0


}
catch{Write-Log "$($_.Exception.Message)" -Level ERROR;Exit 100}
