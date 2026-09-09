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
            year     = $year
            enabled  = $true
            hostPort = $year
            # Same location the shipped samples/docker-compose.<year>.yml uses,
            # so an existing installation keeps its models without moving them.
            dataDir  = (Join-Path (Join-Path $RepoRoot 'samples') ("rs$year"))
        }
    }

    return [pscustomobject]@{
        panelPort       = 8787
        windowsContext  = 'desktop-windows'
        proxyContext    = ''      # empty = current docker context (Linux engine)
        composeProject  = 'samples'
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

    $scalarKeys = @('panelPort', 'windowsContext', 'proxyContext', 'composeProject', 'autoOpenBrowser')
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
            foreach ($key in @('enabled', 'hostPort', 'dataDir')) {
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
        $errors += 'Порт панели должен быть числом от 1 до 65535.'
    }

    $proxyPort = 0
    if (-not [int]::TryParse([string]$Config.proxy.port, [ref]$proxyPort) -or $proxyPort -lt 1 -or $proxyPort -gt 65535) {
        $errors += 'Порт прокси должен быть числом от 1 до 65535.'
    }

    if ([string]::IsNullOrWhiteSpace([string]$Config.windowsContext)) {
        $errors += 'Не задан docker-контекст для Windows-контейнеров.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Config.composeProject)) {
        $errors += 'Не задано имя compose-проекта.'
    }

    $seenPorts = @{}
    foreach ($version in $Config.versions) {
        $hostPort = 0
        if (-not [int]::TryParse([string]$version.hostPort, [ref]$hostPort) -or $hostPort -lt 1 -or $hostPort -gt 65535) {
            $errors += "Revit Server $($version.year): порт должен быть числом от 1 до 65535."
            continue
        }
        if ($seenPorts.ContainsKey($hostPort)) {
            $errors += "Порт $hostPort занят сразу двумя версиями ($($seenPorts[$hostPort]) и $($version.year))."
        } else {
            $seenPorts[$hostPort] = $version.year
        }
        if ($hostPort -eq $proxyPort) {
            $errors += "Revit Server $($version.year): порт $hostPort совпадает с портом прокси."
        }
        if ($hostPort -eq $panelPort) {
            $errors += "Revit Server $($version.year): порт $hostPort совпадает с портом панели."
        }
        if ([string]::IsNullOrWhiteSpace([string]$version.dataDir)) {
            $errors += "Revit Server $($version.year): не задана папка с моделями."
        }
    }

    if ($proxyPort -eq $panelPort) {
        $errors += 'Порт прокси совпадает с портом панели.'
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
        Write-Warning "Не удалось прочитать $ConfigPath ($($_.Exception.Message)). Используются значения по умолчанию."
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

function Get-VersionConfig {
    param($Config, [int]$Year)

    foreach ($version in $Config.versions) {
        if ([int]$version.year -eq $Year) { return $version }
    }
    return $null
}
