<#
.SYNOPSIS
    Azure API Management (APIM) credential inventory and subscription key rotation toolkit.

.DESCRIPTION
    Menu-driven (or non-interactive) script that helps you find and rotate credentials in an
    Azure API Management instance.

      INVENTORY
        1  Subscription keys
        2  Named values that hold secrets
        3  Backend credentials (headers, query parameters, authorization, client certificates)
        4  OAuth 2.0 / OpenID Connect client secrets (plus credential manager providers)
        5  Logger credentials and connection strings (Event Hubs, Application Insights)
        6  Full credential report (runs 1-5)

      ROTATION
        7  Regenerate PRIMARY subscription keys
        8  Regenerate SECONDARY subscription keys

    Secret VALUES are never printed or written to disk. The inventories report WHERE each
    credential lives (Key Vault, named value, literal value, managed identity) so you can plan
    rotation. Every result is exported to CSV in a time-stamped report folder with a run log.

    Works in Azure Cloud Shell (PowerShell) and locally with PowerShell 5.1 or 7+ and the
    Az.Accounts module.

.PARAMETER SubscriptionId
    Azure subscription that holds the APIM instance. Defaults to the current Az context.

.PARAMETER ResourceGroup
    Resource group of the APIM instance. If omitted, you pick the instance from a list.

.PARAMETER ApimName
    APIM instance name. If omitted, you pick the instance from a list.

.PARAMETER Action
    Run a single action without the menu, then exit. Valid values:
    InventorySubscriptionKeys, InventoryNamedValues, InventoryBackends, InventoryOAuth,
    InventoryLoggers, InventoryAll, RegeneratePrimaryKeys, RegenerateSecondaryKeys

.PARAMETER SubscriptionFilter
    Wildcard filter on subscription ID or display name for key regeneration. Default '*' (all).
    Example: 'partner-*'

.PARAMETER SubscriptionListFile
    Optional CSV (with a 'Sid' column) or text file (one ID per line) listing the subscription
    IDs to regenerate. Use the 'failed' CSV from a previous run to retry only the failures.

.PARAMETER ExcludeBuiltInAllAccess
    Skip the built-in all-access subscription ('master') during regeneration.

.PARAMETER Force
    Skip the typed confirmation before regeneration (for automation pipelines).

.PARAMETER SkipSecretPresenceCheck
    Do not call listSecrets on OAuth 2.0 / OpenID Connect providers. The inventory then cannot
    say whether a client secret is configured.

.PARAMETER OutputPath
    Root folder for reports. Default: ./apim-credential-reports

.PARAMETER DelayMs
    Pause between regeneration calls, to avoid Azure throttling. Default 250 ms.

.PARAMETER ApiVersion
    Azure Resource Manager API version for Microsoft.ApiManagement. Default 2024-05-01.

.EXAMPLE
    ./Invoke-ApimCredentialToolkit.ps1
    Signs in if needed, lets you pick an APIM instance, then shows the menu.

.EXAMPLE
    ./Invoke-ApimCredentialToolkit.ps1 -ResourceGroup rg-apim -ApimName contoso-apim -Action InventoryAll
    Produces the full credential report for one instance without the menu.

.EXAMPLE
    ./Invoke-ApimCredentialToolkit.ps1 -ResourceGroup rg-apim -ApimName contoso-apim -Action RegenerateSecondaryKeys -SubscriptionFilter 'test-*'
    Regenerates secondary keys only for subscriptions whose ID or name starts with 'test-'.

.EXAMPLE
    ./Invoke-ApimCredentialToolkit.ps1 -ResourceGroup rg-apim -ApimName contoso-apim -Action RegenerateSecondaryKeys -SubscriptionListFile ./failed_secondary.csv
    Retries only the subscriptions that failed in a previous run.

.NOTES
    Permissions
      - Inventories: Reader on the APIM instance. The OAuth/OpenID secret-presence check needs
        listSecrets permission (for example, API Management Service Contributor).
      - Regeneration: API Management Service Contributor (or a custom role with
        Microsoft.ApiManagement/service/subscriptions/regeneratePrimaryKey/action and
        .../regenerateSecondaryKey/action).

    Recommended subscription key rotation order (zero downtime)
      1. Move all clients to the PRIMARY key.     2. Regenerate the SECONDARY key (option 8).
      3. Move all clients to the new SECONDARY.   4. Regenerate the PRIMARY key (option 7).

    Test on a non-production instance first.
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$ApimName,

    [ValidateSet('InventorySubscriptionKeys', 'InventoryNamedValues', 'InventoryBackends',
                 'InventoryOAuth', 'InventoryLoggers', 'InventoryAll',
                 'RegeneratePrimaryKeys', 'RegenerateSecondaryKeys')]
    [string]$Action,

    [string]$SubscriptionFilter = '*',
    [string]$SubscriptionListFile,
    [switch]$ExcludeBuiltInAllAccess,
    [switch]$Force,
    [switch]$SkipSecretPresenceCheck,
    [string]$OutputPath = (Join-Path $PWD.Path 'apim-credential-reports'),
    [ValidateRange(0, 10000)][int]$DelayMs = 250,
    [string]$ApiVersion = '2024-05-01'
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------------------------
# Script state
# ----------------------------------------------------------------------------------------------
$script:Apim           = $null    # Selected instance (hashtable)
$script:ReportDir      = $null    # Report folder for the selected instance
$script:LogFile        = $null    # Run log
$script:WorkspaceCache = $null    # Cached workspace list for the selected instance
$script:SecretLikeName = '(?i)(secret|password|passwd|pwd|apikey|api-key|key|token|connection|connstr|credential|sas|signature|clientsecret)'

# ----------------------------------------------------------------------------------------------
# Logging and output helpers
# ----------------------------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Ok', 'Warn', 'Error', 'Step')][string]$Level = 'Info'
    )
    $colors  = @{ Info = 'Gray'; Ok = 'Green'; Warn = 'Yellow'; Error = 'Red'; Step = 'Cyan' }
    $prefix  = @{ Info = '   '; Ok = '[+]'; Warn = '[!]'; Error = '[x]'; Step = '==>' }
    Write-Host ('{0} {1}' -f $prefix[$Level], $Message) -ForegroundColor $colors[$Level]
    if ($script:LogFile) {
        try {
            $line = '{0} [{1}] {2}' -f (Get-Date).ToUniversalTime().ToString('u'), $Level.ToUpper(), $Message
            Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
        } catch { }
    }
}

function Show-AndExport {
    param(
        [object[]]$Rows,
        [string]$Title,
        [string]$FileName,
        [string[]]$TableColumns
    )
    $count = @($Rows).Count
    Write-Host ''
    Write-Log ('{0} - {1} item(s)' -f $Title, $count) 'Step'
    if ($count -eq 0) {
        Write-Log 'Nothing found.' 'Info'
        return $null
    }
    $Rows | Format-Table -Property $TableColumns -AutoSize -Wrap | Out-Host
    $file = Join-Path $script:ReportDir $FileName
    try {
        $Rows | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
        Write-Log ('Saved: {0}' -f $file) 'Ok'
    } catch {
        Write-Log ('Could not save {0}: {1}' -f $file, $_.Exception.Message) 'Warn'
    }
    return $file
}

function Get-ValueSource {
    # Describes where a credential value comes from WITHOUT revealing the value.
    param($Value)
    if ($null -eq $Value) { return 'Empty' }
    $text = (@($Value) | ForEach-Object { [string]$_ }) -join ' '
    if ([string]::IsNullOrWhiteSpace($text)) { return 'Empty' }
    $refs = [regex]::Matches($text, '\{\{([^}]+)\}\}')
    if ($refs.Count -gt 0) {
        $names = ($refs | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ', '
        return ('Named value: {0}' -f $names)
    }
    return 'Literal value (hidden) - move to a Key Vault named value'
}

function Get-DaysToExpiry {
    param($Date)
    if (-not $Date) { return $null }
    try {
        return [int][Math]::Floor((([datetime]$Date).ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalDays)
    } catch { return $null }
}

function Format-SubscriptionScope {
    param([string]$Scope)
    if (-not $Scope) { return '' }
    if ($Scope -match '/products/([^/]+)$') { return ('Product: {0}' -f $Matches[1]) }
    if ($Scope -match '/apis/([^/]+)$')     { return ('API: {0}' -f $Matches[1]) }
    if ($Scope -match '/apis/?$')           { return 'All APIs' }
    return $Scope
}

function Get-ResourceGroupFromId {
    param([string]$Id)
    $parts = $Id -split '/'
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        if ($parts[$i] -ieq 'resourceGroups') { return $parts[$i + 1] }
    }
    return ''
}

# ----------------------------------------------------------------------------------------------
# Azure Resource Manager helpers (retry, paging, friendly errors)
# ----------------------------------------------------------------------------------------------
function Get-ArmErrorMessage {
    param($Response)
    try {
        $err = ($Response.Content | ConvertFrom-Json).error
        if ($err) { return ('{0}: {1}' -f $err.code, $err.message) }
    } catch { }
    if ($Response.Content) {
        $c = [string]$Response.Content
        return $c.Substring(0, [Math]::Min(300, $c.Length))
    }
    return 'No error details returned.'
}

function New-ArmError {
    param([int]$Code, [string]$Message, [string]$Path)
    $hint = ''
    switch ($Code) {
        401 { $hint = ' Your sign-in may have expired: run Connect-AzAccount and try again.' }
        403 { $hint = ' You do not have permission for this operation on the APIM instance.' }
        404 { $hint = ' The resource was not found.' }
    }
    $ex = New-Object System.Exception ('HTTP {0} - {1}{2}' -f $Code, $Message, $hint)
    $ex.Data['StatusCode'] = $Code
    $ex.Data['Path'] = $Path
    return $ex
}

function Invoke-Arm {
    param(
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxRetries = 5
    )
    $attempt = 0
    while ($true) {
        $attempt++
        $resp = $null
        try {
            $resp = Invoke-AzRestMethod -Method $Method -Path $Path -WarningAction SilentlyContinue -ErrorAction Stop
        } catch {
            if ($attempt -le $MaxRetries) {
                $wait = [int][Math]::Min(60, [Math]::Pow(2, $attempt))
                Write-Log ('Network error, retrying in {0}s ({1}/{2}): {3}' -f $wait, $attempt, $MaxRetries, $_.Exception.Message) 'Warn'
                Start-Sleep -Seconds $wait
                continue
            }
            throw (New-ArmError -Code 0 -Message ('Network error: {0}' -f $_.Exception.Message) -Path $Path)
        }

        $code = [int]$resp.StatusCode
        if ($code -ge 200 -and $code -lt 300) {
            if ($resp.Content -and ([string]$resp.Content).Trim().Length -gt 0) {
                return ($resp.Content | ConvertFrom-Json)
            }
            return $true
        }

        if (($code -eq 429 -or $code -ge 500) -and $attempt -le $MaxRetries) {
            $wait = [int][Math]::Min(60, [Math]::Pow(2, $attempt))
            try {
                $ra = $resp.Headers.RetryAfter
                if ($ra -and $ra.Delta) { $wait = [int][Math]::Ceiling($ra.Delta.TotalSeconds) }
            } catch { }
            Write-Log ('Azure returned {0}; retrying in {1}s ({2}/{3})...' -f $code, $wait, $attempt, $MaxRetries) 'Warn'
            Start-Sleep -Seconds $wait
            continue
        }

        throw (New-ArmError -Code $code -Message (Get-ArmErrorMessage $resp) -Path $Path)
    }
}

function Get-ArmList {
    # Returns every item across all pages of an ARM list call.
    param([Parameter(Mandatory)][string]$Path)
    $items = New-Object System.Collections.Generic.List[object]
    $next  = $Path
    while ($next) {
        $page = Invoke-Arm -Method GET -Path $next
        if ($page -and $page.value) {
            foreach ($i in $page.value) { $items.Add($i) }
        }
        $next = $null
        if ($page -and $page.nextLink) { $next = ([uri]$page.nextLink).PathAndQuery }
    }
    return $items.ToArray()
}

function Get-ApimPath {
    # Builds an ARM path under the selected APIM instance, with the API version.
    param([string]$Relative = '')
    return ('{0}{1}?api-version={2}' -f $script:Apim.Path, $Relative, $ApiVersion)
}

function Get-ApimWorkspaces {
    if ($null -ne $script:WorkspaceCache) { return $script:WorkspaceCache }
    $ws = @()
    try {
        $ws = @(Get-ArmList (Get-ApimPath '/workspaces'))
        if ($ws.Count -gt 0) { Write-Log ('Found {0} workspace(s); including workspace-level items.' -f $ws.Count) 'Info' }
    } catch {
        Write-Log 'Workspaces are not available on this instance; checking service level only.' 'Info'
        $ws = @()
    }
    $script:WorkspaceCache = $ws
    return $ws
}

function Get-ScopedItems {
    # Lists a collection at service level and in every workspace, tagging each item with its scope.
    param([Parameter(Mandatory)][string]$Collection)
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($i in @(Get-ArmList (Get-ApimPath ('/{0}' -f $Collection)))) {
        $results.Add([pscustomobject]@{ Scope = 'Service'; Item = $i })
    }
    foreach ($w in @(Get-ApimWorkspaces)) {
        try {
            foreach ($i in @(Get-ArmList (Get-ApimPath ('/workspaces/{0}/{1}' -f $w.name, $Collection)))) {
                $results.Add([pscustomobject]@{ Scope = ('Workspace: {0}' -f $w.name); Item = $i })
            }
        } catch {
            Write-Log ('Could not read {0} in workspace {1}: {2}' -f $Collection, $w.name, $_.Exception.Message) 'Warn'
        }
    }
    return $results.ToArray()
}

# ----------------------------------------------------------------------------------------------
# Prerequisites, sign-in and instance selection
# ----------------------------------------------------------------------------------------------
function Test-Prerequisites {
    $v = $PSVersionTable.PSVersion
    if ($v.Major -lt 5 -or ($v.Major -eq 5 -and $v.Minor -lt 1)) {
        throw 'PowerShell 5.1 or later is required (Azure Cloud Shell works out of the box).'
    }
    if (-not (Get-Module -Name Az.Accounts)) {
        $mod = Get-Module -ListAvailable -Name Az.Accounts | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $mod) {
            throw 'The Az.Accounts module is not installed. Run: Install-Module Az.Accounts -Scope CurrentUser   (or use Azure Cloud Shell).'
        }
        Import-Module Az.Accounts -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    }
    if (-not (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue)) {
        throw 'Your Az.Accounts module is too old (Invoke-AzRestMethod missing). Run: Update-Module Az.Accounts'
    }
}

function Connect-Azure {
    param([string]$TargetSubscriptionId)
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx -or -not $ctx.Account) {
        Write-Log 'No Azure sign-in found. Opening sign-in...' 'Step'
        if ($TargetSubscriptionId) {
            Connect-AzAccount -Subscription $TargetSubscriptionId -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        } else {
            Connect-AzAccount -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        }
        $ctx = Get-AzContext
    }
    if ($TargetSubscriptionId -and $ctx.Subscription.Id -ne $TargetSubscriptionId) {
        Set-AzContext -Subscription $TargetSubscriptionId -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        $ctx = Get-AzContext
    }
    if (-not $ctx.Subscription) { throw 'No Azure subscription is selected. Re-run with -SubscriptionId.' }
    Write-Log ('Signed in as {0} | Azure subscription: {1} ({2})' -f $ctx.Account.Id, $ctx.Subscription.Name, $ctx.Subscription.Id) 'Ok'
    return $ctx
}

function Set-ApimInstance {
    param([string]$Rg, [string]$Name)
    $ctx = Get-AzContext
    $sub = $ctx.Subscription.Id

    if (-not ($Rg -and $Name)) {
        Write-Log ('Looking for API Management instances in {0}...' -f $ctx.Subscription.Name) 'Step'
        $all = @(Get-ArmList ('/subscriptions/{0}/providers/Microsoft.ApiManagement/service?api-version={1}' -f $sub, $ApiVersion))
        if ($Name) { $all = @($all | Where-Object { $_.name -ieq $Name }) }
        if ($Rg)   { $all = @($all | Where-Object { (Get-ResourceGroupFromId $_.id) -ieq $Rg }) }
        if ($all.Count -eq 0) {
            throw ('No API Management instances found in subscription {0}. Check the subscription or pass -SubscriptionId.' -f $ctx.Subscription.Name)
        }
        if ($all.Count -eq 1) {
            $pick = $all[0]
        } else {
            Write-Host ''
            Write-Host ('  {0,-4} {1,-35} {2,-30} {3,-14} {4}' -f '#', 'Instance', 'Resource group', 'Tier', 'Region') -ForegroundColor Cyan
            for ($i = 0; $i -lt $all.Count; $i++) {
                Write-Host ('  {0,-4} {1,-35} {2,-30} {3,-14} {4}' -f ($i + 1), $all[$i].name, (Get-ResourceGroupFromId $all[$i].id), $all[$i].sku.name, $all[$i].location)
            }
            do {
                $sel = Read-Host ('Select an instance (1-{0})' -f $all.Count)
            } until ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $all.Count)
            $pick = $all[[int]$sel - 1]
        }
        $Rg   = Get-ResourceGroupFromId $pick.id
        $Name = $pick.name
    }

    $path = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.ApiManagement/service/{2}' -f $sub, $Rg, $Name
    try {
        $svc = Invoke-Arm -Path ('{0}?api-version={1}' -f $path, $ApiVersion)
    } catch {
        throw ('Could not open APIM instance {0} in resource group {1}: {2}' -f $Name, $Rg, $_.Exception.Message)
    }

    $sku    = [string]$svc.sku.name
    $family = 'Classic'
    if ($sku -like '*V2') { $family = 'v2' }

    $script:Apim = @{
        SubscriptionId = $sub
        ResourceGroup  = $Rg
        Name           = $svc.name
        Sku            = $sku
        TierFamily     = $family
        Location       = $svc.location
        Path           = $path
    }
    $script:WorkspaceCache = $null

    $folder = '{0}_{1}' -f $svc.name, (Get-Date -Format 'yyyyMMdd_HHmmss')
    $script:ReportDir = Join-Path $OutputPath $folder
    New-Item -ItemType Directory -Path $script:ReportDir -Force | Out-Null
    $script:LogFile = Join-Path $script:ReportDir 'run.log'

    Write-Log ('Selected APIM instance: {0} | Resource group: {1} | Tier: {2} ({3}) | Region: {4}' -f $svc.name, $Rg, $sku, $family, $svc.location) 'Ok'
    Write-Log ('Reports folder: {0}' -f $script:ReportDir) 'Info'
}

# ----------------------------------------------------------------------------------------------
# 1. Subscription keys
# ----------------------------------------------------------------------------------------------
function Get-SubscriptionKeyInventory {
    Write-Log 'Collecting subscriptions...' 'Step'
    $rows = foreach ($e in @(Get-ScopedItems 'subscriptions')) {
        $p = $e.Item.properties
        [pscustomobject]@{
            Sid              = $e.Item.name
            DisplayName      = $p.displayName
            InstanceScope    = $e.Scope
            GrantsAccessTo   = $(Format-SubscriptionScope ([string]$p.scope))
            State            = $p.state
            OwnerUserId      = $(if ($p.ownerId) { ([string]$p.ownerId -split '/')[-1] } else { '' })
            CreatedUtc       = $p.createdDate
            ExpiresUtc       = $p.expirationDate
            BuiltInAllAccess = ($e.Item.name -eq 'master')
            ResourceId       = $e.Item.id
        }
    }
    return @($rows)
}

function Invoke-SubscriptionKeyInventory {
    $rows = @(Get-SubscriptionKeyInventory)
    $null = Show-AndExport -Rows $rows -Title 'Subscription keys' -FileName '1_subscription_keys.csv' `
        -TableColumns Sid, DisplayName, InstanceScope, GrantsAccessTo, State, BuiltInAllAccess
    if ($rows.Count -gt 0) {
        $byState = $rows | Group-Object State | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Count }
        Write-Log ('By state - {0}' -f ($byState -join ' | ')) 'Info'
        Write-Log 'Each subscription has a primary and a secondary key. Key values are not shown.' 'Info'
    }
    return $rows.Count
}

# ----------------------------------------------------------------------------------------------
# 2. Named values that hold secrets
# ----------------------------------------------------------------------------------------------
function Invoke-NamedValueInventory {
    Write-Log 'Collecting named values...' 'Step'
    $rows = foreach ($e in @(Get-ScopedItems 'namedValues')) {
        $p        = $e.Item.properties
        $kv       = $p.keyVault
        $isKv     = [bool]($kv -and $kv.secretIdentifier)
        $isSecret = [bool]$p.secret
        $looksSecret = (-not $isSecret) -and (-not $isKv) -and
                       (($e.Item.name -match $script:SecretLikeName) -or ([string]$p.displayName -match $script:SecretLikeName))
        if (-not ($isSecret -or $isKv -or $looksSecret)) { continue }

        $storage = 'Secret stored in APIM'
        $action  = 'Rotate at the source, update the value in APIM (or move it to Key Vault)'
        if ($isKv) {
            $storage = 'Azure Key Vault reference'
            $action  = 'Rotate in Key Vault; APIM picks up the new version on refresh'
        } elseif ($looksSecret) {
            $storage = 'PLAIN TEXT - not marked secret (review)'
            $action  = 'Mark as secret or move to Key Vault, then rotate'
        }

        $identity = ''
        if ($isKv) {
            $identity = 'System-assigned'
            if ($kv.identityClientId) { $identity = 'User-assigned: {0}' -f $kv.identityClientId }
        }
        $kvStatus = ''
        if ($isKv -and $kv.lastStatus) { $kvStatus = '{0} at {1}' -f $kv.lastStatus.code, $kv.lastStatus.timeStampUtc }

        [pscustomobject]@{
            Name             = $e.Item.name
            DisplayName      = $p.displayName
            InstanceScope    = $e.Scope
            Storage          = $storage
            KeyVaultSecretId = $(if ($isKv) { $kv.secretIdentifier } else { '' })
            KeyVaultIdentity = $identity
            LastKeyVaultSync = $kvStatus
            Tags             = (@($p.tags) -join ', ')
            RotationAction   = $action
        }
    }
    $rows = @($rows)
    $null = Show-AndExport -Rows $rows -Title 'Named values holding secrets' -FileName '2_named_values_secrets.csv' `
        -TableColumns DisplayName, InstanceScope, Storage, KeyVaultIdentity, LastKeyVaultSync
    $plain = @($rows | Where-Object { $_.Storage -like 'PLAIN TEXT*' }).Count
    if ($plain -gt 0) {
        Write-Log ('{0} named value(s) look like secrets but are NOT marked secret. Review them.' -f $plain) 'Warn'
    }
    return $rows.Count
}

# ----------------------------------------------------------------------------------------------
# 3. Backend credentials and client certificates
# ----------------------------------------------------------------------------------------------
function Invoke-BackendInventory {
    Write-Log 'Collecting certificates...' 'Step'
    $certRows = foreach ($e in @(Get-ScopedItems 'certificates')) {
        $p    = $e.Item.properties
        $days = Get-DaysToExpiry $p.expirationDate
        $status = 'OK'
        if ($null -ne $days) {
            if ($days -lt 0)       { $status = 'EXPIRED' }
            elseif ($days -le 30)  { $status = 'Expires within 30 days' }
        }
        [pscustomobject]@{
            Name          = $e.Item.name
            InstanceScope = $e.Scope
            Subject       = $p.subject
            Thumbprint    = $p.thumbprint
            ExpiresUtc    = $p.expirationDate
            DaysToExpiry  = $days
            Status        = $status
            Source        = $(if ($p.keyVault -and $p.keyVault.secretIdentifier) { 'Azure Key Vault reference' } else { 'Uploaded to APIM' })
            ResourceId    = $e.Item.id
        }
    }
    $certRows = @($certRows)

    $certById    = @{}
    $certByThumb = @{}
    foreach ($c in $certRows) {
        if ($c.ResourceId) { $certById[([string]$c.ResourceId).ToLower()] = $c }
        if ($c.Thumbprint) { $certByThumb[([string]$c.Thumbprint).ToUpper()] = $c }
    }

    Write-Log 'Collecting backends...' 'Step'
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(Get-ScopedItems 'backends')) {
        $b    = $e.Item
        $p    = $b.properties
        $cred = $p.credentials
        $type = 'Single'
        if ($p.type) { $type = $p.type }
        $found = 0

        $newRow = {
            param($Kind, $CredName, $Source, $Detail)
            [pscustomobject]@{
                Backend        = $b.name
                InstanceScope  = $e.Scope
                Url            = $p.url
                BackendType    = $type
                CredentialKind = $Kind
                CredentialName = $CredName
                ValueSource    = $Source
                Detail         = $Detail
            }
        }

        if ($cred) {
            if ($cred.header) {
                foreach ($h in $cred.header.PSObject.Properties) {
                    $rows.Add((& $newRow 'Header' $h.Name (Get-ValueSource $h.Value) '')); $found++
                }
            }
            if ($cred.query) {
                foreach ($q in $cred.query.PSObject.Properties) {
                    $rows.Add((& $newRow 'Query parameter' $q.Name (Get-ValueSource $q.Value) '')); $found++
                }
            }
            if ($cred.authorization -and ($cred.authorization.scheme -or $cred.authorization.parameter)) {
                $rows.Add((& $newRow 'Authorization header' ([string]$cred.authorization.scheme) (Get-ValueSource $cred.authorization.parameter) '')); $found++
            }
            foreach ($certId in $cred.certificateIds) {
                if (-not $certId) { continue }
                $match = $certById[([string]$certId).ToLower()]
                if ($match) {
                    $detail = 'Expires {0} ({1} days) - {2}' -f $match.ExpiresUtc, $match.DaysToExpiry, $match.Status
                    $rows.Add((& $newRow 'Client certificate' $match.Name $match.Source $detail))
                } else {
                    $rows.Add((& $newRow 'Client certificate' (([string]$certId -split '/')[-1]) 'Certificate not found in APIM' ''))
                }
                $found++
            }
            foreach ($thumb in $cred.certificate) {
                if (-not $thumb) { continue }
                $match = $certByThumb[([string]$thumb).ToUpper()]
                $detail = ''
                $name   = $thumb
                $source = 'Thumbprint reference (legacy)'
                if ($match) {
                    $name   = $match.Name
                    $detail = 'Expires {0} ({1} days) - {2}' -f $match.ExpiresUtc, $match.DaysToExpiry, $match.Status
                }
                $rows.Add((& $newRow 'Client certificate' $name $source $detail)); $found++
            }
        }
        if ($p.proxy -and $p.proxy.password) {
            $rows.Add((& $newRow 'Proxy password' ([string]$p.proxy.username) (Get-ValueSource $p.proxy.password) ([string]$p.proxy.url))); $found++
        }
        if ($found -eq 0) {
            $rows.Add((& $newRow 'None' '' 'No stored credentials (may use managed identity or a policy)' ''))
        }
    }
    $rows = $rows.ToArray()

    $null = Show-AndExport -Rows $rows -Title 'Backend credentials' -FileName '3_backend_credentials.csv' `
        -TableColumns Backend, InstanceScope, CredentialKind, CredentialName, ValueSource, Detail
    $null = Show-AndExport -Rows $certRows -Title 'Certificates stored in APIM' -FileName '3_certificates.csv' `
        -TableColumns Name, InstanceScope, Subject, ExpiresUtc, DaysToExpiry, Status, Source

    $literal = @($rows | Where-Object { $_.ValueSource -like 'Literal*' }).Count
    if ($literal -gt 0) { Write-Log ('{0} backend credential(s) use literal values. Move them to Key Vault named values.' -f $literal) 'Warn' }
    $expiring = @($certRows | Where-Object { $_.Status -ne 'OK' }).Count
    if ($expiring -gt 0) { Write-Log ('{0} certificate(s) are expired or expire within 30 days.' -f $expiring) 'Warn' }

    return @($rows | Where-Object { $_.CredentialKind -ne 'None' }).Count
}

# ----------------------------------------------------------------------------------------------
# 4. OAuth 2.0 and OpenID Connect client secrets
# ----------------------------------------------------------------------------------------------
function Test-ProviderSecret {
    # Returns Yes/No/Unknown for whether a secret is configured. The secret itself is discarded.
    param([string]$Path, [string]$Field = 'clientSecret')
    if ($SkipSecretPresenceCheck) { return 'Not checked' }
    try {
        $s = Invoke-Arm -Method POST -Path $Path
        $has = -not [string]::IsNullOrEmpty([string]$s.$Field)
        $s = $null
        if ($has) { return 'Yes' } else { return 'No' }
    } catch {
        $code = $_.Exception.Data['StatusCode']
        if ($code -eq 403) { return 'Unknown (no listSecrets permission)' }
        return ('Unknown ({0})' -f $_.Exception.Message)
    }
}

function Invoke-OAuthInventory {
    $rows = New-Object System.Collections.Generic.List[object]
    $rotate = 'Create a new client secret at the identity provider, update it here, test, then delete the old secret'

    Write-Log 'Collecting OAuth 2.0 authorization servers...' 'Step'
    try {
        foreach ($a in @(Get-ArmList (Get-ApimPath '/authorizationServers'))) {
            $p = $a.properties
            $listPath = Get-ApimPath ('/authorizationServers/{0}/listSecrets' -f $a.name)
            $rows.Add([pscustomobject]@{
                Type                = 'OAuth 2.0 authorization server'
                Name                = $a.name
                DisplayName         = $p.displayName
                ClientId            = $p.clientId
                GrantTypes          = (@($p.grantTypes) -join ', ')
                Endpoint            = $p.tokenEndpoint
                ClientSecretSet     = $(Test-ProviderSecret -Path $listPath -Field 'clientSecret')
                ResourceOwnerPwdSet = $(if ($SkipSecretPresenceCheck) { 'Not checked' } else { Test-ProviderSecret -Path $listPath -Field 'resourceOwnerPassword' })
                RotationAction      = $rotate
            })
        }
    } catch { Write-Log ('Could not read OAuth 2.0 authorization servers: {0}' -f $_.Exception.Message) 'Warn' }

    Write-Log 'Collecting OpenID Connect providers...' 'Step'
    try {
        foreach ($o in @(Get-ArmList (Get-ApimPath '/openidConnectProviders'))) {
            $p = $o.properties
            $rows.Add([pscustomobject]@{
                Type                = 'OpenID Connect provider'
                Name                = $o.name
                DisplayName         = $p.displayName
                ClientId            = $p.clientId
                GrantTypes          = ''
                Endpoint            = $p.metadataEndpoint
                ClientSecretSet     = $(Test-ProviderSecret -Path (Get-ApimPath ('/openidConnectProviders/{0}/listSecrets' -f $o.name)))
                ResourceOwnerPwdSet = 'n/a'
                RotationAction      = $rotate
            })
        }
    } catch { Write-Log ('Could not read OpenID Connect providers: {0}' -f $_.Exception.Message) 'Warn' }

    Write-Log 'Collecting credential manager providers...' 'Step'
    try {
        foreach ($c in @(Get-ArmList (Get-ApimPath '/authorizationProviders'))) {
            $p = $c.properties
            $grants = ''
            if ($p.oauth2 -and $p.oauth2.grantTypes) { $grants = ($p.oauth2.grantTypes.PSObject.Properties.Name -join ', ') }
            $rows.Add([pscustomobject]@{
                Type                = 'Credential manager provider'
                Name                = $c.name
                DisplayName         = $p.displayName
                ClientId            = ''
                GrantTypes          = $grants
                Endpoint            = $p.identityProvider
                ClientSecretSet     = 'Stored by APIM (not readable)'
                ResourceOwnerPwdSet = 'n/a'
                RotationAction      = $rotate
            })
        }
    } catch {
        Write-Log 'Credential manager is not available on this instance (skipped).' 'Info'
    }

    $rows = $rows.ToArray()
    $null = Show-AndExport -Rows $rows -Title 'OAuth 2.0 / OpenID Connect client secrets' -FileName '4_oauth_openid_secrets.csv' `
        -TableColumns Type, DisplayName, ClientId, Endpoint, ClientSecretSet
    return $rows.Count
}

# ----------------------------------------------------------------------------------------------
# 5. Logger credentials and connection strings
# ----------------------------------------------------------------------------------------------
function Invoke-LoggerInventory {
    Write-Log 'Collecting loggers...' 'Step'
    $rows = foreach ($e in @(Get-ScopedItems 'loggers')) {
        $p    = $e.Item.properties
        $c    = $p.credentials
        $type = [string]$p.loggerType
        $auth = 'None found'
        $src  = ''
        $act  = 'Review'

        if ($c -and $c.identityClientId) {
            $auth = 'Managed identity'
            $src  = $(if ($c.identityClientId -eq 'SystemAssigned') { 'System-assigned' } else { 'User-assigned: {0}' -f $c.identityClientId })
            $act  = 'No secret to rotate'
        } elseif ($c -and $c.connectionString) {
            $auth = 'Connection string'
            $src  = Get-ValueSource $c.connectionString
            if ($type -eq 'azureEventHub') {
                $act = 'Rotate the Event Hubs shared access key (switch to the other key first), update the referenced named value, then regenerate the old key'
            } else {
                $act = 'Update the referenced named value if the connection string changes; consider managed identity'
            }
        } elseif ($c -and $c.instrumentationKey) {
            $auth = 'Instrumentation key'
            $src  = Get-ValueSource $c.instrumentationKey
            $act  = 'Consider switching to a connection string or managed identity'
        } elseif ($type -eq 'azureMonitor') {
            $auth = 'Built-in Azure Monitor'
            $src  = 'n/a'
            $act  = 'No secret to rotate'
        }

        $target = ''
        if ($c -and $c.name)            { $target = 'Event hub: {0}' -f $c.name }
        if ($c -and $c.endpointAddress) { $target = ('{0} @ {1}' -f $target, $c.endpointAddress).Trim(' @') }
        if (-not $target -and $p.resourceId) { $target = ([string]$p.resourceId -split '/')[-1] }

        [pscustomobject]@{
            Logger           = $e.Item.name
            InstanceScope    = $e.Scope
            LoggerType       = $type
            AuthMethod       = $auth
            CredentialSource = $src
            Target           = $target
            RotationAction   = $act
        }
    }
    $rows = @($rows)
    $null = Show-AndExport -Rows $rows -Title 'Logger credentials / connection strings' -FileName '5_logger_credentials.csv' `
        -TableColumns Logger, InstanceScope, LoggerType, AuthMethod, CredentialSource, Target
    return @($rows | Where-Object { $_.AuthMethod -in @('Connection string', 'Instrumentation key') }).Count
}

# ----------------------------------------------------------------------------------------------
# 6. Full credential report
# ----------------------------------------------------------------------------------------------
function Invoke-AllInventories {
    $summary = New-Object System.Collections.Generic.List[object]
    $steps = [ordered]@{
        'Subscriptions (each has 2 keys)'          = { Invoke-SubscriptionKeyInventory }
        'Named values holding secrets'             = { Invoke-NamedValueInventory }
        'Backend credentials'                      = { Invoke-BackendInventory }
        'OAuth 2.0 / OpenID Connect providers'     = { Invoke-OAuthInventory }
        'Loggers using connection strings or keys' = { Invoke-LoggerInventory }
    }
    foreach ($k in $steps.Keys) {
        $count  = $null
        $status = 'OK'
        try {
            $block = $steps[$k]
            $count = @(& $block)[-1]
        } catch {
            $status = 'FAILED: {0}' -f $_.Exception.Message
            Write-Log ('{0} inventory failed: {1}' -f $k, $_.Exception.Message) 'Error'
        }
        $summary.Add([pscustomobject]@{ Area = $k; Count = $count; Status = $status })
    }
    $null = Show-AndExport -Rows $summary.ToArray() -Title ('Credential report summary for {0}' -f $script:Apim.Name) `
        -FileName '0_summary.csv' -TableColumns Area, Count, Status
}

# ----------------------------------------------------------------------------------------------
# 7 / 8. Regenerate subscription keys
# ----------------------------------------------------------------------------------------------
function Get-SidListFromFile {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { throw ('Subscription list file not found: {0}' -f $File) }
    if ($File -like '*.csv') {
        $csv = @(Import-Csv -LiteralPath $File)
        if ($csv.Count -gt 0 -and -not ($csv[0].PSObject.Properties.Name -contains 'Sid')) {
            throw 'The CSV file must have a column named Sid.'
        }
        return @($csv | ForEach-Object { ([string]$_.Sid).Trim() } | Where-Object { $_ })
    }
    return @(Get-Content -LiteralPath $File | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}

function Invoke-KeyRegeneration {
    param([Parameter(Mandatory)][ValidateSet('Primary', 'Secondary')][string]$KeyType)

    $otherKey = 'secondary'
    $apiOp    = 'regeneratePrimaryKey'
    if ($KeyType -eq 'Secondary') { $otherKey = 'primary'; $apiOp = 'regenerateSecondaryKey' }

    $all = @(Get-SubscriptionKeyInventory)
    if ($all.Count -eq 0) { Write-Log 'This instance has no subscriptions.' 'Warn'; return 0 }

    $targets = @($all | Where-Object { ($_.Sid -like $SubscriptionFilter) -or ([string]$_.DisplayName -like $SubscriptionFilter) })
    if ($SubscriptionListFile) {
        $wanted  = @(Get-SidListFromFile $SubscriptionListFile)
        $targets = @($targets | Where-Object { $wanted -contains $_.Sid })
        $missing = @($wanted | Where-Object { $all.Sid -notcontains $_ })
        if ($missing.Count -gt 0) { Write-Log ('{0} ID(s) in the list file were not found on this instance: {1}' -f $missing.Count, ($missing -join ', ')) 'Warn' }
    }
    if ($ExcludeBuiltInAllAccess) { $targets = @($targets | Where-Object { -not $_.BuiltInAllAccess }) }

    if ($targets.Count -eq 0) {
        Write-Log ('No subscriptions match the selection (filter: {0}).' -f $SubscriptionFilter) 'Warn'
        return 0
    }

    $stamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
    $keyLower = $KeyType.ToLower()
    $null = Show-AndExport -Rows $targets -Title ('Subscriptions selected for {0} key regeneration' -f $KeyType.ToUpper()) `
        -FileName ('{0}_selected_{1}.csv' -f $keyLower, $stamp) `
        -TableColumns Sid, DisplayName, InstanceScope, GrantsAccessTo, State

    Write-Host ''
    Write-Host ('  IMPORTANT: any client still calling with the current {0} key will get 401 errors' -f $KeyType.ToUpper()) -ForegroundColor Yellow
    Write-Host ('  as soon as its key is regenerated. Move those clients to the {0} key first.' -f $otherKey) -ForegroundColor Yellow
    Write-Host ''

    if (-not $Force) {
        $prompt = 'Type the instance name ({0}) to regenerate {1} keys for {2} subscription(s), or press Enter to cancel' -f $script:Apim.Name, $KeyType.ToUpper(), $targets.Count
        $answer = Read-Host $prompt
        if ([string]$answer -ne $script:Apim.Name) {
            Write-Log 'Cancelled. No keys were changed.' 'Warn'
            return 0
        }
    }

    $resultFile = Join-Path $script:ReportDir ('{0}_regeneration_results_{1}.csv' -f $keyLower, $stamp)
    $failedFile = Join-Path $script:ReportDir ('{0}_failed_{1}.csv' -f $keyLower, $stamp)
    Write-Log ('Regenerating {0} keys for {1} subscription(s)...' -f $KeyType.ToUpper(), $targets.Count) 'Step'

    $ok = 0; $failed = 0; $i = 0
    foreach ($t in $targets) {
        $i++
        Write-Progress -Activity ('Regenerating {0} keys' -f $KeyType) -Status ('{0} of {1}: {2}' -f $i, $targets.Count, $t.Sid) `
            -PercentComplete ([int](($i / $targets.Count) * 100))
        $result = 'Success'
        $errMsg = ''
        try {
            $null = Invoke-Arm -Method POST -Path ('{0}/{1}?api-version={2}' -f $t.ResourceId, $apiOp, $ApiVersion)
            $ok++
            Write-Log ('OK    {0}  ({1})' -f $t.Sid, $t.DisplayName) 'Ok'
        } catch {
            $result = 'Failed'
            $errMsg = $_.Exception.Message
            $failed++
            Write-Log ('FAIL  {0}  ({1}) - {2}' -f $t.Sid, $t.DisplayName, $errMsg) 'Error'
        }

        $record = [pscustomobject]@{
            Sid            = $t.Sid
            DisplayName    = $t.DisplayName
            InstanceScope  = $t.InstanceScope
            KeyRegenerated = $KeyType
            Result         = $result
            Error          = $errMsg
            TimestampUtc   = (Get-Date).ToUniversalTime().ToString('u')
        }
        # Written after every call so the record survives an interruption (Ctrl+C).
        try { $record | Export-Csv -Path $resultFile -NoTypeInformation -Encoding UTF8 -Append } catch { }
        if ($result -eq 'Failed') {
            try { $record | Export-Csv -Path $failedFile -NoTypeInformation -Encoding UTF8 -Append } catch { }
        }

        if ($DelayMs -gt 0 -and $i -lt $targets.Count) { Start-Sleep -Milliseconds $DelayMs }
    }
    Write-Progress -Activity ('Regenerating {0} keys' -f $KeyType) -Completed

    Write-Host ''
    Write-Log ('{0} key regeneration finished. Succeeded: {1} | Failed: {2}' -f $KeyType.ToUpper(), $ok, $failed) $(if ($failed -gt 0) { 'Warn' } else { 'Ok' })
    Write-Log ('Results: {0}' -f $resultFile) 'Info'
    if ($failed -gt 0) {
        Write-Log ('Failed IDs: {0}' -f $failedFile) 'Warn'
        Write-Log ('Retry only those with: -Action Regenerate{0}Keys -SubscriptionListFile "{1}"' -f $KeyType, $failedFile) 'Info'
    }
    return $failed
}

# ----------------------------------------------------------------------------------------------
# Help, menu and dispatcher
# ----------------------------------------------------------------------------------------------
function Show-RotationGuide {
    Write-Host ''
    Write-Host '  Zero-downtime subscription key rotation' -ForegroundColor Cyan
    Write-Host '    1. Run option 1 to record the current subscriptions.'
    Write-Host '    2. Ask every client to use the PRIMARY key.'
    Write-Host '    3. Run option 8 to regenerate SECONDARY keys.'
    Write-Host '    4. Give clients the new SECONDARY key and confirm they use it.'
    Write-Host '    5. Run option 7 to regenerate PRIMARY keys.'
    Write-Host ''
    Write-Host '  Other credentials' -ForegroundColor Cyan
    Write-Host '    - Key Vault named values: rotate in Key Vault; APIM refreshes the reference.'
    Write-Host '    - Secrets stored in APIM or literal values: rotate at the source, update APIM, prefer Key Vault.'
    Write-Host '    - OAuth / OpenID client secrets: add a new secret at the identity provider, update APIM, delete the old one.'
    Write-Host '    - Event Hubs loggers: rotate the shared access key you are not using, update the named value, then the other key.'
    Write-Host ''
}

function Invoke-ToolkitAction {
    param([string]$Name)
    switch ($Name) {
        'InventorySubscriptionKeys' { $null = Invoke-SubscriptionKeyInventory; return 0 }
        'InventoryNamedValues'      { $null = Invoke-NamedValueInventory;      return 0 }
        'InventoryBackends'         { $null = Invoke-BackendInventory;         return 0 }
        'InventoryOAuth'            { $null = Invoke-OAuthInventory;           return 0 }
        'InventoryLoggers'          { $null = Invoke-LoggerInventory;          return 0 }
        'InventoryAll'              { Invoke-AllInventories;                   return 0 }
        'RegeneratePrimaryKeys'     { return (Invoke-KeyRegeneration -KeyType Primary) }
        'RegenerateSecondaryKeys'   { return (Invoke-KeyRegeneration -KeyType Secondary) }
    }
    return 0
}

function Show-Menu {
    $a = $script:Apim
    Write-Host ''
    Write-Host '  ================================================================' -ForegroundColor DarkCyan
    Write-Host '   Azure API Management - Credential Inventory and Rotation Toolkit' -ForegroundColor Cyan
    Write-Host '  ================================================================' -ForegroundColor DarkCyan
    Write-Host ('   Instance : {0}   (resource group: {1})' -f $a.Name, $a.ResourceGroup)
    Write-Host ('   Tier     : {0} ({1})   Region: {2}' -f $a.Sku, $a.TierFamily, $a.Location)
    Write-Host ('   Reports  : {0}' -f $script:ReportDir)
    if ($SubscriptionFilter -ne '*' -or $SubscriptionListFile -or $ExcludeBuiltInAllAccess) {
        Write-Host ('   Key filter: {0}{1}{2}' -f $SubscriptionFilter,
            $(if ($SubscriptionListFile) { ' | list: ' + $SubscriptionListFile } else { '' }),
            $(if ($ExcludeBuiltInAllAccess) { ' | excluding built-in all-access' } else { '' })) -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '   INVENTORY (read-only)' -ForegroundColor Green
    Write-Host '     1  Subscription keys'
    Write-Host '     2  Named values holding secrets'
    Write-Host '     3  Backend credentials (headers, query parameters, client certificates)'
    Write-Host '     4  OAuth 2.0 / OpenID Connect client secrets'
    Write-Host '     5  Logger connection strings (Event Hubs, Application Insights)'
    Write-Host '     6  Full credential report (runs 1-5)'
    Write-Host ''
    Write-Host '   ROTATION (changes keys)' -ForegroundColor Yellow
    Write-Host '     7  Regenerate PRIMARY subscription keys'
    Write-Host '     8  Regenerate SECONDARY subscription keys'
    Write-Host ''
    Write-Host '     S  Switch APIM instance      H  Rotation guide      Q  Quit'
    Write-Host ''
}

# ----------------------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------------------
$menuMap = @{
    '1' = 'InventorySubscriptionKeys'; '2' = 'InventoryNamedValues'; '3' = 'InventoryBackends'
    '4' = 'InventoryOAuth';            '5' = 'InventoryLoggers';     '6' = 'InventoryAll'
    '7' = 'RegeneratePrimaryKeys';     '8' = 'RegenerateSecondaryKeys'
}

try {
    Test-Prerequisites
    $null = Connect-Azure -TargetSubscriptionId $SubscriptionId
    Set-ApimInstance -Rg $ResourceGroup -Name $ApimName
} catch {
    Write-Log $_.Exception.Message 'Error'
    exit 1
}

# Non-interactive mode
if ($Action) {
    try {
        $failures = Invoke-ToolkitAction -Name $Action
        if ($failures -gt 0) { exit 2 }
        exit 0
    } catch {
        Write-Log ('{0} failed: {1}' -f $Action, $_.Exception.Message) 'Error'
        exit 1
    }
}

# Interactive menu
$quit = $false
while (-not $quit) {
    Show-Menu
    $choice = ([string](Read-Host 'Choose an option')).Trim().ToUpper()
    $pause  = $true
    try {
        if ($menuMap.ContainsKey($choice)) {
            $null = Invoke-ToolkitAction -Name $menuMap[$choice]
        } elseif ($choice -eq 'S') {
            $newSub = Read-Host 'Azure subscription ID (press Enter to keep the current one)'
            if ($newSub) { $null = Connect-Azure -TargetSubscriptionId $newSub.Trim() }
            Set-ApimInstance
        } elseif ($choice -eq 'H') {
            Show-RotationGuide
        } elseif ($choice -eq 'Q') {
            $quit  = $true
            $pause = $false
        } else {
            Write-Log 'Please choose 1-8, S, H or Q.' 'Warn'
            $pause = $false
        }
    } catch {
        Write-Log ('That action failed: {0}' -f $_.Exception.Message) 'Error'
    }
    if ($pause) { $null = Read-Host 'Press Enter to return to the menu' }
}
Write-Log ('Done. Reports are in {0}' -f $script:ReportDir) 'Ok'
