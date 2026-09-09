# Docker state queries.
#
# Every call is bounded by a timeout: when Docker Desktop is stopped the CLI
# retries the named pipe for a long time, and the panel's HTTP loop is single
# threaded, so an unbounded call would freeze the whole UI.

Set-StrictMode -Version 1.0

function Invoke-Docker {
    param(
        [Parameter(Mandatory = $true)][string[]]$DockerArgs,
        [string]$Context = '',
        [int]$TimeoutSec = 20
    )

    $all = @()
    if (-not [string]::IsNullOrWhiteSpace($Context)) { $all += @('--context', $Context) }
    $all += $DockerArgs
    return (Invoke-Cli -FilePath 'docker' -Arguments $all -TimeoutSec $TimeoutSec)
}

function ConvertFrom-DockerJsonLines {
    param([string]$Text)

    $items = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $items }
    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0) { continue }
        try { $items += ($trimmed | ConvertFrom-Json) } catch { continue }
    }
    return $items
}

<#
.SYNOPSIS
    Lists every container on a docker context, keyed by container name.
#>
function Get-ContainerMap {
    param([string]$Context = '', [int]$TimeoutSec = 15)

    $result = [pscustomobject]@{
        Reachable  = $false
        Error      = ''
        Containers = @{}
    }

    $run = Invoke-Docker -Context $Context -TimeoutSec $TimeoutSec `
        -DockerArgs @('ps', '-a', '--no-trunc', '--format', '{{json .}}')

    if ($run.TimedOut) {
        $result.Error = "Docker не ответил за $TimeoutSec с — движок недоступен или запускается."
        return $result
    }
    if (-not $run.Launched) {
        $result.Error = 'Не найден docker CLI. Установите Docker Desktop и убедитесь, что docker есть в PATH.'
        return $result
    }
    if ($run.ExitCode -ne 0) {
        $message = $run.StdErr
        if ([string]::IsNullOrWhiteSpace($message)) { $message = $run.StdOut }
        $result.Error = ($message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        return $result
    }

    $result.Reachable = $true
    foreach ($item in (ConvertFrom-DockerJsonLines $run.StdOut)) {
        if ($item.PSObject.Properties.Match('Names').Count -eq 0) { continue }
        # A container can carry several comma-separated names.
        foreach ($name in ([string]$item.Names -split ',')) {
            $key = $name.Trim()
            if ($key.Length -eq 0) { continue }
            $result.Containers[$key] = $item
        }
    }
    return $result
}

<#
.SYNOPSIS
    Set of "repository:tag" strings present on a docker context.
#>
function Get-ImageSet {
    param([string]$Context = '', [int]$TimeoutSec = 15)

    $set = @{}
    $run = Invoke-Docker -Context $Context -TimeoutSec $TimeoutSec `
        -DockerArgs @('images', '--format', '{{json .}}')

    if ($run.TimedOut -or -not $run.Launched -or $run.ExitCode -ne 0) { return $set }

    foreach ($item in (ConvertFrom-DockerJsonLines $run.StdOut)) {
        if ($item.PSObject.Properties.Match('Repository').Count -eq 0) { continue }
        $tag = ''
        if ($item.PSObject.Properties.Match('Tag').Count -gt 0) { $tag = [string]$item.Tag }
        if ([string]::IsNullOrWhiteSpace($tag)) { $tag = 'latest' }
        $set["$([string]$item.Repository):$tag"] = $true
    }
    return $set
}

function Get-DockerContextNames {
    param([int]$TimeoutSec = 10)

    $names = @()
    $run = Invoke-Cli -FilePath 'docker' -TimeoutSec $TimeoutSec `
        -Arguments @('context', 'ls', '--format', '{{json .}}')
    if ($run.TimedOut -or -not $run.Launched -or $run.ExitCode -ne 0) { return $names }

    foreach ($item in (ConvertFrom-DockerJsonLines $run.StdOut)) {
        if ($item.PSObject.Properties.Match('Name').Count -gt 0) { $names += [string]$item.Name }
    }
    return $names
}

function Test-DockerDesktopRunning {
    $proc = Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue
    return ($null -ne $proc)
}

function Get-DockerDesktopExePath {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Docker\Docker\Docker Desktop.exe')
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    return ''
}

function Get-DockerCliExePath {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Docker\Docker\DockerCli.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Docker\Docker\DockerCli.exe')
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    return ''
}

# Maps docker's container State to a coarse status the UI colours by.
function ConvertTo-UiState {
    param([string]$DockerState)

    switch ($DockerState) {
        'running'    { return 'running' }
        'restarting' { return 'starting' }
        'created'    { return 'stopped' }
        'paused'     { return 'stopped' }
        'exited'     { return 'stopped' }
        'dead'       { return 'error' }
        default      { return 'stopped' }
    }
}

<#
.SYNOPSIS
    Full snapshot of everything the panel shows: both engines, every version
    container, the built images and the proxy.
#>
function Get-PanelStatus {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [int]$TimeoutSec = 15
    )

    $windows = Get-ContainerMap -Context ([string]$Config.windowsContext) -TimeoutSec $TimeoutSec
    $images = @{}
    if ($windows.Reachable) {
        $images = Get-ImageSet -Context ([string]$Config.windowsContext) -TimeoutSec $TimeoutSec
    }

    $proxyContext = [string]$Config.proxyContext
    $proxyEngine = Get-ContainerMap -Context $proxyContext -TimeoutSec $TimeoutSec

    $project = [string]$Config.composeProject
    $versions = @()
    foreach ($version in $Config.versions) {
        $year = [int]$version.year
        $containerName = "rs$year"
        $imageName = "$project-rs${year}:latest"

        $state = 'absent'
        $statusText = 'Контейнер не создан'
        $ports = ''
        if ($windows.Reachable -and $windows.Containers.ContainsKey($containerName)) {
            $container = $windows.Containers[$containerName]
            $state = ConvertTo-UiState ([string]$container.State)
            $statusText = [string]$container.Status
            if ($container.PSObject.Properties.Match('Ports').Count -gt 0) {
                $ports = [string]$container.Ports
            }
        } elseif (-not $windows.Reachable) {
            $state = 'unknown'
            $statusText = 'Движок Windows-контейнеров недоступен'
        }

        $versions += [pscustomobject]@{
            year       = $year
            enabled    = [bool]$version.enabled
            hostPort   = [int]$version.hostPort
            dataDir    = [string]$version.dataDir
            state      = $state
            statusText = $statusText
            ports      = $ports
            imageBuilt = $images.ContainsKey($imageName)
            imageName  = $imageName
            directUrl  = "http://localhost:$([int]$version.hostPort)/RevitServerAdmin$year/"
            proxyUrl   = "http://localhost:$([int]$Config.proxy.port)/RevitServerAdmin$year/"
        }
    }

    $proxyState = 'absent'
    $proxyStatusText = 'Контейнер не создан'
    if ($proxyEngine.Reachable -and $proxyEngine.Containers.ContainsKey('revit-proxy')) {
        $container = $proxyEngine.Containers['revit-proxy']
        $proxyState = ConvertTo-UiState ([string]$container.State)
        $proxyStatusText = [string]$container.Status
    } elseif (-not $proxyEngine.Reachable) {
        $proxyState = 'unknown'
        $proxyStatusText = 'Linux-движок недоступен'
    }

    return [pscustomobject]@{
        checkedAt     = (Get-Date).ToString('HH:mm:ss')
        dockerDesktop = [bool](Test-DockerDesktopRunning)
        windowsEngine = [pscustomobject]@{
            context   = [string]$Config.windowsContext
            reachable = [bool]$windows.Reachable
            error     = [string]$windows.Error
        }
        proxyEngine   = [pscustomobject]@{
            context   = $proxyContext
            reachable = [bool]$proxyEngine.Reachable
            error     = [string]$proxyEngine.Error
        }
        proxy         = [pscustomobject]@{
            enabled    = [bool]$Config.proxy.enabled
            port       = [int]$Config.proxy.port
            state      = $proxyState
            statusText = $proxyStatusText
            url        = "http://localhost:$([int]$Config.proxy.port)/"
        }
        versions      = $versions
    }
}

<#
.SYNOPSIS
    Probes the Revit Server admin page of every running version.
.DESCRIPTION
    A running container is not the same thing as a ready server: IIS inside the
    Windows container needs a while after start before it answers. Kept separate
    from Get-PanelStatus because probing costs a round trip per version.
#>
function Get-PanelHealth {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Status,
        [int]$TimeoutMs = 6000
    )

    # A cold ASP.NET app pool in a Windows container answers the first request
    # in a couple of seconds, so the budget has to be generous. Too tight a
    # timeout is self-defeating: the probe aborts before the server replies, the
    # app never warms up, and the version looks like it is starting forever.
    $pending = @()
    foreach ($version in $Status.versions) {
        if ($version.state -ne 'running') { continue }
        $pending += [pscustomobject]@{
            key   = "$($version.year)"
            probe = (Start-HttpProbe -Url $version.directUrl -TimeoutMs $TimeoutMs)
        }
    }

    $proxyProbe = $null
    if ($Status.proxy.state -eq 'running') {
        $proxyProbe = Start-HttpProbe -Url $Status.proxy.url -TimeoutMs $TimeoutMs
    }

    # All probes are already in flight, so a shared deadline caps the total wait
    # at one timeout rather than one per version.
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $remaining = { [int][math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds) }

    $health = @{}
    foreach ($item in $pending) {
        $result = Complete-HttpProbe -Probe $item.probe -TimeoutMs (& $remaining)
        $health[$item.key] = [pscustomobject]@{
            ready      = [bool]$result.Reachable
            statusCode = [int]$result.StatusCode
        }
    }

    $proxyReady = $false
    if ($proxyProbe) {
        $proxyReady = [bool](Complete-HttpProbe -Probe $proxyProbe -TimeoutMs (& $remaining)).Reachable
    }

    return [pscustomobject]@{
        versions = $health
        proxy    = $proxyReady
    }
}
