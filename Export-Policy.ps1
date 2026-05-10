<#
.SYNOPSIS
Exports Microsoft Intune Settings Catalog configuration policies to JSON files.

.DESCRIPTION
This script connects to Microsoft Graph using application credentials and exports
Intune Settings Catalog configuration policies by **policy ID or policy name**.
Each policy is retrieved together with all its settings and saved as a JSON file
to the specified output folder.

The script supports two parameter sets:
- Export by Policy ID
- Export by Policy Name

Authentication is performed using client credentials (App Registration).

.PARAMETER ClientId
Azure AD Application (Client) ID used for Microsoft Graph authentication.

.PARAMETER ClientSecret
Path to a file containing the Client Secret for the Azure AD application.

.PARAMETER TenantId
Azure AD Tenant ID where Intune policies are located.

.PARAMETER OutputFolder
Directory where exported policy JSON files will be saved.
If the folder does not exist, it will be created automatically.

.PARAMETER PoliciesID
One or more Intune Settings Catalog policy IDs to export.
Used when the **ById** parameter set is selected.

.PARAMETER PoliciesName
One or more Intune Settings Catalog policy names to export.
Used when the **ByName** parameter set is selected.

.PARAMETER Log
Path to a log file where script execution details will be written.

.OUTPUTS
JSON files containing exported Intune Settings Catalog policies.

.EXAMPLE
Export policies by ID:

.\Export-IntunePolicy.ps1 
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ClientSecret ".\secret.txt" `
    -PoliciesID "c2887999-2ebd-44b7-8220-d28cc42694a6"

.EXAMPLE
Export policies by Name:

.\Export-IntunePolicy.ps1 `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ClientSecret ".\secret.txt" `
    -PoliciesName "MAIN_Reference_Policy"

.NOTES
Author  : Viktor Kravtsov
Version : 1.0
Requires: PowerShell 5.1+ or PowerShell 7+
API     : Microsoft Graph (beta)
Permissions:
- DeviceManagementConfiguration.Read.All (Application)

#>


param(
    [Parameter(Mandatory = $false)][string] $ClientId = 'xxxxxxxxxx-xxxxx-xxxxxxx-xxxxxx',
    [Parameter(Mandatory = $false)][string] $ClientSecret = ".\ClientId_xxxxxxxxxx-xxxxx-xxxxxxx-xxxxxx.txt",
    [Parameter(Mandatory = $false)][string] $TenantId = 'xxxxxxxxxx-xxxxx-xxxxxxx-xxxxxx',
    [Parameter(Mandatory = $false)][string]$OutputFolder = ".\Exported_Policies",
    [Parameter(Mandatory=$false,ParameterSetName = 'ById')][string[]]$PoliciesID = @('xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'),
    [Parameter(Mandatory=$false,ParameterSetName = 'ByName')][string[]]$PoliciesName = @('MAIN_Reference_Policy'),
    [Parameter(Mandatory = $false)][string] $Log = ".\Log\Export-Policy.log"
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

function Get-ConfigPolicy {
param([string]$PolicyName)
    try {
        $Uri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies"
        If (!($global:allPolicies)) {$global:allPolicies = Get-AllGraphPages -Uri $Uri -Headers $headers}
        $match = $allPolicies | Where-Object {$_.Name -eq $PolicyName}
        if (-not $match) {throw "Policy '$PolicyName' not found in Intune tenant."}
        $r = $match | Select-Object id #, displayName
        return $r.id
    } catch {throw "Failed to get policy: $($_.Exception.Message)"}
}

function Export-IntuneConfigurationPolicy {
    param (
        [Parameter(Mandatory=$true,ParameterSetName = 'ById')]        [string]$PolicyId,
        [Parameter(Mandatory=$true,ParameterSetName = 'ByName')]      [string]$PolicyName,
        [Parameter(Mandatory)]                                        [string]$OutputPath
    )
    try {
        switch ($PSCmdlet.ParameterSetName) {
            'ByName' {Write-Log "Getting ID of ($PolicyName) ..."
                      try{$PolicyId = Get-ConfigPolicy -PolicyName $PolicyName}
                      catch{throw "$($_.Exception.Message)"}
            }
        }


        # 1. Get policy metadata
        Write-Log "Getting policy $PolicyId($PolicyName) metadata..."

        try{
            $policy = Invoke-RestMethod `
                -Method GET `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$PolicyId" `
                -Headers $headers `
                -ErrorAction Stop

        }
        catch{
            Write-Log "Failed getting policy $PolicyId($PolicyName) metadata..." -Level WARN
            throw "Failed getting policy $PolicyId($PolicyName) metadata: $($_.Exception.Message)"
        }
                  


        # 2. Get policy settings (paged-safe)
        Write-Log "Getting policy $PolicyId($($policy.name)) settings..."
        $settings = Get-AllGraphPages `
            -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$PolicyId/settings" `
            -Headers $headers
            
        # 3. Build export object
        Write-Log "Build $PolicyId($($policy.name)) export object ..."
        $exportObject = [ordered]@{
            name          = $policy.name
            description   = $policy.description
            platforms     = $policy.platforms
            technologies  = $policy.technologies
            settings      = $settings
        }

        # 4. Save JSON
        Write-Log "Save $PolicyId($PolicyName) JSON..."
        $json = $exportObject | ConvertTo-Json -Depth 100
        $fileName = Join-Path $OutputPath "$($policy.name).json"
        $json | Out-File -Encoding UTF8 -FilePath $fileName
        Write-Log "Exported policy '$($policy.name)' to $fileName" -Level SUCC
        $global:counter++
    }
    catch {Write-Log "ERROR exporting policy: $($_.Exception.Message)" -Level ERROR}
}

#######################################################################################
####################### MAIN  #########################################################
#######################################################################################
$global:allPolicies=$null
$global:counter=0

If (!(Test-Path -LiteralPath $OutputFolder)){New-Item -Path $OutputFolder -ItemType Directory -Force| Out-Null}
$OutputFolder=(Resolve-Path $OutputFolder).Path
$ClientSecret=(Resolve-Path $ClientSecret).Path

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


Write-Log "Export Setting policies started..."
Write-Log "----------------------------------------"
Write-Log "Initializing script with next params..."
Write-Log "-TenantId     = $TenantId" -Level DEBUG
Write-Log "-ClientId     = $ClientId" -Level DEBUG
Write-Log "-ClientSecret = $ClientSecret" -Level DEBUG
Write-Log "-OutputFolder = $OutputFolder" -Level DEBUG
Write-Log "-Log          = $Log" -Level DEBUG
switch ($PSCmdlet.ParameterSetName) {
    'ById' {Write-Log "-Policies     = $PoliciesID" -Level DEBUG}
    'ByName' {Write-Log "-Policies     = $PoliciesName" -Level DEBUG}
}
Write-Log "----------------------------------------"
Write-Log "Processing started..."

try{
    $headers = Get-Headers -ClientId $ClientId -ClientSecret (Get-Content $ClientSecret -Raw).Trim() -TenantId $TenantId

    Write-Log "Connecting to MS GRAPH..."
    switch ($PSCmdlet.ParameterSetName) {
        'ById' {$PoliciesId | Foreach-object {Export-IntuneConfigurationPolicy -PolicyID $_ -OutputPath $OutputFolder}}
        'ByName' {$PoliciesName | Foreach-object {Export-IntuneConfigurationPolicy -PolicyName $_ -OutputPath $OutputFolder}}
    }
    Write-Log "Export completed. $($global:counter) exported policies" -Level INFO;Exit 0
}
catch{Write-Log "$($_.Exception.Message)" -Level ERROR;Exit 100}
