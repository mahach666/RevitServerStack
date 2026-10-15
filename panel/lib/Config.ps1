# Panel configuration: defaults, load, validate, save.
# The runtime config lives outside the repo tree that git tracks
# (panel/runtime/panel.config.json) so user settings never show up as diffs.

Set-StrictMode -Version 1.0

function Get-DiscoveredYears {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $srcDir = Join-Path $RepoRoot 'src'
    $years = @()
    if (Test-Path -LiteralPath $srcDir) {
        Get-ChildItem -LiteralPath $srcDir -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                if ($_.Name -match '^rs(\d{4})$') { $years += [int]$Matches[1] }
            }
    }
    return ($years | Sort-Object)
}

function New-DefaultConfig {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $versions = @()
    foreach ($year in (Get-DiscoveredYears -RepoRoot $RepoRoot)) {
        $versions += [pscustomobject]@{
            year         = $year
            enabled      = $true
            hostPort     = $year
            # Revit itself talks WCF net.tcp on port 808, not HTTP on 80 - the
            # admin web page working proves nothing about Revit being able to
            # connect. 808 is fixed in the protocol, so exactly one version can
            # own it; see Test-PanelConfig.
            revitClients = $false
            # Same location the shipped samples/docker-compose.<year>.yml uses,
            # so an existing installation keeps its models without moving them.
            dataDir      = (Join-Path (Join-Path $RepoRoot 'samples') ("rs$year"))
        }
    }

    return [pscustomobject]@{
        panelPort       = 8787
        windowsContext  = 'desktop-windows'
        proxyContext    = ''      # empty = current docker context (Linux engine)
        composeProject  = 'samples'
        # Address of the machine the engines run on, for links and the proxy.
        # Empty = taken from the docker context (localhost for Docker Desktop).
        windowsHost     = ''
        proxyHost       = ''
        autoOpenBrowser = $true
        proxy           = [pscustomobject]@{
            enabled = $true
            port    = 80
            image   = 'nginx:stable'
        }
        versions        = $versions
    }
}

function Merge-ConfigWithDefaults {
    param($Loaded, $Defaults)

    $result = $Defaults

    $scalarKeys = @('panelPort', 'windowsContext', 'proxyContext', 'composeProject', 'windowsHost', 'proxyHost', 'autoOpenBrowser')
    foreach ($key in $scalarKeys) {
        if ($Loaded.PSObject.Properties.Match($key).Count -gt 0 -and $null -ne $Loaded.$key) {
            $result.$key = $Loaded.$key
        }
    }

    if ($Loaded.PSObject.Properties.Match('proxy').Count -gt 0 -and $null -ne $Loaded.proxy) {
        foreach ($key in @('enabled', 'port', 'image')) {
            if ($Loaded.proxy.PSObject.Properties.Match($key).Count -gt 0 -and $null -ne $Loaded.proxy.$key) {
                $result.proxy.$key = $Loaded.proxy.$key
            }
        }
    }

    # Versions are keyed by year: keep the discovered set (src/rs<year> is the
    # source of truth for which versions exist) and overlay saved settings.
    if ($Loaded.PSObject.Properties.Match('versions').Count -gt 0 -and $null -ne $Loaded.versions) {
        foreach ($savedVersion in $Loaded.versions) {
            if ($savedVersion.PSObject.Properties.Match('year').Count -eq 0) { continue }
            $target = $result.versions | Where-Object { $_.year -eq [int]$savedVersion.year }
            if (-not $target) { continue }
            foreach ($key in @('enabled', 'hostPort', 'dataDir', 'revitClients')) {
                if ($savedVersion.PSObject.Properties.Match($key).Count -gt 0 -and $null -ne $savedVersion.$key) {
                    $target.$key = $savedVersion.$key
                }
            }
        }
    }

    return $result
}

function Test-PanelConfig {
    param($Config)

    $errors = @()

    $panelPort = 0
    if (-not [int]::TryParse([string]$Config.panelPort, [ref]$panelPort) -or $panelPort -lt 1 -or $panelPort -gt 65535) {
        $errors += (T 'cfg.panelPort')
    }

    $proxyPort = 0
    if (-not [int]::TryParse([string]$Config.proxy.port, [ref]$proxyPort) -or $proxyPort -lt 1 -or $proxyPort -gt 65535) {
        $errors += (T 'cfg.proxyPort')
    }

    if ([string]::IsNullOrWhiteSpace([string]$Config.windowsContext)) {
        $errors += (T 'cfg.noWindowsContext')
    }
    if ([string]::IsNullOrWhiteSpace([string]$Config.composeProject)) {
        $errors += (T 'cfg.noProject')
    } elseif ([string]$Config.composeProject -cnotmatch '^[a-z0-9][a-z0-9_-]*\z') {
        $errors += (T 'cfg.badProject')
    }

    # The project and context names are placed on a cmd.exe command line by the
    # job runner, so anything beyond what docker itself accepts is refused.
    foreach ($contextName in @([string]$Config.windowsContext, [string]$Config.proxyContext)) {
        if ($contextName -and -not (Test-ContextName $contextName)) {
            $errors += (T 'cfg.badContext' $contextName)
        }
    }

    $hostFields = @(
        @{ Name = 'windowsHost'; Label = 'settings.windowsHost' },
        @{ Name = 'proxyHost'; Label = 'settings.proxyHost' }
    )
    foreach ($field in $hostFields) {
        $value = ([string]$Config.($field.Name)).Trim()
        if ($value -and -not (Test-HostName $value)) {
            $errors += (T 'cfg.badHost' (T $field.Label))
        }
    }

    $seenPorts = @{}
    foreach ($version in $Config.versions) {
        $hostPort = 0
        if (-not [int]::TryParse([string]$version.hostPort, [ref]$hostPort) -or $hostPort -lt 1 -or $hostPort -gt 65535) {
            $errors += (T 'cfg.versionPort' $version.year)
            continue
        }
        if ($seenPorts.ContainsKey($hostPort)) {
            $errors += (T 'cfg.dupPort' $hostPort ($seenPorts[$hostPort]) $version.year)
        } else {
            $seenPorts[$hostPort] = $version.year
        }
        if ($hostPort -eq $proxyPort) {
            $errors += (T 'cfg.portProxyClash' $version.year $hostPort)
        }
        if ($hostPort -eq $panelPort) {
            $errors += (T 'cfg.portPanelClash' $version.year $hostPort)
        }
        if ([string]::IsNullOrWhiteSpace([string]$version.dataDir)) {
            $errors += (T 'cfg.noDir' $version.year)
        }
    }

    if ($proxyPort -eq $panelPort) {
        $errors += (T 'cfg.proxyPanelClash')
    }

    # net.tcp 808 is baked into the Revit Server protocol - Revit connects to
    # net.tcp://<host>/ModelService<year>/... with no port, so it is always 808.
    # Two containers cannot publish the same host port.
    $netTcpOwners = @($Config.versions | Where-Object { $_.revitClients } | ForEach-Object { [int]$_.year })
    if ($netTcpOwners.Count -gt 1) {
        $errors += (T 'cfg.port808' ($netTcpOwners -join ', '))
    }

    return $errors
}

function Get-PanelConfig {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    $defaults = New-DefaultConfig -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $defaults }

    $raw = Read-TextFileUtf8 $ConfigPath
    if ([string]::IsNullOrWhiteSpace($raw)) { return $defaults }

    try {
        $loaded = $raw | ConvertFrom-Json
    } catch {
        Write-Warning (T 'cfg.unreadable' $ConfigPath $_.Exception.Message)
        return $defaults
    }

    return (Merge-ConfigWithDefaults -Loaded $loaded -Defaults $defaults)
}

function Save-PanelConfig {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    $json = $Config | ConvertTo-Json -Depth 8
    Write-TextFileUtf8 -Path $ConfigPath -Content $json
}

# With a remote engine a models folder is a folder on that machine. A path
# inside this repository only exists here, and a relative path means nothing there.
function Test-RemoteDataDir {
    param([string]$Path, [string]$RepoRoot)

    if ($Path -notmatch '^([A-Za-z]:[\\/]|\\\\)') { return $false }
    if ($RepoRoot) {
        $local = $RepoRoot.TrimEnd('\', '/') + '\'
        if (($Path -replace '/', '\').StartsWith($local, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Get-VersionConfig {
    param($Config, [int]$Year)

    foreach ($version in $Config.versions) {
        if ([int]$version.year -eq $Year) { return $version }
    }
    return $null
}
