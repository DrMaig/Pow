# Microsoft.PowerShell_profile.ps1
# Improved, best-practice PowerShell profile for interactive sessions.
# (This file is an updated version including support for winget/choco/scoop installs,
# expanded command-to-module/tool suggestions, and a profile bootstrap helper.)
#
# NOTE: This file is intended for interactive sessions. Non-interactive scripts
# should avoid side-effects; this profile already guards interactive-only actions.

#region 0 - Basic guards (interactive-only)
$script:IsInteractive = $false
try {
    $script:IsInteractive = ($Host -and $Host.UI -and $Host.UI.RawUI) -and ($PSCommandPath -ne $null -or $Profile -ne $null)
} catch { $script:IsInteractive = $false }
#endregion

#region 1 - Configuration (defaults + persistence)
if (-not $Global:ProfileConfig) {
    $Global:ProfileConfig = [ordered]@{
        ShowDiagnostics   = $true
        ShowWelcome       = $true
        PromptStyle       = 'modern'   # modern, minimal, full

        EnableLogging     = $true
        EnableAutoUpdate  = $false
        EnableTranscript  = $false
        EnableFzf         = $true

        LogPath           = "$HOME\Documents\PowerShell\Logs"
        TranscriptPath    = "$HOME\Documents\PowerShell\Transcripts"
        CachePath         = "$HOME\Documents\PowerShell\Cache"

        Editor            = 'code'
        UpdateCheckDays   = 7
        HistorySize       = 10000

        DeferredLoader    = @{
            WaitForProvisionSeconds = 10
            Notification = $true
            NotificationStyle = 'hint'
        }

        Provisioning = @{
            Provider = 'Auto'
            DryRun = $false
            WaitForCompletionSeconds = 20
        }

        Telemetry = @{
            OptIn = $false
        }

        OhMyPosh = @{
            Enabled = $true
            ModuleName = 'oh-my-posh'
            BinaryName = 'oh-my-posh'
            Theme = 'paradox'
        }

        PSReadLine = @{
            Enabled = $true
            EditMode = 'Windows'
            HistorySaveStyle = 'SaveIncrementally'
            HistoryNoDuplicates = $true
            MaximumHistoryCount = 4096
            MinimumVersion = '2.2.6'
        }
    }
}

$pathsToEnsure = @($Global:ProfileConfig.LogPath, $Global:ProfileConfig.TranscriptPath, $Global:ProfileConfig.CachePath)
foreach ($p in $pathsToEnsure) {
    try { if (-not (Test-Path -Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } } catch {}
}

$script:ProfileConfigFile = Join-Path $Global:ProfileConfig.CachePath 'profile_config.json'

function Save-ProfileConfig { param([string]$Path = $script:ProfileConfigFile)
    try { $Global:ProfileConfig | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Force -Encoding UTF8; Write-ProfileLog "Saved profile config to $Path" -Level DEBUG; return $true } catch { Write-Host "Failed to save profile config: $_" -ForegroundColor Yellow; return $false }
}

function Invoke-ProfileConfig { param([string]$Path = $script:ProfileConfigFile)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $json = Get-Content -Path $Path -Raw -ErrorAction Stop
        $obj = $json | ConvertFrom-Json
        foreach ($k in $obj.PSObject.Properties.Name) { $Global:ProfileConfig[$k] = $obj.$k }
        Write-ProfileLog "Loaded profile config from $Path" -Level DEBUG
        return $true
    } catch { Write-ProfileLog "Failed to load profile config: $_" -Level WARN; return $false }
}

try { Invoke-ProfileConfig | Out-Null } catch {}
#endregion

#region 2 - Environment state and helpers
if (-not $Global:ProfileState) {
    $Global:ProfileState = [ordered]@{
        IsAdmin = $false
        IsWindows = $IsWindows
        IsLinux = $IsLinux
        IsMacOS = $IsMacOS
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        MissingCommands = @()
        HasNetwork = $null
        Provisioned = $false
        LastChecked = $null
        Notes = @()
    }
}

if (-not (Get-Command Test-Admin -ErrorAction SilentlyContinue)) {
    function Test-Admin {
        try {
            if ($IsWindows) {
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                $principal = New-Object Security.Principal.WindowsPrincipal($identity)
                return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            } else {
                if (Get-Command id -ErrorAction SilentlyContinue) {
                    $uid = (& id -u 2>$null)
                    return ([int]$uid) -eq 0
                }
                return ($null -ne $env:SUDO_UID) -or ($env:USER -eq 'root')
            }
        } catch { return $false }
    }
}

function Test-Environment { [CmdletBinding()] param([switch]$SkipNetworkCheck)
    $Global:ProfileState.IsWindows = $IsWindows
    $Global:ProfileState.IsLinux = $IsLinux
    $Global:ProfileState.IsMacOS = $IsMacOS
    $Global:ProfileState.PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    try { $Global:ProfileState.IsAdmin = Test-Admin } catch { $Global:ProfileState.IsAdmin = $false; $Global:ProfileState.Notes += "Admin check failed" }

    $commandsToCheck = @('winget','choco','scoop','oh-my-posh','pwsh','code','fzf','git','gh')
    $missing = @()
    foreach ($c in $commandsToCheck) { if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { $missing += $c } }
    $Global:ProfileState.MissingCommands = $missing

    $provFile = Join-Path $Global:ProfileConfig.CachePath 'provision_state.json'
    $Global:ProfileState.Provisioned = Test-Path $provFile

    if (-not $SkipNetworkCheck) {
        try {
            if ($IsWindows) { $res = Resolve-DnsName -Name 'www.microsoft.com' -ErrorAction SilentlyContinue; $Global:ProfileState.HasNetwork = ($null -ne $res) }
            else {
                $sock = New-Object System.Net.Sockets.TcpClient
                $async = $sock.BeginConnect('1.1.1.1', 53, $null, $null)
                $ok = $async.AsyncWaitHandle.WaitOne(500)
                if ($ok) { $sock.EndConnect($async); $sock.Close(); $Global:ProfileState.HasNetwork = $true } else { $Global:ProfileState.HasNetwork = $false }
            }
        } catch { $Global:ProfileState.HasNetwork = $false; $Global:ProfileState.Notes += "Network probe failed: $($_.Exception.Message)" }
    } else { $Global:ProfileState.HasNetwork = $null }

    $Global:ProfileState.LastChecked = (Get-Date).ToString('o')
    return $Global:ProfileState
}

try { Test-Environment -SkipNetworkCheck | Out-Null } catch {}
#endregion

#region 3 - Logging system
if (-not (Test-Path -Path $Global:ProfileConfig.LogPath)) { try { New-Item -ItemType Directory -Path $Global:ProfileConfig.LogPath -Force | Out-Null } catch {} }
$script:LogLevels = @('DEBUG','INFO','SUCCESS','WARN','ERROR')
if (-not ($Global:ProfileConfig.PSObject.Properties.Name -contains 'LogLevel')) { $Global:ProfileConfig.LogLevel = 'DEBUG' }

function Get-ProfileLogFile { param([string]$Prefix = 'profile') $date = Get-Date -Format 'yyyy-MM'; return Join-Path $Global:ProfileConfig.LogPath "$Prefix`_$date.log" }

function Write-ProfileLog {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$Message, [ValidateSet('INFO','WARN','ERROR','DEBUG','SUCCESS')][string]$Level = 'INFO', [string]$Prefix = 'profile')
    if (-not $Global:ProfileConfig.EnableLogging) { return }
    $currentIndex = $script:LogLevels.IndexOf($Global:ProfileConfig.LogLevel)
    $msgIndex = $script:LogLevels.IndexOf($Level)
    if ($msgIndex -lt $currentIndex) { return }
    $timestamp = (Get-Date).ToString('o')
    $entry = @{ time = $timestamp; level = $Level; message = $Message } | ConvertTo-Json -Compress
    $logFile = Get-ProfileLogFile -Prefix $Prefix
    try { Add-Content -Path $logFile -Value $entry -Encoding UTF8 } catch {}
    if ($script:IsInteractive -and ($Level -ne 'DEBUG')) {
        $color = switch ($Level) { 'INFO' { 'Cyan' } 'SUCCESS' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
        Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
    }
}

function Set-ProfileLogLevel { param([ValidateSet('DEBUG','INFO','SUCCESS','WARN','ERROR')][string]$Level) $Global:ProfileConfig.LogLevel = $Level; Write-ProfileLog "Log level set to $Level" -Level DEBUG }
#endregion

#region 4 - Repos, package providers, module helpers, and external installers (winget/choco/scoop)
$script:TrustedRepoFile = Join-Path $Global:ProfileConfig.CachePath 'trusted_repos.json'
$script:InstalledModulesCacheFile = Join-Path $Global:ProfileConfig.CachePath 'installed_modules_cache.json'
$script:InstalledModulesCacheTtlSeconds = 300

function Get-PSRepositorySafe { param([string]$Name = 'PSGallery') try { return Get-PSRepository -Name $Name -ErrorAction SilentlyContinue } catch { return $null } }
function Test-RepositoryReachable { param([Parameter(Mandatory=$true)][string]$SourceLocation, [int]$TimeoutSeconds = 5)
    try {
        if (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue) {
            $resp = Invoke-WebRequest -Uri $SourceLocation -Method Head -TimeoutSec $TimeoutSeconds -ErrorAction SilentlyContinue
            return $resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400
        } else {
            $uri = [uri]$SourceLocation
            $HostName = $uri.Host
            $sock = New-Object System.Net.Sockets.TcpClient
            $async = $sock.BeginConnect($HostName, 443, $null, $null)
            $ok = $async.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000)
            if ($ok) { $sock.EndConnect($async); $sock.Close(); return $true } else { return $false }
        }
    } catch { return $false }
}

function Get-PreferredPackageProvider {
    try {
        if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) { return 'PSResourceGet' }
        if (Get-Command Install-Module -ErrorAction SilentlyContinue) { return 'PowerShellGet' }
        return $null
    } catch { Write-ProfileLog "Get-PreferredPackageProvider failed" -Level DEBUG; return $null }
}

function Install-ModuleSafe {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$Name, [string]$MinVersion, [ValidateSet('Auto','PSResourceGet','PowerShellGet')][string]$Provider = 'Auto', [switch]$Force)
    $selected = if ($Provider -eq 'Auto') { Get-PreferredPackageProvider() } else { $Provider }
    if (-not $selected) { Write-ProfileLog "No package provider available to install $Name" -Level WARN; return $false }
    if ($Global:ProfileConfig.Provisioning.DryRun) { Write-ProfileLog "DryRun enabled: skipping install of $Name" -Level INFO; return $true }

    try {
        if ($selected -eq 'PSResourceGet') {
            $params = @{ Name = $Name; Scope = 'CurrentUser'; TrustRepository = $true; ErrorAction = 'Stop' }
            if ($MinVersion) { $params['Version'] = $MinVersion }
            if ($Force) { $params['Reinstall'] = $true }
            Install-PSResource @params | Out-Null
            Write-ProfileLog "Installed $Name via PSResourceGet" -Level SUCCESS
            return $true
        }
        $installParams = @{ Name = $Name; Scope = 'CurrentUser'; Force = $true; AllowClobber = $true; ErrorAction = 'Stop' }
        if ($MinVersion) { $installParams['MinimumVersion'] = $MinVersion }
        Install-Module @installParams | Out-Null
        Write-ProfileLog "Installed $Name via PowerShellGet" -Level SUCCESS
        return $true
    } catch { Write-ProfileLog "Install-ModuleSafe failed for $Name : $_" -Level ERROR; return $false }
}

function Get-InstalledModuleVersion { param([Parameter(Mandatory=$true)][string]$Name)
    try { $m = Get-InstalledModule -Name $Name -ErrorAction SilentlyContinue; if ($m) { return [version]$m.Version } $mod = Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1; if ($mod) { return [version]$mod.Version } } catch {}
    return $null
}

function Ensure-ModuleInstalled { [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$Name, [string]$MinVersion, [ValidateSet('Auto','PSResourceGet','PowerShellGet')][string]$Provider = 'Auto')
    $current = Get-InstalledModuleVersion -Name $Name
    if ($current -and -not $MinVersion) { return $true }
    if ($current -and $MinVersion) { try { if ($current -ge ([version]$MinVersion)) { return $true } } catch {} }
    return Install-ModuleSafe -Name $Name -MinVersion $MinVersion -Provider $Provider -Force
}

function Ensure-PathPrefix { [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $separator = [System.IO.Path]::PathSeparator
        $segments = $env:PATH -split [regex]::Escape($separator)
        if ($segments -contains $Path) { return $false }
        $env:PATH = "$Path$separator$env:PATH"
        return $true
    } catch { Write-ProfileLog "Ensure-PathPrefix failed for $Path : $_" -Level DEBUG; return $false }
}

function Ensure-OhMyPoshPath {
    try {
        $binCmd = $Global:ProfileConfig.OhMyPosh.BinaryName
        if (Get-Command $binCmd -ErrorAction SilentlyContinue) { return $true }
        $module = Get-Module -ListAvailable -Name $Global:ProfileConfig.OhMyPosh.ModuleName -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $module) { return $false }
        $binPath = Join-Path (Split-Path -Parent $module.Path) 'bin'
        if (Test-Path -LiteralPath $binPath) { if (Ensure-PathPrefix -Path $binPath) { Write-ProfileLog "Added oh-my-posh bin to PATH: $binPath" -Level DEBUG } return $null -ne (Get-Command $binCmd -ErrorAction SilentlyContinue) }
        return $false
    } catch { Write-ProfileLog "Ensure-OhMyPoshPath failed: $_" -Level DEBUG; return $false }
}

function Ensure-OhMyPoshThemesPath {
    try {
        if ($env:POSH_THEMES_PATH -and (Test-Path -LiteralPath $env:POSH_THEMES_PATH)) { return $true }
        $module = Get-Module -ListAvailable -Name $Global:ProfileConfig.OhMyPosh.ModuleName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($module) {
            $themes = Join-Path (Split-Path -Parent $module.Path) 'themes'
            if (Test-Path -LiteralPath $themes) { $env:POSH_THEMES_PATH = $themes; return $true }
        }
        $fallback = Join-Path $HOME '.poshthemes'
        if (Test-Path -LiteralPath $fallback) { $env:POSH_THEMES_PATH = $fallback; return $true }
        return $false
    } catch { Write-ProfileLog "Ensure-OhMyPoshThemesPath failed: $_" -Level DEBUG; return $false }
}
#endregion

#region 5 - External tool installer helpers (winget / choco / scoop)
# Mapping of tool -> package ids for various package managers. IDs may vary by platform/distribution.
$script:ExternalToolPackageMap = @{
    'fzf' = @{ winget = 'junegunn.fzf'; choco = 'fzf'; scoop = 'fzf' }
    'oh-my-posh' = @{ winget = 'JanDeDobbeleer.OhMyPosh'; choco = 'oh-my-posh'; scoop = 'oh-my-posh' }
    'git' = @{ winget = 'Git.Git'; choco = 'git'; scoop = 'git' }
    'gh' = @{ winget = 'GitHub.cli'; choco = 'github'; scoop = 'gh' }
    'rg' = @{ winget = 'BurntSushi.Ripgrep'; choco = 'ripgrep'; scoop = 'ripgrep' }
    'bat' = @{ winget = 'sharkdp.bat'; choco = 'bat'; scoop = 'bat' }
    'jq' = @{ winget = 'jq'; choco = 'jq'; scoop = 'jq' }
    'delta' = @{ winget = 'dandavison.delta'; choco = 'git-delta'; scoop = 'git-delta' }
    'pwsh' = @{ winget = 'Microsoft.PowerShell'; choco = 'powershell-core'; scoop = 'pwsh' }
    'vscode' = @{ winget = 'Microsoft.VisualStudioCode'; choco = 'vscode'; scoop = 'vscode' }
    'docker' = @{ winget = 'Docker.DockerDesktop'; choco = 'docker-desktop'; scoop = $null }
    'kubectl' = @{ winget = 'Kubernetes.kubectl'; choco = 'kubernetes-cli'; scoop = 'kubectl' }
    'terraform' = @{ winget = 'HashiCorp.Terraform'; choco = 'terraform'; scoop = 'terraform' }
}

function Get-AvailableExternalPackageManagers {
    $mgrs = @()
    if (Get-Command winget -ErrorAction SilentlyContinue) { $mgrs += 'winget' }
    if (Get-Command choco -ErrorAction SilentlyContinue) { $mgrs += 'choco' }
    if (Get-Command scoop -ErrorAction SilentlyContinue) { $mgrs += 'scoop' }
    return $mgrs
}

function Choose-ExternalPackageManager {
    param([string[]]$PreferredOrder = @('winget','choco','scoop'))
    $available = Get-AvailableExternalPackageManagers
    foreach ($p in $PreferredOrder) { if ($available -contains $p) { return $p } }
    return $null
}

function Install-ExternalTool {
    [CmdletBinding()] param([Parameter(Mandatory = $true)][string]$ToolName, [string]$PreferredManager)

    $map = $script:ExternalToolPackageMap
    if (-not $map.ContainsKey($ToolName)) {
        Write-ProfileLog "No package mapping available for $ToolName" -Level WARN
        return $false
    }
    $entry = $map[$ToolName]
    $mgr = if ($PreferredManager) { $PreferredManager } else { Choose-ExternalPackageManager() }
    if (-not $mgr) { Write-ProfileLog "No external package manager found to install $ToolName" -Level WARN; return $false }

    $pkgId = if ($entry.ContainsKey($mgr)) { $entry[$mgr] } else { $null }
    if (-not $pkgId) { Write-ProfileLog "No package id for $ToolName via $mgr" -Level WARN; return $false }

    if ($Global:ProfileConfig.Provisioning.DryRun) { Write-ProfileLog "DryRun: would install $ToolName via $mgr ($pkgId)" -Level INFO; return $true }

    Write-ProfileLog "Attempting to install $ToolName via $mgr ($pkgId)" -Level INFO
    try {
        switch ($mgr) {
            'winget' {
                $args = @('install','--id', $pkgId, '-e')
                # Some packages support --silent; leave out to allow interactive prompts if needed
                Start-Process -FilePath 'winget' -ArgumentList $args -NoNewWindow -Wait -ErrorAction Stop
            }
            'choco' {
                $args = @('install', $pkgId, '-y')
                Start-Process -FilePath 'choco' -ArgumentList $args -NoNewWindow -Wait -ErrorAction Stop
            }
            'scoop' {
                $args = @('install', $pkgId)
                Start-Process -FilePath 'scoop' -ArgumentList $args -NoNewWindow -Wait -ErrorAction Stop
            }
            default {
                Write-ProfileLog "Unknown package manager: $mgr" -Level WARN
                return $false
            }
        }
        # Quick check: command now exists?
        Start-Sleep -Seconds 1
        if (Get-Command $ToolName -ErrorAction SilentlyContinue) { Write-ProfileLog "Installed external tool $ToolName via $mgr" -Level SUCCESS; return $true }
        # Fallback test: check expected binary names
        $candidate = if ($ToolName -eq 'oh-my-posh') { 'oh-my-posh' } else { $ToolName }
        if (Get-Command $candidate -ErrorAction SilentlyContinue) { Write-ProfileLog "Installed external tool $ToolName via $mgr" -Level SUCCESS; return $true }
        Write-ProfileLog "Install-ExternalTool completed but command not found for $ToolName" -Level WARN
        return $true
    } catch {
        Write-ProfileLog "Install-ExternalTool failed for $ToolName via $mgr : $_" -Level ERROR
        return $false
    }
}
#endregion

#region 6 - Module plan and first-run provisioning
function Get-ProfileModulePlan {
    [CmdletBinding()] param()
    $modules = @(
        @{ Name = 'PSReadLine'; MinVersion = $Global:ProfileConfig.PSReadLine.MinimumVersion; Required = $true }
        @{ Name = 'oh-my-posh'; MinVersion = $null; Required = $Global:ProfileConfig.OhMyPosh.Enabled }
        @{ Name = 'PSFzf'; MinVersion = $null; Required = $Global:ProfileConfig.EnableFzf }
        @{ Name = 'Terminal-Icons'; MinVersion = $null; Required = $false }
    )
    return $modules
}

$script:ProvisionStateFile = Join-Path $Global:ProfileConfig.CachePath 'provision_state.json'

function Invoke-FirstRunProvisioning {
    [CmdletBinding()] param()

    if (Test-Path $script:ProvisionStateFile) {
        try {
            $state = Get-Content -Path $script:ProvisionStateFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($state -and $state.Provisioned) { $Global:ProfileState.Provisioned = $true; return $true }
        } catch {}
    }

    if ($null -eq $Global:ProfileState.HasNetwork) { try { Test-Environment | Out-Null } catch {} }
    if ($Global:ProfileState.HasNetwork -eq $false) { Write-ProfileLog 'Skipping provisioning (no network detected)' -Level WARN; return $false }

    $provider = $Global:ProfileConfig.Provisioning.Provider
    if ($provider -eq 'Auto') { $provider = Get-PreferredPackageProvider() }
    if (-not $provider) { Write-ProfileLog 'No package provider available; cannot provision modules automatically' -Level WARN; return $false }

    try {
        $repo = Get-PSRepositorySafe -Name 'PSGallery'
        if ($repo -and $repo.InstallationPolicy -ne 'Trusted' -and (Get-Command Set-PSRepository -ErrorAction SilentlyContinue)) {
            try { Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch {}
            Write-ProfileLog 'Set PSGallery InstallationPolicy to Trusted for provisioning' -Level DEBUG
        }
    } catch {}

    $desired = Get-ProfileModulePlan
    $installedList = @()
    foreach ($m in $desired) {
        if (-not $m.Required) { continue }
        $ok = Ensure-ModuleInstalled -Name $m.Name -MinVersion $m.MinVersion -Provider $provider
        if ($ok) { $installedList += $m.Name } else { Write-ProfileLog "Provision: failed to install $($m.Name)" -Level WARN }
    }

    # Install essential external binaries if not present (fzf, oh-my-posh binary) -- best-effort
    if ($Global:ProfileConfig.EnableFzf -and -not (Get-Command fzf -ErrorAction SilentlyContinue)) {
        try { Install-ExternalTool -ToolName 'fzf' } catch {}
    }
    if ($Global:ProfileConfig.OhMyPosh.Enabled -and -not (Get-Command $Global:ProfileConfig.OhMyPosh.BinaryName -ErrorAction SilentlyContinue)) {
        try { Install-ExternalTool -ToolName 'oh-my-posh' } catch {}
    }

    Ensure-OhMyPoshPath | Out-Null
    Ensure-OhMyPoshThemesPath | Out-Null

    $state = [ordered]@{
        Provisioned = $true
        Timestamp = (Get-Date).ToString('o')
        Provider = $provider
        Modules = $installedList
    }
    try { $state | ConvertTo-Json -Depth 6 | Set-Content -Path $script:ProvisionStateFile -Force -Encoding UTF8; $Global:ProfileState.Provisioned = $true } catch { Write-ProfileLog "Failed to write provision state: $_" -Level WARN }

    return $Global:ProfileState.Provisioned
}
#endregion

#region 7 - Provisioning orchestration (bounded first-run)
try {
    $isProvisioned = Test-Path $script:ProvisionStateFile
    if (-not $isProvisioned -and $script:IsInteractive) {
        Write-ProfileLog "Starting first-run provisioning (bounded wait)..." -Level INFO
        $wait = $Global:ProfileConfig.Provisioning.WaitForCompletionSeconds
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $completed = $false
        try { $completed = Invoke-FirstRunProvisioning } catch { Write-ProfileLog "Invoke-FirstRunProvisioning failed: $_" -Level WARN }
        if (-not $completed -and $sw.Elapsed.TotalSeconds -lt $wait) {
            $deadline = [DateTime]::UtcNow.AddSeconds($wait)
            while (-not $completed -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Seconds 1; try { $completed = Invoke-FirstRunProvisioning } catch {} }
        }
        if ($completed) { Write-ProfileLog "Provisioning completed during first-run." -Level SUCCESS } else { Write-ProfileLog "Provisioning did not complete within wait; continuing in background." -Level INFO }
    } elseif ($script:IsInteractive -and $isProvisioned) {
        try { Test-Environment -SkipNetworkCheck | Out-Null } catch {}
    }
} catch { Write-ProfileLog "First-run provisioning orchestration failed: $_" -Level WARN }
#endregion

#region 8 - PSReadLine configuration
if ($script:IsInteractive -and $Global:ProfileConfig.PSReadLine.Enabled) {
    try {
        if (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) {
            Set-PSReadLineOption -EditMode $Global:ProfileConfig.PSReadLine.EditMode
            if ($Global:ProfileConfig.PSReadLine.HistorySaveStyle -eq 'SaveIncrementally') { Set-PSReadLineOption -HistorySaveStyle SaveIncrementally } else { Set-PSReadLineOption -HistorySaveStyle SaveAtExit }
            if ($Global:ProfileConfig.PSReadLine.MaximumHistoryCount) { Set-PSReadLineOption -MaximumHistoryCount $Global:ProfileConfig.PSReadLine.MaximumHistoryCount }
            if ($Global:ProfileConfig.PSReadLine.HistoryNoDuplicates) { Set-PSReadLineOption -HistoryNoDuplicates }
        } else {
            if (Ensure-ModuleInstalled -Name 'PSReadLine' -MinVersion $Global:ProfileConfig.PSReadLine.MinimumVersion -Provider 'Auto') {
                try { Import-Module PSReadLine -ErrorAction SilentlyContinue } catch {}
                if (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) {
                    Set-PSReadLineOption -EditMode $Global:ProfileConfig.PSReadLine.EditMode
                    if ($Global:ProfileConfig.PSReadLine.HistorySaveStyle -eq 'SaveIncrementally') { Set-PSReadLineOption -HistorySaveStyle SaveIncrementally } else { Set-PSReadLineOption -HistorySaveStyle SaveAtExit }
                    if ($Global:ProfileConfig.PSReadLine.MaximumHistoryCount) { Set-PSReadLineOption -MaximumHistoryCount $Global:ProfileConfig.PSReadLine.MaximumHistoryCount }
                    if ($Global:ProfileConfig.PSReadLine.HistoryNoDuplicates) { Set-PSReadLineOption -HistoryNoDuplicates }
                }
            }
        }
    } catch { Write-ProfileLog "PSReadLine configuration failed: $_" -Level WARN }
}
#endregion

#region 9 - Prompt + oh-my-posh lazy loading
$script:OhMyPoshLoaded = $false
$script:OhMyPoshRenderError = $null

function global:Invoke-OhMyPoshPrompt {
    param()
    if (-not $script:OhMyPoshLoaded) {
        try {
            if (Get-Module -ListAvailable -Name $Global:ProfileConfig.OhMyPosh.ModuleName) { try { Import-Module -Name $Global:ProfileConfig.OhMyPosh.ModuleName -ErrorAction Stop } catch {} }
            Ensure-OhMyPoshThemesPath | Out-Null
            if (Get-Command -Name 'Get-PoshPrompt' -ErrorAction SilentlyContinue) { $script:OhMyPoshLoaded = $true }
            elseif (Get-Command -Name 'oh-my-posh' -ErrorAction SilentlyContinue) { $script:OhMyPoshLoaded = $true }
            else {
                if (-not $Global:ProfileState.Provisioned) { Write-ProfileLog "oh-my-posh not found; attempting install via provisioning routine" -Level INFO; try { Invoke-FirstRunProvisioning | Out-Null } catch {} }
                if (Get-Command -Name $Global:ProfileConfig.OhMyPosh.BinaryName -ErrorAction SilentlyContinue) { $script:OhMyPoshLoaded = $true }
            }
        } catch { $script:OhMyPoshRenderError = $_; Write-ProfileLog "Failed to prepare oh-my-posh: $_" -Level WARN }
    }

    try {
        if ($script:OhMyPoshLoaded) {
            if (Get-Command -Name 'Get-PoshPrompt' -ErrorAction SilentlyContinue) { return & Get-PoshPrompt -Theme $Global:ProfileConfig.OhMyPosh.Theme }
            elseif (Get-Command -Name 'oh-my-posh' -ErrorAction SilentlyContinue) {
                $themeArg = $Global:ProfileConfig.OhMyPosh.Theme
                $poshBinary = (Get-Command $Global:ProfileConfig.OhMyPosh.BinaryName -ErrorAction SilentlyContinue).Source
                if ($poshBinary) {
                    $configPath = Join-Path $env:POSH_THEMES_PATH "$themeArg.omp.json"
                    $output = & $poshBinary --init --shell pwsh --config $configPath 2>$null
                    if ($output) { return $output }
                }
            } elseif (Get-Command -Name 'Set-PoshPrompt' -ErrorAction SilentlyContinue) {
                try { Set-PoshPrompt -Theme $Global:ProfileConfig.OhMyPosh.Theme -ErrorAction SilentlyContinue } catch {}
            }
        }
    } catch { Write-ProfileLog "oh-my-posh rendering error: $_" -Level WARN }

    $cwd = (Get-Location).Path
    return "PS $cwd> "
}

function global:prompt {
    try {
        if ($Global:ProfileConfig.PromptStyle -eq 'minimal') { return "PS> " }
        elseif ($Global:ProfileConfig.PromptStyle -eq 'full') {
            $user = $env:USERNAME; $host = $env:COMPUTERNAME; $cwd = (Get-Location).Path
            return "[$user@$host] $cwd`nPS> "
        } else {
            if ($script:IsInteractive) {
                $res = Invoke-OhMyPoshPrompt
                if ($res) { return $res }
            }
            $cwd = (Get-Location).Path
            return "PS $cwd> "
        }
    } catch { Write-ProfileLog "prompt function error: $_" -Level WARN; return "PS> " }
}
#endregion

#region 10 - Expanded CommandNotFound suggestions (non-invasive hints)
# Expanded mapping so when a command isn't found we can hint which module or package to install.
$script:CommandToPackageHints = @{
    'fzf' = @{ module = 'PSFzf'; tool = 'fzf' }
    'oh-my-posh' = @{ module = 'oh-my-posh'; tool = 'oh-my-posh' }
    'Get-PoshPrompt' = @{ module = 'oh-my-posh'; tool = 'oh-my-posh' }
    'git' = @{ tool = 'git' }
    'gh' = @{ tool = 'gh' }
    'rg' = @{ tool = 'rg' }
    'bat' = @{ tool = 'bat' }
    'jq' = @{ tool = 'jq' }
    'code' = @{ tool = 'vscode' }
    'pwsh' = @{ tool = 'pwsh' }
    'kubectl' = @{ tool = 'kubectl' }
    'terraform' = @{ tool = 'terraform' }
    'docker' = @{ tool = 'docker' }
    'docker-compose' = @{ tool = 'docker' }
    'aws' = @{ tool = 'awscli' }
    'az' = @{ tool = 'azure-cli' }
    'kubectx' = @{ tool = 'kubectx' }
}

if ($script:IsInteractive) {
    if (-not (Get-Variable -Name 'ProfileCommandNotFoundRegistered' -Scope Script -ErrorAction SilentlyContinue)) {
        $script:ProfileCommandNotFoundRegistered = $true
        Register-EngineEvent PowerShell.OnCommandNotFoundAction -SupportEvent -Action {
            param($sender, $eventArgs)
            try {
                $name = $eventArgs.CommandName
                if (-not $name) { return }
                if ($script:CommandToPackageHints.ContainsKey($name)) {
                    $hint = $script:CommandToPackageHints[$name]
                    $msgs = @()
                    if ($hint.module) { $msgs += "PowerShell module: $($hint.module) (Install-Module -Name $($hint.module))" }
                    if ($hint.tool) {
                        $tool = $hint.tool
                        $mgr = Choose-ExternalPackageManager()
                        if ($mgr) {
                            $msgs += "Tool: $tool (install via $mgr: Install-ExternalTool -ToolName '$tool' or use $mgr directly)"
                        } else {
                            $msgs += "Tool: $tool (no supported package manager detected; install manually)"
                        }
                    }
                    Write-Host "`nHint: command '$name' is not available. Suggested install(s):" -ForegroundColor Yellow
                    foreach ($m in $msgs) { Write-Host "  - $m" -ForegroundColor Yellow }
                } else {
                    # Generic hint: suggest installing common modules/tools
                    Write-Host "`nHint: command '$name' not found. You can run Start-ProfileBootstrap to interactively install recommended modules and tools." -ForegroundColor DarkYellow
                }
            } catch {}
        } | Out-Null
    }
}
#endregion

#region 11 - Profile bootstrap helper (interactive once-off installer)
function Start-ProfileBootstrap {
    [CmdletBinding()] param(
        [switch]$InstallModules = $true,
        [switch]$InstallExternalTools = $true,
        [ValidateSet('winget','choco','scoop')][string]$PreferredManager
    )

    if (-not $script:IsInteractive) { Write-ProfileLog "Start-ProfileBootstrap requires interactive shell" -Level WARN; Write-Host "Start-ProfileBootstrap requires an interactive shell."; return $false }

    Write-Host "PowerShell Profile Bootstrap" -ForegroundColor Cyan
    Write-Host "This interactive helper will (optionally):" -ForegroundColor Cyan
    Write-Host " - Install recommended PowerShell modules (PSReadLine, oh-my-posh, PSFzf, ...)" -ForegroundColor Yellow
    Write-Host " - Install recommended external tools (fzf, oh-my-posh binary, git, rg, etc.)" -ForegroundColor Yellow
    Write-Host ""
    $modules = Get-ProfileModulePlan | Where-Object { $_.Required } | ForEach-Object { $_.Name }
    Write-Host "Planned modules:" -ForegroundColor Green
    Write-Host ("  - " + ($modules -join "`n  - ")) -ForegroundColor Green
    $tools = @()
    if ($InstallExternalTools) { $tools = @('fzf','oh-my-posh','git','rg','bat','jq') }
    if ($tools.Count -gt 0) {
        Write-Host "`nPlanned external tools (best-effort):" -ForegroundColor Green
        Write-Host ("  - " + ($tools -join "`n  - ")) -ForegroundColor Green
    }

    Write-Host "`nProceed with bootstrap? (Y/N): " -NoNewline -ForegroundColor Yellow
    $resp = Read-Host
    if ($resp -ne 'Y' -and $resp -ne 'y') { Write-Host "Bootstrap cancelled."; return $false }

    # Install modules
    if ($InstallModules) {
        $provider = if ($Global:ProfileConfig.Provisioning.Provider -eq 'Auto') { Get-PreferredPackageProvider() } else { $Global:ProfileConfig.Provisioning.Provider }
        if (-not $provider) { Write-Host "No PowerShell package provider available (Install-Module/Install-PSResource)." -ForegroundColor Yellow }
        foreach ($m in Get-ProfileModulePlan) {
            if (-not $m.Required) { continue }
            Write-Host "Installing module: $($m.Name) ..." -ForegroundColor Cyan
            $ok = Ensure-ModuleInstalled -Name $m.Name -MinVersion $m.MinVersion -Provider $provider
            if ($ok) { Write-Host "  Installed $($m.Name)." -ForegroundColor Green } else { Write-Host "  Failed to install $($m.Name)." -ForegroundColor Red }
        }
    }

    # Install external tools
    if ($InstallExternalTools) {
        $mgr = $PreferredManager
        if (-not $mgr) { $mgr = Choose-ExternalPackageManager() }
        if (-not $mgr) { Write-Host "No external package manager (winget/choco/scoop) detected; skipping external tool installs." -ForegroundColor Yellow }
        foreach ($t in $tools) {
            Write-Host "Installing external tool: $t ..." -ForegroundColor Cyan
            $ok = Install-ExternalTool -ToolName $t -PreferredManager $mgr
            if ($ok) { Write-Host "  Installed $t (or attempt succeeded)." -ForegroundColor Green } else { Write-Host "  Failed to install $t." -ForegroundColor Red }
        }
    }

    # Finalize: ensure oh-my-posh paths and PSReadLine options configured
    Ensure-OhMyPoshPath | Out-Null
    Ensure-OhMyPoshThemesPath | Out-Null

    try {
        Invoke-FirstRunProvisioning | Out-Null
    } catch {}

    Write-Host "`nBootstrap complete. Restart your shell for all changes to take effect (or re-open a new terminal)." -ForegroundColor Cyan
    return $true
}
#endregion

#region 12 - UX niceties (welcome)
if ($script:IsInteractive -and $Global:ProfileConfig.ShowWelcome) {
    try {
        $ver = $PSVersionTable.PSVersion.ToString()
        $prov = if ($Global:ProfileState.Provisioned) { 'Yes' } else { 'No' }
        Write-Host "PowerShell $ver - Profile loaded. Provisioned: $prov" -ForegroundColor Cyan
        if ($Global:ProfileState.MissingCommands.Count -gt 0) {
            Write-Host "Missing common commands: $($Global:ProfileState.MissingCommands -join ', ')" -ForegroundColor Yellow
            Write-Host "Run Start-ProfileBootstrap to interactively install recommended modules/tools." -ForegroundColor Yellow
        }
    } catch {}
}
#endregion

# End of Microsoft.PowerShell_profile.ps1
