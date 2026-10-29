#Requires -Version 5.1
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
Assigns one existing Windows Server 2016 ESU license to Arc machine names in a CSV.
.DESCRIPTION
AuthenticationMode ExistingContext (default) uses your current Azure sign-in.
Interactive signs in a person; ServicePrincipal signs in unattended using a
TenantId, ClientId, and SecureString ClientSecret supplied by your secret store.
The CSV requires a MachineName column containing Azure Arc resource names.
CsvPath defaults to ..\examples\machine-names.csv relative to this script.
Interactive authentication prompts for the CSV path when CsvPath is omitted;
press Enter to accept the displayed default. Other modes never prompt for it.
Custom relative paths use the current working directory. Matching surrounding
single or double quotes pasted into a path value are removed.
All machines must be in ResourceGroupName. LicenseResourceGroupName defaults to it.
This script is self-contained; no companion scripts or modules beyond Az.Accounts are needed.
Stops on the first failure; earlier assignments are not rolled back.
Displays the selected Azure identity and checks caller permissions for all
targets before submitting any assignments, including during -WhatIf.
.EXAMPLE
.\WS2016_ESU_License_CSV.ps1 -SubscriptionId '<guid>' -ResourceGroupName 'ArcDemoLab' -EsuLicenseName 'WS2016ESUDemo' -WhatIf
.EXAMPLE
.\WS2016_ESU_License_CSV.ps1 -SubscriptionId '<guid>' -ResourceGroupName 'ArcDemoLab' -EsuLicenseName 'WS2016ESUDemo' -AuthenticationMode Interactive -TenantId '<tenant-guid>'
.EXAMPLE
.\WS2016_ESU_License_CSV.ps1 -SubscriptionId '<guid>' -ResourceGroupName 'ArcDemoLab' -EsuLicenseName 'WS2016ESUDemo' -AuthenticationMode ServicePrincipal -TenantId '<tenant-guid>' -ClientId '<application-guid>' -ClientSecret $secret -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$CsvPath,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[\w().-]+$')][string]$ResourceGroupName,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_.-]+$')][string]$EsuLicenseName,
    [ValidatePattern('^[\w().-]+$')][string]$LicenseResourceGroupName,
    [switch]$ReplaceExisting,
    [ValidateSet('ExistingContext', 'Interactive', 'ServicePrincipal')]
    [string]$AuthenticationMode = 'ExistingContext',
    [guid]$TenantId,
    [guid]$ClientId,
    [System.Security.SecureString]$ClientSecret
)

$ErrorActionPreference = 'Stop'
if (-not $PSBoundParameters.ContainsKey('CsvPath')) {
    $CsvPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\examples\machine-names.csv'))
}
if ($AuthenticationMode -eq 'ExistingContext') {
    if ($PSBoundParameters.ContainsKey('TenantId') -or
        $PSBoundParameters.ContainsKey('ClientId') -or
        $PSBoundParameters.ContainsKey('ClientSecret')) {
        throw 'ExistingContext uses the current sign-in. Choose Interactive or ServicePrincipal when supplying authentication parameters.'
    }
}
else {
    if (-not $TenantId -or $TenantId -eq [guid]::Empty) {
        throw "TenantId is required for $AuthenticationMode authentication."
    }
    if ($AuthenticationMode -eq 'ServicePrincipal') {
        if (-not $ClientId -or $ClientId -eq [guid]::Empty -or
            -not $ClientSecret -or $ClientSecret.Length -eq 0) {
            throw 'ServicePrincipal requires ClientId and a nonempty SecureString ClientSecret. Supply them from your automation secret store; no interactive prompt is used.'
        }
    }
    elseif ($PSBoundParameters.ContainsKey('ClientId') -or $PSBoundParameters.ContainsKey('ClientSecret')) {
        throw 'Interactive authentication does not accept ClientId or ClientSecret. Choose ServicePrincipal for unattended execution.'
    }
}
if ($AuthenticationMode -eq 'Interactive' -and -not $PSBoundParameters.ContainsKey('CsvPath')) {
    $enteredPath = Read-Host "CSV path [$CsvPath] (press Enter to accept)"
    if (-not [string]::IsNullOrWhiteSpace($enteredPath)) {
        $CsvPath = $enteredPath
    }
}
function Get-ArcEsuContext {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context -or -not $context.Account -or -not $context.Subscription) {
        throw 'Sign in with Connect-AzAccount and select a subscription with Set-AzContext first.'
    }
    if ($context.Environment.Name -ne 'AzureCloud') {
        throw 'These samples support Azure public cloud (AzureCloud) only.'
    }
    return $context
}

function Assert-ArcEsuResourceId {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][ValidateSet('machines', 'licenses')][string]$ResourceType,
        [Parameter(Mandatory)]$Context
    )

    $pattern = '^/subscriptions/(?<subscription>[0-9a-fA-F-]{36})/resourceGroups/[\w().-]+/providers/Microsoft\.HybridCompute/' +
        $ResourceType + '/[a-zA-Z0-9_.-]+$'
    if ($ResourceId -notmatch $pattern) {
        throw "Expected a full Microsoft.HybridCompute/$ResourceType resource ID, without a trailing slash: $ResourceId"
    }
    $subscription = $Matches.subscription
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($subscription, [ref]$parsed)) {
        throw "Invalid subscription ID in $ResourceId"
    }
    if ($subscription -ne $Context.Subscription.Id) {
        throw "Resource subscription $subscription does not match the selected subscription $($Context.Subscription.Id). Select the intended subscription first."
    }
}

function Invoke-ArcEsuRequest {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT', 'PATCH')][string]$Method,
        [Parameter(Mandatory)]$Context,
        [hashtable]$Body,
        [switch]$AllowNotFound,
        [string]$ApiVersion = '2023-06-20-preview'
    )

    $parameters = @{
        Path = if ($ResourceId.Contains('?')) { $ResourceId } else { "${ResourceId}?api-version=$ApiVersion" }
        Method = $Method
        DefaultProfile = $Context
        ErrorAction = 'Stop'
        WhatIf = $false
        Confirm = $false
    }
    if ($Body) {
        $parameters.Payload = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    try {
        $response = Invoke-AzRestMethod @parameters
    }
    catch {
        if ($AllowNotFound -and $_.Exception.Response -and
            [int]$_.Exception.Response.StatusCode -eq 404) {
            return $null
        }
        throw
    }
    if ($AllowNotFound -and [int]$response.StatusCode -eq 404) {
        return $null
    }
    if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
        throw "ARM $Method $ResourceId failed (HTTP $($response.StatusCode)): $($response.Content)"
    }
    if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
        return ($response.Content | ConvertFrom-Json -ErrorAction Stop)
    }
}

function Assert-ArcEsuPermission {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string[]]$Actions,
        [Parameter(Mandatory)]$Context
    )

    $path = "$ResourceId/providers/Microsoft.Authorization/permissions"
    $permissions = @()
    $visited = @{}
    do {
        if ($visited.ContainsKey($path)) {
            throw "Permission preflight received a repeated pagination link for $ResourceId. No assignments were submitted."
        }
        $visited[$path] = $true
        try {
            $page = Invoke-ArcEsuRequest -ResourceId $path -Method GET -Context $Context -ApiVersion '2022-04-01'
        }
        catch {
            throw "Unable to verify caller permissions for '$ResourceId': $($_.Exception.Message) No assignments were submitted. Permission inspection failed; this does not by itself prove the ESU action is denied."
        }
        if (-not $page -or 'value' -notin $page.PSObject.Properties.Name) {
            throw "Permission preflight returned an invalid response for $ResourceId. No assignments were submitted."
        }
        $permissions += @($page.value)
        $path = $null
        if ($page.nextLink) {
            $next = $null
            if (-not [uri]::TryCreate($page.nextLink, [UriKind]::Absolute, [ref]$next) -or
                $next.Scheme -ne 'https' -or $next.Host -ne 'management.azure.com' -or
                -not $next.IsDefaultPort -or $next.UserInfo -or $next.Fragment -or
                $next.AbsolutePath -ine "$ResourceId/providers/Microsoft.Authorization/permissions") {
                throw "Permission preflight returned an unexpected pagination URL for $ResourceId. No assignments were submitted."
            }
            $path = $next.PathAndQuery
        }
    } while ($path)

    foreach ($action in $Actions) {
        $allowed = $false
        foreach ($permission in $permissions) {
            $included = @($permission.actions | Where-Object { $action -like $_ }).Count -gt 0
            $excluded = @($permission.notActions | Where-Object { $action -like $_ }).Count -gt 0
            # NotActions subtracts from this grant, not from other role grants.
            if ($included -and -not $excluded) {
                $allowed = $true
                break
            }
        }
        if (-not $allowed) {
            throw "RBAC preflight: account '$($Context.Account.Id)' (type '$($Context.Account.Type)', tenant '$($Context.Tenant.Id)') lacks '$action' at '$ResourceId'. No assignments were submitted. Use -AuthenticationMode ServicePrincipal with your authorized application, or have an administrator grant Azure Connected Machine Resource Administrator at the appropriate scope and refresh your sign-in."
        }
    }
}

function Get-ArcEsuSummary {
    param(
        [Parameter(Mandatory)]$Machine,
        $Profile,
        [Parameter(Mandatory)][string]$Operation
    )

    [pscustomobject]@{
        MachineResourceId = $Machine.id
        MachineName = $Machine.name
        Location = $Machine.location
        ArcStatus = $Machine.properties.status
        OSName = $Machine.properties.osName
        OSSku = $Machine.properties.osSku
        AgentVersion = $Machine.properties.agentVersion
        AssignedLicense = $Profile.properties.esuProfile.assignedLicense
        EsuEligibility = $Profile.properties.esuProfile.esuEligibility
        EsuKeyState = $Profile.properties.esuProfile.esuKeyState
        Operation = $Operation
    }
}

function Set-ArcWs2016EsuLicense {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$MachineResourceId,
        [ValidateSet('Link', 'Unlink')][string]$Action = 'Link',
        [string]$LicenseResourceId,
        [Parameter(Mandatory)]$Context,
        [switch]$ReplaceExisting,
        [ValidateRange(1, 120)][int]$VerificationAttempts = 12,
        [ValidateRange(1, 60)][int]$VerificationDelaySeconds = 5
    )

    if ($Action -eq 'Link' -and [string]::IsNullOrWhiteSpace($LicenseResourceId)) {
        throw 'LicenseResourceId is required for Link.'
    }
    if ($Action -eq 'Unlink' -and ($LicenseResourceId -or $ReplaceExisting)) {
        throw 'Do not supply LicenseResourceId or ReplaceExisting for Unlink.'
    }
    $context = $Context
    Assert-ArcEsuResourceId -ResourceId $MachineResourceId -ResourceType machines -Context $context
    if ($Action -eq 'Link') {
        Assert-ArcEsuResourceId -ResourceId $LicenseResourceId -ResourceType licenses -Context $context
    }
    $machine = Invoke-ArcEsuRequest -ResourceId $MachineResourceId -Method GET -Context $context
    if (-not $machine.location) {
        throw 'The machine response has no location; no changes were made.'
    }
    $profileId = "$MachineResourceId/licenseProfiles/default"
    $profile = Invoke-ArcEsuRequest -ResourceId $profileId -Method GET -Context $context -AllowNotFound
    $assignedLicense = $profile.properties.esuProfile.assignedLicense

    if ($Action -eq 'Link') {
        $osDescription = "$($machine.properties.osSku) $($machine.properties.osName)"
        if ($osDescription -notmatch '\bWindows Server 2016\b') {
            throw "Expected Windows Server 2016; Arc reports '$osDescription'."
        }
        if ($machine.properties.status -ne 'Connected') {
            throw "Arc machine is '$($machine.properties.status)', not Connected. Restore connectivity first."
        }
        $agentVersion = $null
        if (-not [version]::TryParse([string]$machine.properties.agentVersion, [ref]$agentVersion) -or
            $agentVersion -lt [version]'1.62') {
            throw "Windows Server 2016 ESUs require Arc agent 1.62 or later; Arc reports '$($machine.properties.agentVersion)'."
        }
        $license = Invoke-ArcEsuRequest -ResourceId $LicenseResourceId -Method GET -Context $context
        if ($license.properties.licenseDetails.target -ne 'Windows Server 2016' -or
            $license.properties.licenseType -ne 'ESU') {
            throw 'The selected license must be an ESU license targeting Windows Server 2016.'
        }
        if ($license.properties.licenseDetails.state -ne 'Activated') {
            throw 'The selected ESU license is not Activated. Review billing and activate it separately.'
        }
        if ($profile.properties.esuProfile.esuEligibility -eq 'Ineligible') {
            throw 'Azure reports that this machine is ineligible for ESUs. Review eligibility in Azure Arc.'
        }
        if ($assignedLicense -eq $LicenseResourceId) {
            Get-ArcEsuSummary -Machine $machine -Profile $profile -Operation 'AlreadyLinked'
            return
        }
        if ($assignedLicense -and -not $ReplaceExisting) {
            throw "Machine is already linked to $assignedLicense. Review it and use -ReplaceExisting to change the assignment."
        }
    }
    elseif (-not $assignedLicense) {
        Get-ArcEsuSummary -Machine $machine -Profile $profile -Operation 'AlreadyUnlinked'
        return
    }

    $method = 'PUT'
    $apiVersion = '2023-06-20-preview'
    if ($Action -eq 'Link' -and $profile) {
        # PATCH changes only the ESU assignment and leaves unrelated settings alone.
        $method = 'PATCH'
        $apiVersion = '2026-09-01'
    }
    elseif ($profile.properties.productProfile -or $profile.properties.softwareAssurance -or
        ($profile.tags -and @($profile.tags.PSObject.Properties).Count -gt 0)) {
        throw 'Unlink would require a PUT on a profile with non-ESU settings or tags. Unlink this shared profile in the Azure portal instead.'
    }
    $esuProfile = @{}
    if ($Action -eq 'Link') {
        $esuProfile.assignedLicense = $LicenseResourceId
    }
    $body = @{ properties = @{ esuProfile = $esuProfile } }
    if ($method -eq 'PUT') {
        $body.location = $machine.location
    }
    if (-not $PSCmdlet.ShouldProcess($MachineResourceId, "$Action ESU license assignment")) {
        return
    }
    $null = Invoke-ArcEsuRequest -ResourceId $profileId -Method $method -ApiVersion $apiVersion -Context $context -Body $body

    for ($attempt = 1; $attempt -le $VerificationAttempts; $attempt++) {
        $profile = Invoke-ArcEsuRequest -ResourceId $profileId -Method GET -Context $context -AllowNotFound
        $actual = $profile.properties.esuProfile.assignedLicense
        if (($Action -eq 'Link' -and $actual -eq $LicenseResourceId) -or
            ($Action -eq 'Unlink' -and -not $actual)) {
            $operation = if ($Action -eq 'Link') { 'Linked' } else { 'Unlinked' }
            Get-ArcEsuSummary -Machine $machine -Profile $profile -Operation $operation
            return
        }
        if ($attempt -lt $VerificationAttempts) {
            Start-Sleep -Seconds $VerificationDelaySeconds
        }
    }
    throw "The $Action request was submitted, but the expected assignment was not observed after $VerificationAttempts reads. Inspect Azure before retrying; guest activation and patch installation were not verified."
}

$CsvPath = $CsvPath.Trim()
if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    throw 'CsvPath must not be blank. Omit it to use examples\machine-names.csv.'
}
$quoteCharacters = @('"', "'")
if ($CsvPath.Substring(0, 1) -in $quoteCharacters -or
    $CsvPath.Substring($CsvPath.Length - 1, 1) -in $quoteCharacters) {
    if ($CsvPath.Length -lt 3 -or $CsvPath.Substring(0, 1) -notin $quoteCharacters -or
        $CsvPath.Substring(0, 1) -ne $CsvPath.Substring($CsvPath.Length - 1, 1)) {
        throw 'CsvPath has unmatched surrounding quotes. Supply a path without literal quotes, or use one matching pair.'
    }
    $CsvPath = $CsvPath.Substring(1, $CsvPath.Length - 2).Trim()
    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        throw 'CsvPath must not be blank. Omit it to use examples\machine-names.csv.'
    }
}
if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
    throw "CSV file not found: $CsvPath"
}
$CsvPath = (Resolve-Path -LiteralPath $CsvPath -ErrorAction Stop).ProviderPath
Write-Host "CSV input: $CsvPath"
$rows = @(Import-Csv -LiteralPath $CsvPath -ErrorAction Stop)
if ($rows.Count -eq 0) {
    throw 'The CSV must contain at least one machine and a MachineName column.'
}
if ('MachineName' -notin $rows[0].PSObject.Properties.Name) {
    throw 'The CSV must contain a MachineName column.'
}

$machineNames = @()
$seen = @{}
for ($index = 0; $index -lt $rows.Count; $index++) {
    $name = ([string]$rows[$index].MachineName).Trim()
    if ($name -notmatch '^[a-zA-Z0-9_.-]+$') {
        throw "CSV data row $($index + 1) has a blank or invalid MachineName. Use the Azure Arc resource name, not a resource ID."
    }
    if ($seen.ContainsKey($name)) {
        throw "Duplicate MachineName '$name' in CSV data row $($index + 1). Remove duplicate names before running."
    }
    $seen[$name] = $true
    $machineNames += $name
}

if ($AuthenticationMode -ne 'ExistingContext') {
    # Authentication is needed for preflight reads even during a WhatIf preview.
    $null = Disable-AzContextAutosave -Scope Process -WhatIf:$false -Confirm:$false -ErrorAction Stop
    $loginParameters = @{
        Tenant = $TenantId.ToString()
        Subscription = $SubscriptionId.ToString()
        Environment = 'AzureCloud'
        Scope = 'Process'
        WhatIf = $false
        Confirm = $false
        ErrorAction = 'Stop'
    }
    if ($AuthenticationMode -eq 'ServicePrincipal') {
        $loginParameters.ServicePrincipal = $true
        $loginParameters.Credential = [pscredential]::new($ClientId.ToString(), $ClientSecret)
    }
    $null = Connect-AzAccount @loginParameters
}

if (-not $LicenseResourceGroupName) {
    $LicenseResourceGroupName = $ResourceGroupName
}
$licenseId = "/subscriptions/$SubscriptionId/resourceGroups/$LicenseResourceGroupName/providers/Microsoft.HybridCompute/licenses/$EsuLicenseName"
$context = Get-ArcEsuContext
Assert-ArcEsuResourceId -ResourceId $licenseId -ResourceType licenses -Context $context
Write-Host "Azure identity: $($context.Account.Id) | Type: $($context.Account.Type) | Tenant: $($context.Tenant.Id) | Subscription: $($context.Subscription.Id) | Mode: $AuthenticationMode"

Assert-ArcEsuPermission -ResourceId $licenseId -Actions 'Microsoft.HybridCompute/licenses/read' -Context $context
$null = Invoke-ArcEsuRequest -ResourceId $licenseId -Method GET -Context $context
foreach ($name in $machineNames) {
    $machineId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.HybridCompute/machines/$name"
    Assert-ArcEsuPermission -ResourceId $machineId -Actions 'Microsoft.HybridCompute/machines/read' -Context $context
    Assert-ArcEsuPermission -ResourceId "$machineId/licenseProfiles/default" -Actions @(
        'Microsoft.HybridCompute/machines/licenseProfiles/read'
        'Microsoft.HybridCompute/machines/licenseProfiles/write'
    ) -Context $context
    $null = Invoke-ArcEsuRequest -ResourceId $machineId -Method GET -Context $context
    $null = Invoke-ArcEsuRequest -ResourceId "$machineId/licenseProfiles/default" -Method GET -Context $context -AllowNotFound
}
Write-Host "Permission preflight passed for $($machineNames.Count) machine(s). Azure still enforces authorization on each assignment."

foreach ($name in $machineNames) {
    $parameters = @{
        MachineResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.HybridCompute/machines/$name"
        LicenseResourceId = $licenseId
        Context = $context
        ReplaceExisting = $ReplaceExisting
        WhatIf = [bool]$WhatIfPreference
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Confirm')) {
        $parameters.Confirm = $PSBoundParameters['Confirm']
    }
    Write-Verbose "Assigning $EsuLicenseName to $name."
    try {
        Set-ArcWs2016EsuLicense @parameters
    }
    catch {
        throw "Assignment stopped at machine '$name': $($_.Exception.Message) Earlier assignments were not rolled back."
    }
}
