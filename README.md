# Set-SettingsCatalogPolicies

This repository contains PowerShell automation for exporting, transforming, and importing Microsoft Intune Settings Catalog policies using Microsoft Graph.

## Repository Purpose

The scripts are designed to:
- export Intune Settings Catalog policies from a tenant to JSON files,
- generate new policy JSON files from a reference policy using category-based policy grouping,
- merge multiple policy JSON files into a single consolidated policy,
- import generated or existing policy JSON files back into Intune.

## Files

### PowerShell scripts

- `Export-Policy.ps1`
  - Exports Intune Settings Catalog configuration policies to JSON files.
  - Supports exporting by policy ID or policy name.
  - Uses Azure AD application credentials and Microsoft Graph API.
  - Saves exported policy metadata and settings into JSON files.

- `Generate-PolicyFromReference.ps1`
  - Processes a reference Intune policy JSON file and generates multiple new policy JSON files.
  - Enriches settings with category metadata from Microsoft Graph.
  - Uses a CSV mapping file to assign categories to target policy names.
  - Outputs structured JSON files ready for Intune import.

- `Generate-PolicyMultiplyToOne.ps1`
  - Merges multiple Intune Settings Catalog JSON files into a single policy JSON file.
  - Builds a combined policy with common metadata and all merged settings.
  - Useful for creating consolidated import packages.

- `Import-Policy.ps1`
  - Imports JSON policy files from an input folder into Microsoft Intune via Graph API.
  - Supports optional overwrite of existing policies using `-Override`.
  - Includes a `-RunTests` mode to validate each setting by attempting temporary import.
  - Handles duplicate policy names and can create `_PASS`/`_FAIL` result files for validated settings.

### Data files

- `CategoryToPolicy_mapping.csv`
  - Defines category-to-policy mappings used by `Generate-PolicyFromReference.ps1`.
  - Format: `PolicyName,CategoryName`.
  - Example categories include `Security_ThreatProtection`, `Identity_Authentication_Privilege`, and `UserExperience_Privacy_Connectivity`.

- `SettingsCatalogWindows.json`
  - Contains Intune Settings Catalog metadata definitions for Windows.
  - Used as a lookup reference when enriching and mapping policy settings.
  - Must be exported manually as individual for each tenant.


## Usage

Each script is configured with default parameters that may need adjustment for your tenant. Typical workflow:

1. Export policies from Intune:
   ```powershell
   .\Export-Policy.ps1 -TenantId <TenantId> -ClientId <ClientId> -ClientSecret .\ClientId_...txt -PoliciesName <PolicyName>
   ```

2. Generate policy files from a reference policy:
   ```powershell
   .\Generate-PolicyFromReference.ps1 -InputJSONFile .\Exported_Policies\<ReferencePolicy>.json -CategoryToPolicy_mappingFile .\CategoryToPolicy_mapping.csv
   ```

3. Merge generated policy JSON files into one combined policy:
   ```powershell
   .\Generate-PolicyMultiplyToOne.ps1 -OutputPolicy_Name "_MAIN_TEMPLATE" -InputJSON_Names @('_IDENTITY_ACCESS.json','_SECURITY_PROTECTION.json') -OutputFolder .\output
   ```

4. Import policies into Intune:
   ```powershell
   .\Import-Policy.ps1 -TenantId <TenantId> -ClientId <ClientId> -ClientSecret .\ClientId_...txt -InputFolder .\PoliciesToImport -Override -RunTests
   ```

## Requirements

- PowerShell 5.1 or PowerShell 7+
- Azure AD application with appropriate Microsoft Graph permissions
- Microsoft Graph API access for Intune device management
- Valid Intune Settings Catalog JSON export and settings catalog metadata

## Notes

- The scripts use the Microsoft Graph beta endpoint for Intune configuration policy operations.
- `ClientSecret` is stored in a local text file for authentication; protect it carefully.
- The CSV mapping file is essential for correct category-to-policy assignment when generating split policies.

## Author

- Viktor Kravtsov
