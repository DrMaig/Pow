#region 1 - Configuration
# Core configuration and feature toggles for the profile.
# Safe defaults only. Use Save-ProfileConfig to persist changes.

# Default configuration
if (-not $Global:ProfileConfig) {
    $Global:ProfileConfig = [ordered]@{
        # Display
        ShowDiagnostics   = $true
        ShowWelcome       = $true
        PromptStyle       = 'modern'   # modern, minimal, full

        # Feature toggles
        EnableLogging     = $true
        EnableAutoUpdate  = $false
        EnableTranscript  = $false
        EnableFzf         = $true

        # Paths
        LogPath           = "$HOME\Documents\PowerShell\Logs"
        TranscriptPath    = "$HOME\Documents\PowerShell\Transcripts"
        CachePath         = "$HOME\Documents\PowerShell\Cache"

        # Preferences
        Editor            = 'code'  # code, nvim, notepad++
        UpdateCheckDays   = 7
        HistorySize       = 10000

        # Deferred loader defaults (tunable)
        DeferredLoader    = @{
            WaitForProvisionSeconds = 10
            Notification = $true
            NotificationStyle = 'hint'  # 'hint' or 'verbose'
        }

        # Provisioning defaults
        Provisioning = @{
            Provider = 'Auto'   # Auto, PSResourceGet, PowerShellGet
            DryRun = $false
        }

        # Telemetry opt-in (explicit opt-in only)
        Telemetry = @{
            OptIn = $false
        }
    }
}

# Ensure directories exist (safe, idempotent)
$pathsToEnsure = @($Global:ProfileConfig.LogPath, $Global:ProfileConfig.TranscriptPath, $Global:ProfileConfig.CachePath)
foreach ($p in $pathsToEnsure) {
    try {
        if (-not (Test-Path -Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    } catch {
        # Non-fatal; log later when logging is available
    }
}

# Persist and load helpers
$script:ProfileConfigFile = Join-Path $Global:ProfileConfig.CachePath 'profile_config.json'

function Save-ProfileConfig {
    [CmdletBinding()]
    param(
        [string]$Path = $script:ProfileConfigFile
    )
    try {
        $Global:ProfileConfig | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Force -Encoding UTF8
        Write-ProfileLog "Saved profile config to $Path" -Level DEBUG
        return $true
    } catch {
        Write-Host "Failed to save profile config: $_" -ForegroundColor Yellow
        return $false
    }
}

function Invoke-ProfileConfig {
    [CmdletBinding()]
    param(
        [string]$Path = $script:ProfileConfigFile
    )
    if (-not (Test-Path $Path)) { return $false }
    try {
        $json = Get-Content -Path $Path -Raw -ErrorAction Stop
        $obj = $json | ConvertFrom-Json
        # Merge persisted values into defaults (shallow merge)
        foreach ($k in $obj.PSObject.Properties.Name) {
            $Global:ProfileConfig[$k] = $obj.$k
        }
        Write-ProfileLog "Loaded profile config from $Path" -Level DEBUG
        return $true
    } catch {
        Write-ProfileLog "Failed to load profile config: $_" -Level WARN
        return $false
    }
}

# Attempt to load persisted overrides silently
try { Invoke-ProfileConfig | Out-Null } catch {}

#endregion

#region 2 - Environment Validation
# Lightweight environment checks used by other regions.
# Safe by default; network checks are optional.

# Ensure ProfileState exists
if (-not $Global:ProfileState) {
    $Global:ProfileState = [ordered]@{
        IsAdmin = $false
        IsWindows = $false
        IsLinux = $false
        IsMacOS = $false
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        MissingCommands = @()
        HasNetwork = $null
        Provisioned = $false
        LastChecked = $null
        Notes = @()
    }
}

# Provide Test-Admin if not already defined
if (-not (Get-Command Test-Admin -ErrorAction SilentlyContinue)) {
    function Test-Admin {
        try {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal($identity)
            return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch {
            # Non-Windows platforms: check for effective UID 0
            try {
                if (Get-Command id -ErrorAction SilentlyContinue) {
                    $uid = & id -u 2>$null
                    return ([int]$uid) -eq 0
                }
                return ($null -ne $env:SUDO_UID) -or ($env:USER -eq 'root')
            } catch {
                return $false
            }
        }
    }
}

function Test-Environment {
    [CmdletBinding()]
    param(
        [switch]$SkipNetworkCheck
    )

    # Basic platform flags
    $Global:ProfileState.IsWindows = $IsWindows
    $Global:ProfileState.IsLinux = $IsLinux
    $Global:ProfileState.IsMacOS = $IsMacOS

    # PowerShell version
    $Global:ProfileState.PowerShellVersion = $PSVersionTable.PSVersion.ToString()

    # Admin check
    try {
        $Global:ProfileState.IsAdmin = Test-Admin
    } catch {
        $Global:ProfileState.IsAdmin = $false
        $Global:ProfileState.Notes += "Admin check failed: $($_.Exception.Message)"
    }

    # Common commands to verify presence
    $commandsToCheck = @('winget','choco','scoop','oh-my-posh','pwsh','code')
    $missing = @()
    foreach ($c in $commandsToCheck) {
        if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { $missing += $c }
    }
    $Global:ProfileState.MissingCommands = $missing

    # Provisioning state detection (non-blocking)
    $provFile = Join-Path $Global:ProfileConfig.CachePath 'provision_state.json'
    $Global:ProfileState.Provisioned = Test-Path $provFile

    # Optional network check (lightweight)
    if ($SkipNetworkCheck) {
        $Global:ProfileState.HasNetwork = $null
    } else {
        try {
            # Use a short DNS resolution as a lightweight network probe
            if ($IsWindows) {
                $res = Resolve-DnsName -Name 'www.microsoft.com' -ErrorAction SilentlyContinue
                $Global:ProfileState.HasNetwork = ($null -ne $res)
            } else {
                # cross-platform fallback: try a TCP connect to 1.1.1.1:53
                $sock = New-Object System.Net.Sockets.TcpClient
                $async = $sock.BeginConnect('1.1.1.1', 53, $null, $null)
                $ok = $async.AsyncWaitHandle.WaitOne(500)
                if ($ok) { $sock.EndConnect($async); $sock.Close(); $Global:ProfileState.HasNetwork = $true }
                else { $Global:ProfileState.HasNetwork = $false }
            }
        } catch {
            $Global:ProfileState.HasNetwork = $false
            $Global:ProfileState.Notes += "Network probe failed: $($_.Exception.Message)"
        }
    }

    $Global:ProfileState.LastChecked = (Get-Date).ToString('o')
    return $Global:ProfileState
}

function Show-EnvironmentReport {
    [CmdletBinding()]
    param(
        [switch]$VerboseReport
    )

    if (-not $Global:ProfileState.LastChecked) { 
        $null = Test-Environment 
    }

    Write-Host "`n=== Environment Report ===" -ForegroundColor Cyan
    Write-Host "PowerShell Version: " -NoNewline
    Write-Host $Global:ProfileState.PowerShellVersion -ForegroundColor Yellow
    
    Write-Host "Platform: " -NoNewline
    $plat = switch($true) {
        $Global:ProfileState.IsWindows { 'Windows' }
        $Global:ProfileState.IsLinux { 'Linux' }
        $Global:ProfileState.IsMacOS { 'macOS' }
        default { 'Unknown' }
    }
    Write-Host $plat -ForegroundColor Yellow
    
    Write-Host "Is Admin: " -NoNewline
    Write-Host $Global:ProfileState.IsAdmin -ForegroundColor Yellow
    
    Write-Host "Has Network: " -NoNewline
    $networkStatus = if ($null -eq $Global:ProfileState.HasNetwork) { 'Skipped' } else { $Global:ProfileState.HasNetwork }
    Write-Host $networkStatus -ForegroundColor Yellow
    
    Write-Host "Provisioned: " -NoNewline
    Write-Host $Global:ProfileState.Provisioned -ForegroundColor Yellow

    if ($Global:ProfileState.MissingCommands.Count -gt 0) {
        Write-Host "`nMissing Commands:" -ForegroundColor Red
        Write-Host ($Global:ProfileState.MissingCommands -join ', ') -ForegroundColor Yellow
    }
    else {
        Write-Host "`nMissing Commands: None" -ForegroundColor Green
    }

    if ($VerboseReport -and $Global:ProfileState.Notes.Count -gt 0) {
        Write-Host "`nNotes:" -ForegroundColor Cyan
        foreach ($n in $Global:ProfileState.Notes) {
            Write-Host " - $n" -ForegroundColor Gray
        }
    }

    Write-Host "`nLast Checked: $($Global:ProfileState.LastChecked)`n" -ForegroundColor DarkGray
}

# Run a quick environment check at profile load but skip network probe to avoid delays
try { Test-Environment -SkipNetworkCheck | Out-Null } catch {}

#endregion

#region 3 - Logging System
# Structured logging for the profile with rotation, levels, and helpers.

# Ensure log path exists
if (-not (Test-Path -Path $Global:ProfileConfig.LogPath)) {
    try { New-Item -ItemType Directory -Path $Global:ProfileConfig.LogPath -Force | Out-Null } catch {}
}

# Default log level order
$script:LogLevels = @('DEBUG','INFO','SUCCESS','WARN','ERROR')

# Current runtime log level (can be changed with Set-ProfileLogLevel)
if (-not ($Global:ProfileConfig.PSObject.Properties.Name -contains 'LogLevel')) { $Global:ProfileConfig.LogLevel = 'DEBUG' }

function Get-ProfileLogFile {
    param([string]$Prefix = 'profile')
    $date = Get-Date -Format 'yyyy-MM'
    return Join-Path $Global:ProfileConfig.LogPath "$Prefix`_$date.log"
}

function Write-ProfileLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG','SUCCESS')][string]$Level = 'INFO',
        [string]$Prefix = 'profile'
    )

    # Respect global logging toggle
    if (-not $Global:ProfileConfig.EnableLogging) { return }

    # Respect configured log level (suppress lower-priority messages)
    $currentIndex = $script:LogLevels.IndexOf($Global:ProfileConfig.LogLevel)
    $msgIndex = $script:LogLevels.IndexOf($Level)
    if ($msgIndex -lt $currentIndex) { return }

    $timestamp = (Get-Date).ToString('o')
    $entry = @{ time = $timestamp; level = $Level; message = $Message } | ConvertTo-Json -Compress

    $logFile = Get-ProfileLogFile -Prefix $Prefix
    $tempFile = "$logFile.tmp"

    try {
        # Atomic append: write to temp then append to log file
        $entry | Out-File -FilePath $tempFile -Encoding UTF8 -Append
        Add-Content -Path $logFile -Value (Get-Content -Path $tempFile -Raw)
        Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
    } catch {
        # Fallback: try simple Add-Content
        try { Add-Content -Path $logFile -Value $entry -ErrorAction SilentlyContinue } catch {}
    }

    # Console output for non-debug levels or when verbose
    if ($Level -ne 'DEBUG' -or $VerbosePreference -eq 'Continue') {
        $color = switch ($Level) {
            'INFO'    { 'Cyan' }
            'SUCCESS' { 'Green' }
            'WARN'    { 'Yellow' }
            'ERROR'   { 'Red' }
            'DEBUG'   { 'Gray' }
            default   { 'White' }
        }
        Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
    }
}

function Set-ProfileLogLevel {
    param([ValidateSet('DEBUG','INFO','SUCCESS','WARN','ERROR')][string]$Level)
    $Global:ProfileConfig.LogLevel = $Level
    Write-ProfileLog "Log level set to $Level" -Level DEBUG
}

function Get-ProfileLog {
    param(
        [string]$Prefix = 'profile',
        [int]$Lines = 200
    )
    $logFile = Get-ProfileLogFile -Prefix $Prefix
    if (-not (Test-Path $logFile)) { Write-Host "No log file found: $logFile" -ForegroundColor Yellow; return $null }
    try {
        Get-Content -Path $logFile -Tail $Lines -ErrorAction Stop
    } catch {
        Write-ProfileLog "Get-ProfileLog failed: $_" -Level WARN
        return $null
    }
}

function Watch-ProfileLog {
    param(
        [string]$Prefix = 'profile'
    )
    $logFile = Get-ProfileLogFile -Prefix $Prefix
    if (-not (Test-Path $logFile)) { Write-Host "No log file found: $logFile" -ForegroundColor Yellow; return }
    try {
        Get-Content -Path $logFile -Wait -Tail 10
    } catch {
        Write-ProfileLog "Watch-ProfileLog failed: $_" -Level WARN
    }
}

function Clear-OldProfileLogs {
    param(
        [int]$KeepMonths = 6,
        [string]$Prefix = 'profile'
    )
    try {
        $files = Get-ChildItem -Path $Global:ProfileConfig.LogPath -Filter "$Prefix*.*" -File -ErrorAction SilentlyContinue
        $cutoff = (Get-Date).AddMonths(-$KeepMonths)
        foreach ($f in $files) {
            # Parse yyyy-MM from filename
            if ($f.BaseName -match '\d{4}-\d{2}') {
                $ym = $Matches[0]
                $dt = [datetime]::ParseExact($ym,'yyyy-MM',$null)
                if ($dt -lt $cutoff) { Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue }
            }
        }
        Write-ProfileLog "Log cleanup completed (keep $KeepMonths months)" -Level DEBUG
    } catch {
        Write-ProfileLog "Clear-OldProfileLogs failed: $_" -Level WARN
    }
}

# Lightweight helper to write structured event entries (for provisioning, deferred loader, etc.)
function Write-ProfileEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Event,
        [hashtable]$Data = @{},
        [string]$Prefix = 'events'
    )
    $payload = [ordered]@{
        time = (Get-Date).ToString('o')
        event = $Event
        data = $Data
    }
    $payload | ConvertTo-Json -Depth 6 | Out-File -FilePath (Get-ProfileLogFile -Prefix $Prefix) -Append -Encoding UTF8
}

#endregion

#region 4 - Security and Repositories
# Helpers to manage trusted PowerShell repositories and consent flows.
# Safe by default: no automatic registration without explicit consent.

# Path to persist trusted repo metadata
$script:TrustedRepoFile = Join-Path $Global:ProfileConfig.CachePath 'trusted_repos.json'

function Get-PSRepositorySafe {
    [CmdletBinding()]
    param(
        [string]$Name = 'PSGallery'
    )
    try {
        return Get-PSRepository -Name $Name -ErrorAction SilentlyContinue
    } catch {
        return $null
    }
}

function Test-RepositoryReachable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceLocation,
        [int]$TimeoutSeconds = 5
    )
    try {
        # Lightweight HTTP HEAD probe if Invoke-WebRequest available
        if (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue) {
            $resp = Invoke-WebRequest -Uri $SourceLocation -Method Head -TimeoutSec $TimeoutSeconds -ErrorAction SilentlyContinue
            return $resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400
        } else {
            # Fallback: DNS/TCP probe to host
            $uri = [uri]$SourceLocation
            $HostName = $uri.Host
            $sock = New-Object System.Net.Sockets.TcpClient
            $async = $sock.BeginConnect($HostName, 443, $null, $null)
            $ok = $async.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000)
            if ($ok) { $sock.EndConnect($async); $sock.Close(); return $true } else { return $false }
        }
    } catch {
        return $false
    }
}

function Register-RepositoryInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$SourceLocation,
        [PSCredential]$Credential = $null,
        [ValidateSet('Trusted','Untrusted')][string]$InstallationPolicy = 'Trusted'
    )

    Write-Host "Repository registration requested:" -ForegroundColor Cyan
    Write-Host "  Name: $Name" -ForegroundColor Yellow
    Write-Host "  Source: $SourceLocation" -ForegroundColor Yellow
    Write-Host "  InstallationPolicy: $InstallationPolicy" -ForegroundColor Yellow
    Write-Host "`nRegister this repository? (Y/N): " -NoNewline -ForegroundColor Yellow

    $resp = Read-Host
    if ($resp -ne 'Y') {
        Write-ProfileLog "User declined to register repository $Name" -Level INFO
        return $false
    }

    try {
        if ($Credential) {
            Register-PSRepository -Name $Name -SourceLocation $SourceLocation -InstallationPolicy $InstallationPolicy -Credential $Credential -ErrorAction Stop
        } else {
            Register-PSRepository -Name $Name -SourceLocation $SourceLocation -InstallationPolicy $InstallationPolicy -ErrorAction Stop
        }
        Write-ProfileLog "Registered repository $Name -> $SourceLocation" -Level INFO
        # Persist to trusted list
        $entry = [ordered]@{
            Name = $Name
            SourceLocation = $SourceLocation
            InstallationPolicy = $InstallationPolicy
            RegisteredAt = (Get-Date).ToString('o')
        }
        Save-TrustedRepoEntry -Entry $entry
        return $true
    } catch {
        Write-ProfileLog "Failed to register repository $Name : $_" -Level ERROR
        return $false
    }
}

function Save-TrustedRepoEntry {
    param([Parameter(Mandatory = $true)][hashtable]$Entry)
    try {
        $repos = @{}
        if (Test-Path $script:TrustedRepoFile) {
            try { $repos = Get-Content $script:TrustedRepoFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue } catch { $repos = @{} }
        }
        $repos[$Entry.Name] = $Entry
        $repos | ConvertTo-Json -Depth 6 | Set-Content -Path $script:TrustedRepoFile -Force -Encoding UTF8
        Write-ProfileLog "Saved trusted repo entry: $($Entry.Name)" -Level DEBUG
        return $true
    } catch {
        Write-ProfileLog "Failed to save trusted repo entry: $_" -Level WARN
        return $false
    }
}

function Get-TrustedRepos {
    try {
        if (-not (Test-Path $script:TrustedRepoFile)) { return @{} }
        $json = Get-Content $script:TrustedRepoFile -Raw -ErrorAction Stop
        return $json | ConvertFrom-Json
    } catch {
        Write-ProfileLog "Get-TrustedRepos failed: $_" -Level WARN
        return @{}
    }
}

function Set-TrustedRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$SourceLocation,
        [PSCredential]$Credential = $null,
        [ValidateSet('Trusted','Untrusted')][string]$InstallationPolicy = 'Trusted',
        [switch]$ForceRegister
    )

    # If repository already exists, ensure policy matches
    $existing = Get-PSRepositorySafe -Name $Name
    if ($existing) {
        if ($existing.SourceLocation -ne $SourceLocation) {
            Write-ProfileLog "Repository $Name exists but source differs. Existing: $($existing.SourceLocation) Requested: $SourceLocation" -Level WARN
            if (-not $ForceRegister) { return $false }
        }
        # If installation policy is not Trusted, warn and prompt if ForceRegister
        if ($existing.InstallationPolicy -ne $InstallationPolicy) {
            Write-ProfileLog "Repository $Name has InstallationPolicy $($existing.InstallationPolicy). Requested: $InstallationPolicy" -Level WARN
            if (-not $ForceRegister) { return $true }
        }
        Write-ProfileLog "Repository $Name already registered" -Level DEBUG
        return $true
    }

    # Validate reachability before prompting
    $reachable = Test-RepositoryReachable -SourceLocation $SourceLocation -TimeoutSeconds 5
    if (-not $reachable) {
        Write-ProfileLog "Repository $Name at $SourceLocation is not reachable" -Level WARN
        # Still allow registration if user forces it
        if (-not $ForceRegister) { return $false }
    }

    # Prompt user to register (explicit consent)
    return Register-RepositoryInteractive -Name $Name -SourceLocation $SourceLocation -Credential $Credential -InstallationPolicy $InstallationPolicy
}

function Test-RepositoryModules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSeconds = 5
    )
    # Quick check: can we find module metadata from the repository?
    try {
        $repo = Get-PSRepository -Name $Name -ErrorAction Stop
        # Try to find any module metadata (Find-Module requires PowerShellGet)
        if (Get-Command Find-Module -ErrorAction SilentlyContinue) {
            $meta = Find-Module -Repository $Name -ErrorAction SilentlyContinue | Select-Object -First 1
            return $null -ne $meta
        } else {
            # If Find-Module not available, rely on reachability
            return Test-RepositoryReachable -SourceLocation $repo.SourceLocation -TimeoutSeconds $TimeoutSeconds
        }
    } catch {
        Write-ProfileLog "Test-RepositoryModules failed for $Name : $_" -Level WARN
        return $false
    }
}

# Guidance helper (non-destructive) to show recommended action for a repo URL
function Show-RepositoryGuidance {
    param([Parameter(Mandatory = $true)][string]$SourceLocation)
    Write-Host "Repository guidance for: $SourceLocation" -ForegroundColor Cyan
    Write-Host " - Recommended: register with InstallationPolicy 'Trusted' and avoid SkipPublisherCheck." -ForegroundColor Yellow
    Write-Host " - For private repos: provide PSCredential and register via Register-PSRepository." -ForegroundColor Yellow
    Write-Host " - For air-gapped environments: use local file shares or internal artifact feeds." -ForegroundColor Yellow
}

#endregion

#region 5 - Module Management
# Module management helpers: cached installed-module lookup and planning helpers.
# Safe: no installs performed here. Provisioning consumes the plan.

# Cache file for installed module metadata
$script:InstalledModulesCacheFile = Join-Path $Global:ProfileConfig.CachePath 'installed_modules_cache.json'
$script:InstalledModulesCacheTtlSeconds = 300  # 5 minutes

function Update-InstalledModulesCache {
    [CmdletBinding()]
    param(
        [switch]$Force
    )
    try {
        $needRefresh = $true
        if (-not $Force -and (Test-Path $script:InstalledModulesCacheFile)) {
            $age = (Get-Date) - (Get-Item $script:InstalledModulesCacheFile).LastWriteTime
            if ($age.TotalSeconds -lt $script:InstalledModulesCacheTtlSeconds) { $needRefresh = $false }
        }
        if (-not $needRefresh) { return $true }

        $installed = @{}
        try {
            $mods = Get-InstalledModule -ErrorAction SilentlyContinue
            foreach ($m in $mods) {
                $installed[$m.Name] = [ordered]@{
                    Name = $m.Name
                    Version = $m.Version.ToString()
                    Repository = $m.Repository
                    InstalledAt = (Get-Date).ToString('o')
                }
            }
        } catch {
            # If Get-InstalledModule not available, fall back to Get-Module -ListAvailable
            $mods = Get-Module -ListAvailable
            foreach ($m in $mods) {
                $installed[$m.Name] = [ordered]@{
                    Name = $m.Name
                    Version = ($m.Version).ToString()
                    Repository = $null
                    InstalledAt = (Get-Date).ToString('o')
                }
            }
        }

        $installed | ConvertTo-Json -Depth 6 | Set-Content -Path $script:InstalledModulesCacheFile -Encoding UTF8 -Force
        Write-ProfileLog "Updated installed modules cache ($($installed.Keys.Count) entries)" -Level DEBUG
        return $true
    } catch {
        Write-ProfileLog "Update-InstalledModulesCache failed: $_" -Level WARN
        return $false
    }
}

function Get-InstalledModulesCache {
    [CmdletBinding()]
    param(
        [switch]$Refresh
    )
    if ($Refresh) { Update-InstalledModulesCache -Force | Out-Null }
    if (-not (Test-Path $script:InstalledModulesCacheFile)) {
        Update-InstalledModulesCache | Out-Null
    }
    try {
        $json = Get-Content -Path $script:InstalledModulesCacheFile -Raw -ErrorAction Stop
        return $json | ConvertFrom-Json
    } catch {
        Write-ProfileLog "Get-InstalledModulesCache failed: $_" -Level WARN
        return @{}
    }
}

function Get-InstalledModuleVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    $cache = Get-InstalledModulesCache
    if ($null -ne $cache -and $cache.PSObject.Properties.Name -contains $Name) {
        try { return if ($cache.$Name.Version) { [version]$cache.$Name.Version } else { $null } } catch { return $null }
    }
    # Fallback: query live
    try {
        $m = Get-InstalledModule -Name $Name -ErrorAction SilentlyContinue
        if ($m) { return [version]$m.Version }
    } catch {
        $mod = Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($mod) { return [version]$mod.Version }
    }
    return $null
}

function Compare-Version {
    param(
        [Parameter(Mandatory = $true)][version]$Current,
        [Parameter(Mandatory = $true)][version]$Required
    )
    if ($Current -lt $Required) { return -1 }
    if ($Current -gt $Required) { return 1 }
    return 0
}

function Get-ModulePlan {
    <#
    .SYNOPSIS
      Compute an idempotent plan for modules.

    .DESCRIPTION
      Accepts an array of desired module hashtables:
        @{ Name='PSReadLine'; MinVersion='2.2.6'; Required=$true }
      Returns an ordered list of planned actions:
        @{ Name='PSReadLine'; Action='Install'|'Update'|'Skip'|'NoneNeeded'; CurrentVersion='x'; RequiredVersion='y' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$DesiredModules
    )

    # Ensure cache is reasonably fresh
    Update-InstalledModulesCache -Force:$false | Out-Null
    $cache = Get-InstalledModulesCache

    $plan = @()
    foreach ($m in $DesiredModules) {
        $name = $m.Name
        $minVersion = if (($m.PSObject.Properties.Name -contains 'MinVersion') -and $m.MinVersion) { [version]$m.MinVersion } else { $null }
        $isRequired = $true
        if ($m.PSObject.Properties.Name -contains 'Required') { $isRequired = [bool]$m.Required }

        $currentVersion = $null
        if ($cache -and $cache.PSObject.Properties.Name -contains $name) {
            try { $currentVersion = if ($cache.$name.Version) { [version]$cache.$name.Version } else { $null } } catch { $currentVersion = $null }
        } else {
            # fallback live check
            $cv = Get-InstalledModule -Name $name -ErrorAction SilentlyContinue
            if ($cv) { $currentVersion = [version]$cv.Version }
        }

        $action = 'NoneNeeded'
        if (-not $currentVersion) {
            if ($isRequired) { $action = 'Install' } else { $action = 'Skip' }
        } elseif ($minVersion) {
            $cmp = Compare-Version -Current $currentVersion -Required $minVersion
            if ($cmp -lt 0) { $action = 'Update' } else { $action = 'NoneNeeded' }
        } else {
            $action = 'NoneNeeded'
        }

        $plan += [ordered]@{
            Name = $name
            CurrentVersion = if ($currentVersion) { $currentVersion.ToString() } else { $null }
            RequiredVersion = if ($minVersion) { $minVersion.ToString() } else { $null }
            Required = $isRequired
            Action = $action
        }
    }

    return $plan
}

# Convenience wrapper used by profile: compute plan for profile's module list
function Get-ProfileModulePlan {
    [CmdletBinding()]
    param()
    $modules = @(
        @{ Name = 'PSReadLine'; MinVersion = '2.2.6'; Required = $true }
        @{ Name = 'Terminal-Icons'; Required = $false }
        @{ Name = 'PSFzf'; Required = $Global:ProfileConfig.EnableFzf }
    )
    return Get-ModulePlan -DesiredModules $modules
}

# Small helper to pretty-print the plan
function Show-ModulePlan {
    param([array]$Plan)
    if (-not $Plan) { $Plan = Get-ProfileModulePlan }
    $table = $Plan | Select-Object Name, CurrentVersion, RequiredVersion, Required, Action
    $table | Format-Table -AutoSize
}

# Removed blocking early call to Wait-ForDeferredModules to avoid startup stall

#endregion

#region 6 - Deferred Module Loader
# Robust deferred loader with completion notification and optional spinner.
$script:DeferredModules = @('Terminal-Icons','PSFzf')
$script:ProvisionStateFile = Join-Path $Global:ProfileConfig.CachePath 'provision_state.json'

$Global:DeferredModulesStatus = [ordered]@{
    Started = $false
    Completed = $false
    StartedAt = $null
    CompletedAt = $null
    Modules = @{}
    NotificationShown = $false
}

# Default deferred loader config (can be tuned in Configuration region)
if (-not ($Global:ProfileConfig.PSObject.Properties.Name -contains 'DeferredLoader')) {
    $Global:ProfileConfig.DeferredLoader = @{
        WaitForProvisionSeconds = 10
        Notification = $true
        NotificationStyle = 'hint'  # 'hint' or 'verbose'
    }
}

function Wait-ForDeferredModules {
    param([int]$TimeoutSeconds = 30)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $Global:DeferredModulesStatus.Completed -and $sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Milliseconds 200
    }
    return $Global:DeferredModulesStatus.Completed
}

function Invoke-DeferredImport {
    param([string]$Name)
    try {
        if (Get-Module -ListAvailable -Name $Name) {
            Import-Module -Name $Name -Global -ErrorAction Stop
            $Global:DeferredModulesStatus.Modules[$Name] = @{ Status = 'Imported'; Time = (Get-Date).ToString('o') }
            Write-ProfileLog "Deferred import succeeded: $Name" -Level DEBUG
            return $true
        } else {
            $Global:DeferredModulesStatus.Modules[$Name] = @{ Status = 'NotFound'; Time = (Get-Date).ToString('o') }
            Write-ProfileLog "Deferred import skipped (not found): $Name" -Level DEBUG
            return $false
        }
    } catch {
        $Global:DeferredModulesStatus.Modules[$Name] = @{ Status = 'Failed'; Error = $_.ToString(); Time = (Get-Date).ToString('o') }
        Write-ProfileLog "Deferred import failed: $Name $_" -Level WARN
        return $false
    }
}

# Spinner helpers for verbose mode
$script:DeferredSpinnerChars = @('|','/','-','\')
function Start-DeferredSpinner {
    param([ref]$StopFlag)
    $i = 0
    while (-not $StopFlag.Value) {
        $char = $script:DeferredSpinnerChars[$i % $script:DeferredSpinnerChars.Length]
        Write-Host -NoNewline "`r[Loading] $char " -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 120
        $i++
    }
    Write-Host "`r" -NoNewline
}

function Show-DeferredLoaderNotification {
    param()
    if (-not $Global:ProfileConfig.DeferredLoader.Notification) { return }
    if ($Global:DeferredModulesStatus.NotificationShown) { return }

    $imported = $Global:DeferredModulesStatus.Modules.GetEnumerator() |
        Where-Object { $_.Value.Status -eq 'Imported' } | ForEach-Object { $_.Key }

    $failed = $Global:DeferredModulesStatus.Modules.GetEnumerator() |
        Where-Object { $_.Value.Status -eq 'Failed' } | ForEach-Object { $_.Key }

    if ($Global:ProfileConfig.DeferredLoader.NotificationStyle -eq 'verbose') {
        Write-Host "`n[Deferred Loader] Modules imported: $($imported -join ', ')" -ForegroundColor Green
        if ($failed) { Write-Host "[Deferred Loader] Failed: $($failed -join ', ')" -ForegroundColor Yellow }
    } else {
        if ($imported) {
            Write-Host "Hint: deferred modules loaded: $($imported -join ', ')" -ForegroundColor DarkGray
        } elseif ($failed) {
            Write-Host "Hint: deferred module imports encountered issues" -ForegroundColor DarkGray
        }
    }

    $Global:DeferredModulesStatus.NotificationShown = $true
}

if (-not (Get-EventSubscriber -SourceIdentifier 'PowerShell.OnIdle' -ErrorAction SilentlyContinue)) {
    $null = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -MaxTriggerCount 1 -Action {
        $Global:DeferredModulesStatus.Started = $true
        $Global:DeferredModulesStatus.StartedAt = (Get-Date).ToString('o')

        # Wait briefly for provisioning state if present
        $waitSeconds = $Global:ProfileConfig.DeferredLoader.WaitForProvisionSeconds
        $provisionTimeout = [DateTime]::UtcNow.AddSeconds($waitSeconds)
        while ((Test-Path $using:ProvisionStateFile) -and (Get-Item $using:ProvisionStateFile).Length -eq 0 -and ([DateTime]::UtcNow -lt $provisionTimeout)) {
            Start-Sleep -Milliseconds 200
        }

        if (Test-Path $using:ProvisionStateFile) {
            try { $null = Get-Content $using:ProvisionStateFile -Raw -ErrorAction SilentlyContinue } catch {}
        }

        # Start spinner if verbose
        $stop = [ref]$false
        $spinnerTask = $null
        try {
            if ($Global:ProfileConfig.DeferredLoader.NotificationStyle -eq 'verbose') {
                $spinnerTask = [System.Threading.Tasks.Task]::Run([Action]{ Start-DeferredSpinner -StopFlag $stop })
            }
            foreach ($m in $using:DeferredModules) {
                Invoke-DeferredImport -Name $m
            }
        } finally {
            $stop.Value = $true
            if ($spinnerTask -ne $null) { Start-Sleep -Milliseconds 150 }
        }

        $Global:DeferredModulesStatus.Completed = $true
        $Global:DeferredModulesStatus.CompletedAt = (Get-Date).ToString('o')
        Write-ProfileLog "Deferred module loader completed" -Level DEBUG

        try { Show-DeferredLoaderNotification } catch { Write-ProfileLog "Deferred loader notification failed: $_" -Level DEBUG }
    } -MessageData @{ Name = 'Profile.DeferredLoader' } -ErrorAction SilentlyContinue
}
#endregion

#region 9 - PSReadLine Configuration
# Safe PSReadLine configuration and helpers.
# Only applies settings if PSReadLine is present; does not install modules.

# Default PSReadLine options (can be tuned via ProfileConfig)
if (-not ($Global:ProfileConfig.PSObject.Properties.Name -contains 'PSReadLine')) {
    $Global:ProfileConfig.PSReadLine = @{
        EditMode = 'Windows'            # Windows or Emacs
        HistorySize = $Global:ProfileConfig.HistorySize
        HistorySavePath = Join-Path $Global:ProfileConfig.CachePath 'PSReadLine_history.txt'
        MaximumKillRingCount = 10
        PredictionSource = 'None'       # None, History, Plugin (depends on PSReadLine version)
        BellStyle = 'None'              # None, Audible, Visible
        Colors = @{
            Command = 'White'
            Parameter = 'DarkCyan'
            String = 'DarkYellow'
            Comment = 'DarkGray'
            Error = 'Red'
        }
        KeyBindings = @{
            'Ctrl+R' = 'ReverseSearchHistory'
            'Ctrl+S' = 'ForwardSearchHistory'
            'Ctrl+L' = 'ClearScreen'
            'Alt+.'  = 'CompleteNext'   # yank last argument
        }
    }
}

function Set-PSReadLineDefaults {
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    if (-not (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue)) {
        Write-ProfileLog "PSReadLine not available; skipping PSReadLine configuration" -Level DEBUG
        return $false
    }

    try {
        # Basic options
        Set-PSReadLineOption -EditMode $Global:ProfileConfig.PSReadLine.EditMode
        Set-PSReadLineOption -MaximumHistoryCount $Global:ProfileConfig.PSReadLine.HistorySize
        Set-PSReadLineOption -HistorySavePath $Global:ProfileConfig.PSReadLine.HistorySavePath
        Set-PSReadLineOption -BellStyle $Global:ProfileConfig.PSReadLine.BellStyle

        # Prediction source if supported
        if ($Global:ProfileConfig.PSReadLine.PredictionSource -and (Get-Command Get-PSReadLineOption -ErrorAction SilentlyContinue)) {
            try {
                Set-PSReadLineOption -PredictionSource $Global:ProfileConfig.PSReadLine.PredictionSource -ErrorAction SilentlyContinue
            } catch {
                Write-ProfileLog "PSReadLine prediction option not supported in this version" -Level DEBUG
            }
        }

        # Colors applied as a hashtable if supported
        try {
            $colors = $Global:ProfileConfig.PSReadLine.Colors
            if ($colors) {
                Set-PSReadLineOption -Colors $colors -ErrorAction SilentlyContinue
            }
        } catch {}

        # Key bindings
        foreach ($kb in $Global:ProfileConfig.PSReadLine.KeyBindings.PSObject.Properties) {
            try {
                Set-PSReadLineKeyHandler -Key $kb.Name -Function $kb.Value -ErrorAction SilentlyContinue
            } catch {
                Write-ProfileLog "Failed to set PSReadLine key binding $($kb.Name) -> $($kb.Value): $_" -Level DEBUG
            }
        }

        # Kill ring size if supported
        try {
            Set-PSReadLineOption -MaximumKillRingCount $Global:ProfileConfig.PSReadLine.MaximumKillRingCount -ErrorAction SilentlyContinue
        } catch {}

        Write-ProfileLog "PSReadLine defaults applied" -Level INFO
        return $true
    } catch {
        Write-ProfileLog "Set-PSReadLineDefaults failed: $_" -Level WARN
        return $false
    }
}

# Apply defaults at profile load for interactive sessions
# Apply defaults at interactive startup - check for interactive session
if ($Host.Name -ne 'ServerRemoteHost' -and $null -ne $Host.UI.RawUI) {
    try { Set-PSReadLineDefaults | Out-Null } catch {}
}

# Helper to show current PSReadLine settings
function Show-PSReadLineConfig {
    [CmdletBinding()]
    param()
    if (-not (Get-Command Get-PSReadLineOption -ErrorAction SilentlyContinue)) {
        Write-Host "PSReadLine not available" -ForegroundColor Yellow
        return
    }
    try {
        $opts = Get-PSReadLineOption
        $opts | Format-List
    } catch {
        Write-ProfileLog "Show-PSReadLineConfig failed: $_" -Level DEBUG
    }
}

#endregion
#region 10 - Oh-My-Posh Prompt
# Safe oh-my-posh initialization and fallback prompt.
# Does not install anything automatically; use Invoke-Provisioning to install.

# Default prompt config (tunable via ProfileConfig)
if (-not ($Global:ProfileConfig.PSObject.Properties.Name -contains 'OhMyPosh')) {
    $Global:ProfileConfig.OhMyPosh = @{
        Enabled = $true
        Theme = 'paradox'           # default theme name; change to your preferred theme
        BinaryName = 'oh-my-posh'   # binary name when installed via winget/winget/PSResource
        ModuleName = 'oh-my-posh'   # module name when installed as a PowerShell module
        InitArgs = ''               # extra args to pass to init if needed
        FallbackPrompt = $true
    }
}

# Minimal fallback prompt function (keeps prompt informative and fast)
function Grant-Fallback {
    $cwd = (Get-Location).Path
    $user = $env:USERNAME
    $time = (Get-Date).ToString('HH:mm')
    "$user@$env:COMPUTERNAME $time $cwd> "
}

# Try to initialize oh-my-posh safely
function Initialize-OhMyPosh {
    [CmdletBinding()]
    param(
        [string]$Theme = $Global:ProfileConfig.OhMyPosh.Theme
    )

    # Resolve theme path for the binary if a bare name is provided
    function Resolve-OMPConfigPath([string]$t) {
        if ([string]::IsNullOrWhiteSpace($t)) { return $null }
        if (Test-Path -LiteralPath $t) { return (Resolve-Path -LiteralPath $t).Path }
        $name = if ($t.ToLower().EndsWith('.omp.json')) { $t } else { "$t.omp.json" }
        if ($env:POSH_THEMES_PATH) {
            $p1 = Join-Path $env:POSH_THEMES_PATH $name
            if (Test-Path -LiteralPath $p1) { return (Resolve-Path -LiteralPath $p1).Path }
        }
        $base = $PSScriptRoot
        if (-not $base) { $base = Join-Path $HOME 'Documents/PowerShell' }
        $p2 = Join-Path (Join-Path $base 'themes') $name
        if (Test-Path -LiteralPath $p2) { return (Resolve-Path -LiteralPath $p2).Path }
        return $null
    }

    # Prefer binary if available
    $binary = Get-Command $Global:ProfileConfig.OhMyPosh.BinaryName -ErrorAction SilentlyContinue
    $module = Get-Module -ListAvailable -Name $Global:ProfileConfig.OhMyPosh.ModuleName -ErrorAction SilentlyContinue

    if ($binary) {
        try {
            $cfg = Resolve-OMPConfigPath -t $Theme
            if (-not $cfg) { $cfg = $Theme }
            $initCmd = "$($Global:ProfileConfig.OhMyPosh.BinaryName) init pwsh --config '$cfg' $($Global:ProfileConfig.OhMyPosh.InitArgs)"
            # Use Invoke-Expression to run the init output (oh-my-posh prints shell init code)
            $initCmd | Invoke-Expression
            Write-ProfileLog "oh-my-posh initialized via binary ($($binary.Source)) with config $cfg" -Level INFO
            return $true
        } catch {
            Write-ProfileLog "oh-my-posh binary init failed: $_" -Level WARN
            return $false
        }
    }

    if ($module) {
        try {
            # If module exposes Init command or function, attempt to call it; otherwise import and set prompt via theme file
            Import-Module -Name $Global:ProfileConfig.OhMyPosh.ModuleName -Global -ErrorAction Stop
            if (Get-Command 'Set-PoshPrompt' -ErrorAction SilentlyContinue) {
                Set-PoshPrompt -Theme $Theme
                Write-ProfileLog "oh-my-posh initialized via module with theme $Theme" -Level INFO
                return $true
            } else {
                # Some module versions provide 'oh-my-posh' binary only; fallback to binary path if available
                Write-ProfileLog "oh-my-posh module loaded but no Set-PoshPrompt found" -Level DEBUG
                return $false
            }
        } catch {
            Write-ProfileLog "oh-my-posh module init failed: $_" -Level WARN
            return $false
        }
    }

    Write-ProfileLog "oh-my-posh not found (binary or module)" -Level DEBUG
    return $false
}

# Public helper to enable/install oh-my-posh via provisioning (non-destructive wrapper)
function Enable-OhMyPosh {
    [CmdletBinding()]
    param(
        [switch]$Force,
        [ValidateSet('Auto','PSResourceGet','PowerShellGet')][string]$Provider = 'Auto'
    )
    Write-ProfileLog "Enable-OhMyPosh requested (Force=$Force, Provider=$Provider)" -Level INFO

    # If already present, attempt init
    if (Get-Command $Global:ProfileConfig.OhMyPosh.BinaryName -ErrorAction SilentlyContinue -or (Get-Module -ListAvailable -Name $Global:ProfileConfig.OhMyPosh.ModuleName -ErrorAction SilentlyContinue)) {
        Initialize-OhMyPosh -Theme $Global:ProfileConfig.OhMyPosh.Theme | Out-Null
        return $true
    }

    # Otherwise, call provisioning helper to install (bootstrap.ps1 should support installing oh-my-posh)
    if (-not (Get-Command Invoke-Provisioning -ErrorAction SilentlyContinue)) {
        Write-ProfileLog "Invoke-Provisioning helper not available; cannot install oh-my-posh from profile" -Level WARN
        Write-Host "Provisioning helper not available. Run bootstrap.ps1 manually to install oh-my-posh." -ForegroundColor Yellow
        return $false
    }

    # Run provisioning in a new process via wrapper; non-interactive installs should be done with -Force
    if ($Force) {
        Invoke-Provisioning -Force -Provider $Provider | Out-Null
    } else {
        Invoke-Provisioning -Provider $Provider | Out-Null
    }

    # Refresh installed modules cache and attempt init
    try { Update-InstalledModulesCache -Force | Out-Null } catch {}
    Initialize-OhMyPosh -Theme $Global:ProfileConfig.OhMyPosh.Theme | Out-Null
    return $true
}

# Apply prompt at interactive startup
if ($Global:ProfileConfig.OhMyPosh.Enabled) {
    try {
        $ok = Initialize-OhMyPosh -Theme $Global:ProfileConfig.OhMyPosh.Theme
        if (-not $ok -and $Global:ProfileConfig.OhMyPosh.FallbackPrompt) {
            # Set fallback prompt function
            function Prompt { Grant-Fallback }
            Write-ProfileLog "Using fallback prompt (oh-my-posh not available)" -Level DEBUG
        }
    } catch {
        Write-ProfileLog "Oh-My-Posh initialization encountered an error: $_" -Level WARN
        if ($Global:ProfileConfig.OhMyPosh.FallbackPrompt) { function Prompt { Grant-Fallback } }
    }
} else {
    # If disabled, ensure fallback prompt is used
    if ($Global:ProfileConfig.OhMyPosh.FallbackPrompt) { function Prompt { Grant-Fallback } }
}
#endregion
#region 11 - Aliases
# Safe alias definitions guarded by command availability and profile toggles.
# Aliases are non-destructive and only created if the target command exists.

# Default alias config (tunable via ProfileConfig)
if (-not ($Global:ProfileConfig.PSObject.Properties.Name -contains 'Aliases')) {
    $Global:ProfileConfig.Aliases = @{
        EnableCommon = $true
        EnableFileOps = $true
        Custom = @{}  # user-defined alias map: @{ 'll' = 'Get-ChildItem -Force' }
    }
}

# Helper: create alias only if target command exists
function New-ProfileAlias {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value,
        [switch]$Force
    )
    try {
        # If alias exists and not forced, skip
        if (Get-Alias -Name $Name -ErrorAction SilentlyContinue -WarningAction SilentlyContinue) {
            if (-not $Force) {
                Write-ProfileLog "Alias $Name already exists; skipping" -Level DEBUG
                return $false
            } else {
                Remove-Item Alias:$Name -ErrorAction SilentlyContinue
            }
        }

        # If Value is a simple command name, ensure it exists
        $cmdName = ($Value -split '\s+')[0]
        if (Get-Command $cmdName -ErrorAction SilentlyContinue) {
            Set-Alias -Name $Name -Value $cmdName -Force
            Write-ProfileLog "Created alias $Name -> $cmdName" -Level INFO
            return $true
        } else {
            # For complex values (with args), create a function wrapper
            $funcName = "alias_${Name}"
            if (Get-Command $funcName -ErrorAction SilentlyContinue) { Remove-Item Function:$funcName -ErrorAction SilentlyContinue }
            $scriptBlock = [ScriptBlock]::Create($Value)
            Set-Item -Path Function:\$funcName -Value $scriptBlock -Force
            Set-Alias -Name $Name -Value $funcName -Force
            Write-ProfileLog "Created alias $Name -> $Value (function wrapper)" -Level INFO
            return $true
        }
    } catch {
        Write-ProfileLog "New-ProfileAlias failed for $Name : $_" -Level WARN
        return $false
    }
}

# Helper: list profile-defined aliases (not system defaults)
function Get-ProfileAliases {
    [CmdletBinding()]
    param()
    $aliases = Get-Alias | Where-Object { $_.Options -ne 'ReadOnly' } | Sort-Object Name
    $aliases | Format-Table Name, Definition -AutoSize
}

# Helper: remove alias created by profile
function Remove-ProfileAlias {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    try {
        if (Get-Alias -Name $Name -ErrorAction SilentlyContinue) {
            Remove-Item Alias:$Name -ErrorAction Stop
            Write-ProfileLog "Removed alias $Name" -Level INFO
            return $true
        } else {
            Write-ProfileLog "Alias $Name not found" -Level DEBUG
            return $false
        }
    } catch {
        Write-ProfileLog "Remove-ProfileAlias failed for $Name : $_" -Level WARN
        return $false
    }
}

# Define common aliases (guarded)
if ($Global:ProfileConfig.Aliases.EnableCommon) {
    New-ProfileAlias -Name ll -Value 'Get-ChildItem -Force' | Out-Null
    New-ProfileAlias -Name la -Value 'Get-ChildItem -Force -Directory' | Out-Null
    New-ProfileAlias -Name .. -Value 'Set-Location ..' | Out-Null
    New-ProfileAlias -Name ... -Value 'Set-Location ..\..' | Out-Null
    # Removed invalid alias name '~'
    New-ProfileAlias -Name c -Value 'Clear-Host' | Out-Null
}


# File operation aliases
if ($Global:ProfileConfig.Aliases.EnableFileOps) {
    New-ProfileAlias -Name md -Value 'New-Item -ItemType Directory' | Out-Null
    New-ProfileAlias -Name nf -Value 'New-Item -ItemType File' | Out-Null
    New-ProfileAlias -Name rmf -Value 'Remove-Item -Force' | Out-Null
}

# Load user custom aliases from ProfileConfig.Custom
try {
    foreach ($k in $Global:ProfileConfig.Aliases.Custom.Keys) {
        $v = $Global:ProfileConfig.Aliases.Custom[$k]
        New-ProfileAlias -Name $k -Value $v | Out-Null
    }
} catch {
    Write-ProfileLog "Failed to load custom aliases: $_" -Level DEBUG
}

#endregion

#============================================================================== 
# Regions 12 - 20: File Operations through Additional Utilities
# Safe, idempotent, and refactored implementations. No network installs or destructive
# actions run at profile load. Use explicit helpers to perform changes.
#==============================================================================

#region 12 - File Operations
# File and path helpers with validation and logging.

function Initialize-Path {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )
    try {
        if (-not (Test-Path -Path $Path)) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Write-ProfileLog "Created path: $Path" -Level SUCCESS
        } else {
            Write-ProfileLog "Path exists: $Path" -Level DEBUG
        }
        return $true
    } catch {
        Write-ProfileLog "Initialize-Path failed for $Path : $_" -Level WARN
        return $false
    }
}

function New-File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Content = ''
    )
    try {
        $dir = Split-Path -Parent $Path
        if ($dir) { Initialize-Path -Path $dir | Out-Null }
        New-Item -ItemType File -Path $Path -Force | Out-Null
        if ($Content) { Set-Content -Path $Path -Value $Content -Encoding UTF8 -Force }
        Write-ProfileLog "Created file: $Path" -Level SUCCESS
        return $true
    } catch {
        Write-ProfileLog "New-File failed for $Path : $_" -Level WARN
        return $false
    }
}

function Copy-FileSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Overwrite
    )
    try {
        if (-not (Test-Path $Source)) { Write-ProfileLog "Copy-FileSafe: source not found $Source" -Level WARN; return $false }
        $destDir = Split-Path -Parent $Destination
        if ($destDir) { Initialize-Path -Path $destDir | Out-Null }
        Copy-Item -Path $Source -Destination $Destination -Force:$Overwrite -ErrorAction Stop
        Write-ProfileLog "Copied $Source -> $Destination" -Level SUCCESS
        return $true
    } catch {
        Write-ProfileLog "Copy-FileSafe failed: $_" -Level WARN
        return $false
    }
}

function Move-FileSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Overwrite
    )
    try {
        if (-not (Test-Path $Source)) { Write-ProfileLog "Move-FileSafe: source not found $Source" -Level WARN; return $false }
        $destDir = Split-Path -Parent $Destination
        if ($destDir) { Initialize-Path -Path $destDir | Out-Null }
        if (Test-Path $Destination -and -not $Overwrite) { Write-ProfileLog "Move-FileSafe: destination exists and overwrite not set" -Level WARN; return $false }
        Move-Item -Path $Source -Destination $Destination -Force:$Overwrite -ErrorAction Stop
        Write-ProfileLog "Moved $Source -> $Destination" -Level SUCCESS
        return $true
    } catch {
        Write-ProfileLog "Move-FileSafe failed: $_" -Level WARN
        return $false
    }
}

function Get-DirectorySize {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (-not (Test-Path $Path)) { return 0 }
        $size = Get-ChildItem -Path $Path -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | Measure-Object -Property Length -Sum
        return if ($size) { $size.Sum } else { 0 }
    } catch {
        Write-ProfileLog "Get-DirectorySize failed for $Path : $_" -Level DEBUG
        return 0
    }
}
#endregion

#region 13 - System Information
# System info and health helpers (non-invasive).

function Get-SystemInfo {
    [CmdletBinding()]
    param(
        [switch]$VerboseReport
    )
    try {
        $info = [ordered]@{
            OS = (Get-CimInstance -ClassName CIM_OperatingSystem -ErrorAction SilentlyContinue).Caption
            OSVersion = $PSVersionTable.OS
            PowerShell = $PSVersionTable.PSVersion.ToString()
            MachineName = $env:COMPUTERNAME
            User = $env:USERNAME
            Uptime = (Get-Date) - (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime
        }
        if ($VerboseReport) { $info | Format-List } else { return $info }
    } catch {
        Write-ProfileLog "Get-SystemInfo failed: $_" -Level WARN
        return $null
    }
}

function Get-SystemHealth {
    [CmdletBinding()]
    param([switch]$Quick)
    try {
        $health = [ordered]@{
            DiskFree = (Get-PSDrive -PSProvider FileSystem | Select-Object Name, @{n='FreeGB';e={[math]::Round($_.Free/1GB,2)}})
            Memory = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object FreePhysicalMemory, TotalVisibleMemorySize)
            CPU = (Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object Name, LoadPercentage)
        }
        return $health
    } catch {
        Write-ProfileLog "Get-SystemHealth failed: $_" -Level WARN
        return $null
    }
}

function Get-CPUUsage {
    [CmdletBinding()]
    param([int]$Samples = 1, [int]$IntervalSeconds = 1)
    try {
        $cpuSamples = @()
        for ($i = 0; $i -lt $Samples; $i++) {
            $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Measure-Object -Property LoadPercentage -Average
            $cpuSamples += $cpu.Average
            if ($i -lt $Samples - 1) { Start-Sleep -Seconds $IntervalSeconds }
        }
        $avgCpu = ($cpuSamples | Measure-Object -Average).Average
        return [math]::Round($avgCpu, 2)
    } catch {
        Write-ProfileLog "Get-CPUUsage failed: $_" -Level WARN
        return $null
    }
}

function Get-MemoryUsage {
    [CmdletBinding()]
    param()
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $total = $os.TotalVisibleMemorySize
            $free = $os.FreePhysicalMemory
            $used = $total - $free
            $usagePercent = [math]::Round(($used / $total) * 100, 2)
            return [ordered]@{
                TotalGB = [math]::Round($total / 1MB, 2)
                UsedGB = [math]::Round($used / 1MB, 2)
                FreeGB = [math]::Round($free / 1MB, 2)
                UsagePercent = $usagePercent
            }
        }
        return $null
    } catch {
        Write-ProfileLog "Get-MemoryUsage failed: $_" -Level WARN
        return $null
    }
}

function Get-DiskUsage {
    [CmdletBinding()]
    param([string]$Drive = 'C:')
    try {
        $driveInfo = Get-PSDrive -Name $Drive.TrimEnd(':') -PSProvider FileSystem -ErrorAction SilentlyContinue
        if ($driveInfo) {
            $total = $driveInfo.Used + $driveInfo.Free
            $used = $driveInfo.Used
            $free = $driveInfo.Free
            $usagePercent = [math]::Round(($used / $total) * 100, 2)
            return [ordered]@{
                Drive = $Drive
                TotalGB = [math]::Round($total / 1GB, 2)
                UsedGB = [math]::Round($used / 1GB, 2)
                FreeGB = [math]::Round($free / 1GB, 2)
                UsagePercent = $usagePercent
            }
        }
        return $null
    } catch {
        Write-ProfileLog "Get-DiskUsage failed: $_" -Level WARN
        return $null
    }
}

function Get-NetworkUsage {
    [CmdletBinding()]
    param([int]$DurationSeconds = 10)
    try {
        # Get initial counters
        $initial = Get-NetAdapterStatistics -ErrorAction SilentlyContinue
        Start-Sleep -Seconds $DurationSeconds
        $final = Get-NetAdapterStatistics -ErrorAction SilentlyContinue

        if ($initial -and $final) {
            $bytesSent = ($final | Measure-Object -Property SentBytes -Sum).Sum - ($initial | Measure-Object -Property SentBytes -Sum).Sum
            $bytesReceived = ($final | Measure-Object -Property ReceivedBytes -Sum).Sum - ($initial | Measure-Object -Property ReceivedBytes -Sum).Sum

            $sendRate = [math]::Round($bytesSent / $DurationSeconds / 1KB, 2)  # KB/s
            $receiveRate = [math]::Round($bytesReceived / $DurationSeconds / 1KB, 2)  # KB/s

            return [ordered]@{
                SendRateKBps = $sendRate
                ReceiveRateKBps = $receiveRate
                TotalSentMB = [math]::Round($bytesSent / 1MB, 2)
                TotalReceivedMB = [math]::Round($bytesReceived / 1MB, 2)
            }
        }
        return $null
    } catch {
        Write-ProfileLog "Get-NetworkUsage failed: $_" -Level WARN
        return $null
    }
}
#endregion

#region 14 - Network Functions
# Network helpers with timeouts and fallbacks. No external dependencies required.

function Get-LocalIP {
    [CmdletBinding()]
    param()
    try {
        $ips = @()
        if ($IsWindows) {
            $adapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -and $_.PrefixOrigin -ne 'WellKnown' }
            foreach ($a in $adapters) { $ips += $a.IPAddress }
        } else {
            $addrs = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($addrs) {
                foreach ($a in $addrs) { if ($a.IPAddress) { $ips += $a.IPAddress } }
            } elseif (Get-Command ip -ErrorAction SilentlyContinue) {
                $raw = & ip -4 addr 2>$null
                if ($raw) {
                    $matche = Select-String -InputObject $raw -Pattern "\binet\s+(\d+\.\d+\.\d+\.\d+)" -AllMatches
                    foreach ($m in $matche.Matches) { $ips += $m.Groups[1].Value }
                }
            }
        }
        return $ips | Where-Object { $_ } | Select-Object -Unique
    } catch {
        Write-ProfileLog "Get-LocalIP failed: $_" -Level DEBUG
        return @()
    }
}

function Get-PublicIP {
    [CmdletBinding()]
    param([int]$TimeoutSeconds = 5)
    try {
        # Try multiple lightweight providers; do not fail loudly
        $providers = @('https://api.ipify.org','https://ifconfig.me/ip','https://ipinfo.io/ip')
        foreach ($p in $providers) {
            try {
                $resp = Invoke-RestMethod -Uri $p -Method Get -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                if ($resp) { return $resp.Trim() }
            } catch { continue }
        }
        return $null
    } catch {
        Write-ProfileLog "Get-PublicIP failed: $_" -Level DEBUG
        return $null
    }
}

function Test-NetworkHealth {
    [CmdletBinding()]
    param([int]$TimeoutSeconds = 3)
    try {
        $dns = Resolve-DnsName -Name 'www.microsoft.com' -ErrorAction SilentlyContinue -TimeoutSeconds $TimeoutSeconds
        return $null -ne $dns
    } catch {
        return $false
    }
}

function Test-NetworkLatency {
    [CmdletBinding()]
    param([string]$Target = '8.8.8.8', [int]$Count = 4)
    try {
        $result = Test-Connection -ComputerName $Target -Count $Count -ErrorAction SilentlyContinue
        if ($result) {
            $avgLatency = ($result | Measure-Object -Property ResponseTime -Average).Average
            return [math]::Round($avgLatency, 2)
        }
        return $null
    } catch {
        Write-ProfileLog "Test-NetworkLatency failed: $_" -Level WARN
        return $null
    }
}

function Get-NetworkBandwidth {
    [CmdletBinding()]
    param([int]$DurationSeconds = 10)
    try {
        # Use Get-NetworkUsage for bandwidth
        return Get-NetworkUsage -DurationSeconds $DurationSeconds
    } catch {
        Write-ProfileLog "Get-NetworkBandwidth failed: $_" -Level WARN
        return $null
    }
}
#endregion

#region 15 - System Optimization
# Admin-guarded optimization helpers. Require explicit invocation and confirmation.

function Test-IsAdmin {
    try { return Test-Admin } catch { return $false }
}

function Optimize-System {
    [CmdletBinding()]
    param(
        [switch]$WhatIf
    )
    if (-not (Test-IsAdmin)) {
        Write-ProfileLog "Optimize-System requires admin privileges" -Level WARN
        Write-Host "Optimize-System requires administrator privileges. Run an elevated shell to proceed." -ForegroundColor Yellow
        return $false
    }
    if ($WhatIf) {
        Write-ProfileLog "Optimize-System: what-if mode (no changes applied)" -Level INFO
        Write-Host "What-if: would perform system optimizations (cleanup, temp purge, service tuning)" -ForegroundColor Cyan
        return $true
    }
    try {
        # Non-destructive examples: cleanup temp files (user-level), compact event logs (optional)
        $temp = [IO.Path]::GetTempPath()
        Get-ChildItem -Path $temp -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
        }
        Write-ProfileLog "Optimize-System: cleaned user temp files" -Level INFO
        return $true
    } catch {
        Write-ProfileLog "Optimize-System failed: $_" -Level ERROR
        return $false
    }
}

function Optimize-Processes {
    [CmdletBinding()]
    param([switch]$WhatIf)
    if (-not (Test-IsAdmin)) {
        Write-ProfileLog "Optimize-Processes requires admin privileges" -Level WARN
        Write-Host "Optimize-Processes requires administrator privileges." -ForegroundColor Yellow
        return $false
    }
    if ($WhatIf) {
        Write-Host "What-if: would optimize running processes (stop unnecessary services, adjust priorities)" -ForegroundColor Cyan
        return $true
    }
    try {
        # Example: Stop unnecessary background processes (be very careful with this)
        $processesToStop = @('SearchIndexer', 'SysMain')  # Example processes that can be stopped safely
        foreach ($proc in $processesToStop) {
            $running = Get-Process -Name $proc -ErrorAction SilentlyContinue
            if ($running) {
                Stop-Process -Name $proc -Force -ErrorAction SilentlyContinue
                Write-ProfileLog "Stopped process: $proc" -Level INFO
            }
        }
        return $true
    } catch {
        Write-ProfileLog "Optimize-Processes failed: $_" -Level ERROR
        return $false
    }
}

function Clean-SystemCache {
    [CmdletBinding()]
    param([switch]$WhatIf)
    if (-not (Test-IsAdmin)) {
        Write-ProfileLog "Clean-SystemCache requires admin privileges" -Level WARN
        Write-Host "Clean-SystemCache requires administrator privileges." -ForegroundColor Yellow
        return $false
    }
    if ($WhatIf) {
        Write-Host "What-if: would clean system caches (Windows temp, prefetch, etc.)" -ForegroundColor Cyan
        return $true
    }
    try {
        # Clean Windows temp files
        $tempPaths = @($env:TEMP, "$env:windir\Temp", "$env:windir\Prefetch")
        foreach ($path in $tempPaths) {
            if (Test-Path $path) {
                Get-ChildItem -Path $path -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
        }
        Write-ProfileLog "Clean-SystemCache: cleaned system caches" -Level INFO
        return $true
    } catch {
        Write-ProfileLog "Clean-SystemCache failed: $_" -Level ERROR
        return $false
    }
}

function Defrag-Drives {
    [CmdletBinding()]
    param([switch]$WhatIf)
    if (-not (Test-IsAdmin)) {
        Write-ProfileLog "Defrag-Drives requires admin privileges" -Level WARN
        Write-Host "Defrag-Drives requires administrator privileges." -ForegroundColor Yellow
        return $false
    }
    if ($WhatIf) {
        Write-Host "What-if: would defragment drives (analyze and optimize file placement)" -ForegroundColor Cyan
        return $true
    }
    try {
        # Use built-in defrag command
        $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -match '^[C-Z]$' }
        foreach ($drive in $drives) {
            try {
                & defrag /C /H /U /V $drive.Name 2>&1 | Out-Null
                Write-ProfileLog "Defragmented drive: $($drive.Name)" -Level INFO
            } catch {
                Write-ProfileLog "Failed to defrag drive $($drive.Name): $_" -Level WARN
            }
        }
        return $true
    } catch {
        Write-ProfileLog "Defrag-Drives failed: $_" -Level ERROR
        return $false
    }
}

function Optimize-WindowsServices {
    [CmdletBinding()]
    param([switch]$WhatIf)
    Write-ProfileLog "Optimize-WindowsServices invoked (WhatIf=$WhatIf)" -Level INFO
    Write-Host "Optimize-WindowsServices is admin-only and interactive; use with care." -ForegroundColor Yellow
    return $false
}

function Optimize-StartupPrograms {
    [CmdletBinding()]
    param([switch]$WhatIf)
    if (-not (Test-IsAdmin)) {
        Write-ProfileLog "Optimize-StartupPrograms requires admin privileges" -Level WARN
        Write-Host "Optimize-StartupPrograms requires administrator privileges." -ForegroundColor Yellow
        return $false
    }
    if ($WhatIf) {
        Write-Host "What-if: would disable unnecessary startup programs" -ForegroundColor Cyan
        return $true
    }
    try {
        # Get startup programs
        $startup = Get-CimInstance -ClassName Win32_StartupCommand
        foreach ($item in $startup) {
            # Log for review
            Write-ProfileLog "Startup program: $($item.Name) - $($item.Command)" -Level DEBUG
        }
        Write-ProfileLog "Optimize-StartupPrograms: reviewed startup programs" -Level INFO
        return $true
    } catch {
        Write-ProfileLog "Optimize-StartupPrograms failed: $_" -Level ERROR
        return $false
    }
}

function Optimize-VisualEffects {
    [CmdletBinding()]
    param([switch]$WhatIf)
    if (-not (Test-IsAdmin)) {
        Write-ProfileLog "Optimize-VisualEffects requires admin privileges" -Level WARN
        Write-Host "Optimize-VisualEffects requires administrator privileges." -ForegroundColor Yellow
        return $false
    }
    if ($WhatIf) {
        Write-Host "What-if: would set visual effects for best performance" -ForegroundColor Cyan
        return $true
    }
    try {
        # Set visual effects to best performance
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 2
        Write-ProfileLog "Visual effects set to best performance" -Level INFO
        return $true
    } catch {
        Write-ProfileLog "Optimize-VisualEffects failed: $_" -Level ERROR
        return $false
    }
}

function Optimize-PowerSettings {
    [CmdletBinding()]
    param([switch]$WhatIf)
    if (-not (Test-IsAdmin)) {
        Write-ProfileLog "Optimize-PowerSettings requires admin privileges" -Level WARN
        Write-Host "Optimize-PowerSettings requires administrator privileges." -ForegroundColor Yellow
        return $false
    }
    if ($WhatIf) {
        Write-Host "What-if: would set power plan to high performance" -ForegroundColor Cyan
        return $true
    }
    try {
        $highPerf = powercfg /list | Select-String 'High performance' | ForEach-Object { $_.Line -split ' ' | Select-Object -Last 1 }
        if ($highPerf) {
            powercfg /setactive $highPerf
            Write-ProfileLog "Power plan set to high performance" -Level INFO
        } else {
            Write-ProfileLog "High performance plan not found" -Level WARN
        }
        return $true
    } catch {
        Write-ProfileLog "Optimize-PowerSettings failed: $_" -Level ERROR
        return $false
    }
}

function Clean-EventLogs {
    [CmdletBinding()]
    param([switch]$WhatIf)
    if (-not (Test-IsAdmin)) {
        Write-ProfileLog "Clean-EventLogs requires admin privileges" -Level WARN
        Write-Host "Clean-EventLogs requires administrator privileges." -ForegroundColor Yellow
        return $false
    }
    if ($WhatIf) {
        Write-Host "What-if: would clear old event logs" -ForegroundColor Cyan
        return $true
    }
    try {
        $logs = Get-WinEvent -ListLog * | Where-Object { $_.RecordCount -gt 0 }
        foreach ($log in $logs) {
            try {
                [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.ClearLog($log.LogName)
                Write-ProfileLog "Cleared event log: $($log.LogName)" -Level DEBUG
            } catch {
                Write-ProfileLog "Failed to clear $($log.LogName): $_" -Level DEBUG
            }
        }
        Write-ProfileLog "Event logs cleaned" -Level INFO
        return $true
    } catch {
        Write-ProfileLog "Clean-EventLogs failed: $_" -Level ERROR
        return $false
    }
}
#endregion

#region 16 - Package Management
# Bootstrappers and update planning. No automatic installs at profile load.

function Get-PackageUpdatePlan {
    [CmdletBinding()]
    param()
    # Stub: return a plan structure for package managers present
    $plan = [ordered]@{
        Winget = if (Get-Command winget -ErrorAction SilentlyContinue) { 'Available' } else { 'Missing' }
        Chocolatey = if (Get-Command choco -ErrorAction SilentlyContinue) { 'Available' } else { 'Missing' }
        Scoop = if (Get-Command scoop -ErrorAction SilentlyContinue) { 'Available' } else { 'Missing' }
    }
    return $plan
}

function Update-AllPackages {
    [CmdletBinding()]
    param(
        [switch]$WhatIf,
        [switch]$Force
    )
    Write-ProfileLog "Update-AllPackages invoked (WhatIf=$WhatIf, Force=$Force)" -Level INFO
    if ($WhatIf) {
        Write-Host "What-if: would update packages via available package managers" -ForegroundColor Cyan
        return $true
    }
    # Do not run updates automatically from profile; instruct user to run bootstrap or package manager directly
    Write-ProfileLog "Update-AllPackages: no-op in profile; run bootstrap.ps1 or package manager manually" -Level DEBUG
    Write-Host "Run your package manager or bootstrap script to update packages." -ForegroundColor Yellow
    return $false
}

function Install-CommonTools {
    [CmdletBinding()]
    param([switch]$WhatIf)
    Write-ProfileLog "Install-CommonTools invoked (WhatIf=$WhatIf)" -Level INFO
    if ($WhatIf) { Write-Host "What-if: would install common tools" -ForegroundColor Cyan; return $true }
    Write-Host "Install-CommonTools delegates to bootstrap.ps1; run provisioning to install tools." -ForegroundColor Yellow
    return $false
}

function Initialize-Conda {
    [CmdletBinding()]
    param()
    try {
        # Check if conda is available
        $condaPath = Get-Command conda -ErrorAction SilentlyContinue
        if (-not $condaPath) {
            Write-ProfileLog "Conda not found in PATH" -Level WARN
            Write-Host "Conda not found. Please install Miniconda or Anaconda." -ForegroundColor Yellow
            return $false
        }

        # Initialize conda for PowerShell
        & conda init powershell 2>&1 | Out-Null
        Write-ProfileLog "Conda initialized for PowerShell" -Level INFO
        return $true
    } catch {
        Write-ProfileLog "Initialize-Conda failed: $_" -Level ERROR
        return $false
    }
}

function New-CondaEnv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$PythonVersion = '3.11'
    )
    try {
        $condaPath = Get-Command conda -ErrorAction SilentlyContinue
        if (-not $condaPath) {
            Write-ProfileLog "Conda not found" -Level WARN
            return $false
        }

        & conda create -n $Name python=$PythonVersion -y 2>&1 | Out-Null
        Write-ProfileLog "Created conda environment: $Name with Python $PythonVersion" -Level INFO
        return $true
    } catch {
        Write-ProfileLog "New-CondaEnv failed: $_" -Level ERROR
        return $false
    }
}

function Install-CondaPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Package,
        [string]$Environment
    )
    try {
        $condaPath = Get-Command conda -ErrorAction SilentlyContinue
        if (-not $condaPath) {
            Write-ProfileLog "Conda not found" -Level WARN
            return $false
        }

        $cmd = if ($Environment) { "conda install -n $Environment $Package -y" } else { "conda install $Package -y" }
        Invoke-Expression $cmd 2>&1 | Out-Null
        Write-ProfileLog "Installed conda package: $Package" -Level INFO
        return $true
    } catch {
        Write-ProfileLog "Install-CondaPackage failed: $_" -Level ERROR
        return $false
    }
}

function Get-CondaEnvs {
    [CmdletBinding()]
    param()
    try {
        $condaPath = Get-Command conda -ErrorAction SilentlyContinue
        if (-not $condaPath) {
            Write-ProfileLog "Conda not found" -Level WARN
            return $null
        }

        $envs = & conda env list 2>&1 | Where-Object { $_ -match '^\s*\*' -or $_ -match '^\w' } | ForEach-Object {
            $line = $_.Trim()
            if ($line -match '^(\w+)\s+(.+)$') {
                [ordered]@{
                    Name = $matches[1]
                    Path = $matches[2]
                    Active = $line.Contains('*')
                }
            }
        }
        return $envs
    } catch {
        Write-ProfileLog "Get-CondaEnvs failed: $_" -Level WARN
        return $null
    }
}

function Update-WingetPackages {
    [CmdletBinding()]
    param([switch]$WhatIf)
    try {
        $wingetPath = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $wingetPath) {
            Write-ProfileLog "Winget not found" -Level WARN
            return $false
        }

        if ($WhatIf) {
            Write-Host "What-if: would update all Winget packages" -ForegroundColor Cyan
            return $true
        }

        & winget upgrade --all --silent 2>&1 | Out-Null
        Write-ProfileLog "Updated Winget packages" -Level INFO
        return $true
    } catch {
        Write-ProfileLog "Update-WingetPackages failed: $_" -Level ERROR
        return $false
    }
}

function Update-ChocoPackages {
    [CmdletBinding()]
    param([switch]$WhatIf)
    try {
        $chocoPath = Get-Command choco -ErrorAction SilentlyContinue
        if (-not $chocoPath) {
            Write-ProfileLog "Chocolatey not found" -Level WARN
            return $false
        }

        if ($WhatIf) {
            Write-Host "What-if: would update all Chocolatey packages" -ForegroundColor Cyan
            return $true
        }

        & choco upgrade all -y 2>&1 | Out-Null
        Write-ProfileLog "Updated Chocolatey packages" -Level INFO
        return $true
    } catch {
        Write-ProfileLog "Update-ChocoPackages failed: $_" -Level ERROR
        return $false
    }
}

function Update-ScoopPackages {
    [CmdletBinding()]
    param([switch]$WhatIf)
    try {
        $scoopPath = Get-Command scoop -ErrorAction SilentlyContinue
        if (-not $scoopPath) {
            Write-ProfileLog "Scoop not found" -Level WARN
            return $false
        }

        if ($WhatIf) {
            Write-Host "What-if: would update all Scoop packages" -ForegroundColor Cyan
            return $true
        }

        & scoop update * 2>&1 | Out-Null
        Write-ProfileLog "Updated Scoop packages" -Level INFO
        return $true
    } catch {
        Write-ProfileLog "Update-ScoopPackages failed: $_" -Level ERROR
        return $false
    }
}

function Update-CondaPackages {
    [CmdletBinding()]
    param([string]$Environment, [switch]$WhatIf)
    try {
        $condaPath = Get-Command conda -ErrorAction SilentlyContinue
        if (-not $condaPath) {
            Write-ProfileLog "Conda not found" -Level WARN
            return $false
        }

        if ($WhatIf) {
            Write-Host "What-if: would update all Conda packages" -ForegroundColor Cyan
            return $true
        }

        $cmd = if ($Environment) { "conda update -n $Environment --all -y" } else { "conda update --all -y" }
        Invoke-Expression $cmd 2>&1 | Out-Null
        Write-ProfileLog "Updated Conda packages" -Level INFO
        return $true
    } catch {
        Write-ProfileLog "Update-CondaPackages failed: $_" -Level ERROR
        return $false
    }
}
#endregion


#region 18 - Profile Management
# Edit, backup, reload, validate profile helpers.

function Edit-Profile {
    [CmdletBinding()]
    param([string]$Editor = $Global:ProfileConfig.Editor)
    try {
        & $Editor $PROFILE
        Write-ProfileLog "Edit-Profile opened $PROFILE with $Editor" -Level INFO
        return $true
    } catch {
        Write-ProfileLog "Edit-Profile failed: $_" -Level WARN
        Write-Host "Failed to open editor: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Backup-Profile {
    [CmdletBinding()]
    param(
        [string]$Destination = (Join-Path $Global:ProfileConfig.CachePath ("profile_backup_{0}.ps1" -f (Get-Date -Format 'yyyyMMddHHmmss')))
    )
    try {
        Copy-Item -Path $PROFILE -Destination $Destination -Force -ErrorAction Stop
        Write-ProfileLog "Backup-Profile saved to $Destination" -Level SUCCESS
        return $Destination
    } catch {
        Write-ProfileLog "Backup-Profile failed: $_" -Level WARN
        return $null
    }
}

function Update-Profile {
    [CmdletBinding()]
    param()
    try {
        . $PROFILE
        Write-ProfileLog "Profile reloaded" -Level SUCCESS
        return $true
    } catch {
        Write-ProfileLog "Update-Profile failed: $_" -Level WARN
        return $false
    }
}

function Test-Profile {
    [CmdletBinding()]
    param()
    try {
        # Basic syntax check by loading in a new process
        $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if (-not $pwsh) { $pwsh = $PSHOME + '\\pwsh.exe' }
        $argz = @('-NoProfile','-Command', ". '$PROFILE'; Write-Output 'OK'")
        $proc = Start-Process -FilePath $pwsh -ArgumentList $argz -NoNewWindow -Wait -PassThru -ErrorAction Stop
        if ($proc.ExitCode -eq 0) { Write-ProfileLog "Test-Profile: syntax OK" -Level INFO; return $true }
        Write-ProfileLog "Test-Profile: non-zero exit code $($proc.ExitCode)" -Level WARN
        return $false
    } catch {
        Write-ProfileLog "Test-Profile failed: $_" -Level ERROR
        return $false
    }
}
#endregion

#region 19 - Diagnostics and Telemetry
# Opt-in telemetry and diagnostics summary. Telemetry is disabled by default.

if (-not $Global:ProfileTelemetry) { $Global:ProfileTelemetry = @{ OptIn = $false } }

function Get-ProvisionState {
    [CmdletBinding()]
    param()
    try {
        if (Test-Path $script:ProvisionStateFile) {
            $raw = Get-Content $script:ProvisionStateFile -Raw -ErrorAction Stop
            try { return $raw | ConvertFrom-Json } catch { return $raw }
        }
        return $null
    } catch {
        Write-ProfileLog "Get-ProvisionState failed: $_" -Level DEBUG
        return $null
    }
}

function Show-ProfileDiagnostics {
    [CmdletBinding()]
    param()
    $diag = [ordered]@{
        ProfileConfig = $Global:ProfileConfig
        ProfileState = $Global:ProfileState
        DeferredLoader = $Global:DeferredModulesStatus
        ProvisionState = Get-ProvisionState
        RecentLogs = (Get-ProfileLog -Lines 50) -join "`n"
    }
    $diag
}

function Set-ProfileTelemetry {
    [CmdletBinding()]
    param([switch]$Enable)
    if ($Enable) {
        $Global:ProfileTelemetry.OptIn = $true
        Write-ProfileLog "Telemetry enabled by user" -Level INFO
        Write-Host "Telemetry enabled (opt-in)." -ForegroundColor Green
    } else {
        $Global:ProfileTelemetry.OptIn = $false
        Write-ProfileLog "Telemetry disabled by user" -Level INFO
        Write-Host "Telemetry disabled." -ForegroundColor Yellow
    }
    return $Global:ProfileTelemetry.OptIn
}

# Telemetry stub: only run if OptIn true; does not send data by default
function Send-ProfileTelemetry {
    param([hashtable]$Payload)
    if (-not $Global:ProfileTelemetry.OptIn) { Write-ProfileLog "Telemetry suppressed (opt-out)" -Level DEBUG; return $false }
    Write-ProfileLog "Telemetry would send payload (opt-in) - payload keys: $($Payload.Keys -join ', ')" -Level DEBUG
    return $true
}
#endregion

#region 20 - Additional Utilities
# Small convenience helpers used across the profile.

function Get-Uptime {
    try {
        if ($IsWindows) {
            $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime
            return (Get-Date) - $boot
        } else {
            $proc = Get-Process -Id 1 -ErrorAction SilentlyContinue
            if ($proc) { return (Get-Date) - $proc.StartTime }
            return $null
        }
    } catch {
        Write-ProfileLog "Get-Uptime failed: $_" -Level DEBUG
        return $null
    }
}

function New-Directory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    Initialize-Path -Path $Path | Out-Null
    Set-Location -Path $Path
}

function Copy-To-Clipboard {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)
    try {
        if ($IsWindows) {
            Set-Clipboard -Value $Text
        } else {
            # cross-platform fallback using pbcopy/xclip if available
            if (Get-Command pbcopy -ErrorAction SilentlyContinue) {
                $Text | pbcopy
            } elseif (Get-Command xclip -ErrorAction SilentlyContinue) {
                $Text | xclip -selection clipboard
            } else {
                Write-ProfileLog "No clipboard utility available" -Level WARN
                return $false
            }
        }
        Write-ProfileLog "Copied text to clipboard (length $($Text.Length))" -Level DEBUG
        return $true
    } catch {
        Write-ProfileLog "Copy-To-Clipboard failed: $_" -Level WARN
        return $false
    }
}

function Show-HelpUtilities {
    Write-Host "`nProfile Utilities (12-20):" -ForegroundColor Cyan
    Write-Host " - Initialize-Path, New-File, Copy-FileSafe, Move-FileSafe, Get-DirectorySize" -ForegroundColor Yellow
    Write-Host " - Get-SystemInfo, Get-SystemHealth, Get-CPUUsage, Get-MemoryUsage, Get-DiskUsage, Get-NetworkUsage" -ForegroundColor Yellow
    Write-Host " - Get-LocalIP, Get-PublicIP, Test-NetworkHealth, Test-NetworkLatency, Get-NetworkBandwidth" -ForegroundColor Yellow
    Write-Host " - Optimize-System (admin), Optimize-Processes (admin), Clean-SystemCache (admin), Defrag-Drives (admin)" -ForegroundColor Yellow
    Write-Host " - Package Management: Update-WingetPackages, Update-ChocoPackages, Update-ScoopPackages, Update-CondaPackages" -ForegroundColor Yellow
    Write-Host " - Conda Environment: Initialize-Conda, New-CondaEnv, Install-CondaPackage, Get-CondaEnvs" -ForegroundColor Yellow
    Write-Host " - Profile management: Edit-Profile, Backup-Profile, Update-Profile, Test-Profile" -ForegroundColor Yellow
    Write-Host " - Diagnostics: Show-ProfileDiagnostics, Set-ProfileTelemetry" -ForegroundColor Yellow
    Write-Host " - Utilities: Get-Uptime, New-Directory, Copy-To-Clipboard" -ForegroundColor Yellow
    Write-Host ""
}
#endregion
