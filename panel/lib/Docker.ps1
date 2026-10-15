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

# --------------------------------------------------------------------- engines --
#
# A docker context points at an engine on this machine (named pipe, unix socket)
# or at a remote one (ssh://, tcp://). The ports a container publishes, and so
# every browser link and the proxy upstream, belong to the machine of the
# engine, which is only localhost for a local one.

$script:EngineCache = @{}

# Endpoint of a context ("" = the current context), or "" when it cannot be read.
function Get-ContextEndpoint {
    param([string]$Context = '', [int]$TimeoutSec = 10)

    $inspectArgs = @('context', 'inspect', '--format', '{{.Endpoints.docker.Host}}')
    if (-not [string]::IsNullOrWhiteSpace($Context)) { $inspectArgs += $Context }
    $run = Invoke-Cli -FilePath 'docker' -Arguments $inspectArgs -TimeoutSec $TimeoutSec
    if ($run.Launched -and -not $run.TimedOut -and $run.ExitCode -eq 0) { return $run.StdOut.Trim() }
    return ''
}

# "pc" in ssh://pc is usually an alias of ~/.ssh/config, which a browser cannot
# resolve. ssh -G prints the effective settings without connecting anywhere.
function Resolve-SshHost {
    param([string]$Alias, [string]$User = '', [int]$Port = -1)

    $sshArgs = @('-G')
    if ($User -match '^[A-Za-z0-9._-]+\z') { $sshArgs += @('-l', $User) }
    if ($Port -gt 0) { $sshArgs += @('-p', [string]$Port) }
    $sshArgs += @('--', $Alias)

    $run = Invoke-Cli -FilePath 'ssh' -Arguments $sshArgs -TimeoutSec 10
    if ($run.Launched -and -not $run.TimedOut -and $run.ExitCode -eq 0) {
        $found = [regex]::Match($run.StdOut, '(?m)^hostname\s+(\S+)\s*$')
        if ($found.Success -and (Test-HostName $found.Groups[1].Value)) { return $found.Groups[1].Value }
    }
    return $Alias
}

function Resolve-EngineEndpoint {
    param([string]$Endpoint)

    $result = [pscustomobject]@{ Endpoint = $Endpoint; Remote = $false; Host = 'localhost'; HostInvalid = $false }
    if ([string]::IsNullOrWhiteSpace($Endpoint)) { return $result }

    $uri = $null
    if (-not [Uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref]$uri)) {
        # Not a valid address, but with a remote scheme it is still a remote engine.
        if ($Endpoint -match '^(ssh|tcp|tls|http|https)://') {
            $result.Remote = $true
            $result.HostInvalid = $true
        }
        return $result
    }
    # npipe:// and unix:// are engines on this machine.
    if (@('ssh', 'tcp', 'tls', 'http', 'https') -notcontains $uri.Scheme) { return $result }

    $name = $uri.Host
    if ($name -and (@('localhost', '127.0.0.1', '[::1]') -contains $name.ToLowerInvariant())) { return $result }

    $result.Remote = $true
    if (-not (Test-HostName $name)) {
        $result.HostInvalid = $true
        return $result
    }
    $result.Host = $name
    if ($uri.Scheme -eq 'ssh') {
        $result.Host = Resolve-SshHost -Alias $name -User $uri.UserInfo -Port $uri.Port
    }
    return $result
}

<#
.SYNOPSIS
    Where the engine of a context runs and under which address it is reached.
.DESCRIPTION
    HostOverride (a setting of the panel) wins over the address found in the
    context. Resolved endpoints are cached for half a minute, because the status
    request comes every few seconds and each lookup starts docker and ssh.
#>
function Get-EngineInfo {
    param([string]$Context = '', [string]$HostOverride = '')

    $cached = $script:EngineCache[$Context]
    if (-not $cached -or ((Get-Date) - $cached.At).TotalSeconds -gt 30) {
        $cached = [pscustomobject]@{ At = (Get-Date); Value = (Resolve-EngineEndpoint (Get-ContextEndpoint -Context $Context)) }
        $script:EngineCache[$Context] = $cached
    }

    $detected = $cached.Value
    $override = $HostOverride.Trim()
    $effective = $detected.Host
    if ($override) { $effective = $override }

    return [pscustomobject]@{
        Context      = $Context
        Endpoint     = $detected.Endpoint
        Remote       = $detected.Remote
        DetectedHost = $detected.Host
        HostInvalid  = ($detected.HostInvalid -and -not $override)
        Host         = $effective
    }
}

# docker context create for an engine on another machine.
function New-RemoteContext {
    param([string]$Name, [string]$Endpoint)

    if (-not (Test-ContextName $Name)) {
        return [pscustomobject]@{ ok = $false; error = 'Имя контекста: латинские буквы, цифры, «-», «_», «.» и «+», начинаться должно с буквы или цифры.' }
    }
    if (-not (Test-ContextEndpoint $Endpoint)) {
        return [pscustomobject]@{ ok = $false; error = 'Адрес: ssh://пользователь@сервер (или ssh://алиас из ~/.ssh/config) либо tcp://сервер:2376.' }
    }

    $run = Invoke-Cli -FilePath 'docker' -TimeoutSec 20 `
        -Arguments @('context', 'create', $Name, '--docker', "host=$Endpoint")
    if (-not $run.Launched) {
        return [pscustomobject]@{ ok = $false; error = 'Не найден docker CLI. Установите Docker и убедитесь, что docker есть в PATH.' }
    }
    if ($run.TimedOut -or $run.ExitCode -ne 0) {
        $message = $run.StdErr
        if ([string]::IsNullOrWhiteSpace($message)) { $message = $run.StdOut }
        $first = ($message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if (-not $first) { $first = 'docker context create не выполнился.' }
        return [pscustomobject]@{ ok = $false; error = [string]$first }
    }

    $script:EngineCache = @{}
    return [pscustomobject]@{ ok = $true }
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
        [int]$TimeoutSec = 15,
        [string]$RepoRoot = ''
    )

    $windowsInfo = Get-EngineInfo -Context ([string]$Config.windowsContext) -HostOverride ([string]$Config.windowsHost)
    $proxyInfo = Get-EngineInfo -Context ([string]$Config.proxyContext) -HostOverride ([string]$Config.proxyHost)

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

        $servesRevit = $false
        if ($version.PSObject.Properties.Match('revitClients').Count -gt 0) {
            $servesRevit = [bool]$version.revitClients
        }

        # With a remote engine the models folder has to be a path on that machine.
        $dataDirOk = $true
        if ($windowsInfo.Remote) {
            $dataDirOk = [bool](Test-RemoteDataDir -Path ([string]$version.dataDir) -RepoRoot $RepoRoot)
        }

        $versions += [pscustomobject]@{
            year         = $year
            enabled      = [bool]$version.enabled
            hostPort     = [int]$version.hostPort
            dataDir      = [string]$version.dataDir
            dataDirOk    = $dataDirOk
            revitClients = $servesRevit
            state        = $state
            statusText   = $statusText
            ports        = $ports
            imageBuilt   = $images.ContainsKey($imageName)
            imageName    = $imageName
            directUrl    = "http://$($windowsInfo.Host):$([int]$version.hostPort)/RevitServerAdmin$year/"
            proxyUrl     = "http://$($proxyInfo.Host):$([int]$Config.proxy.port)/RevitServerAdmin$year/"
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
        # Docker Desktop matters only while one of the two engines is on this machine.
        usesLocalEngine = ((-not $windowsInfo.Remote) -or (-not $proxyInfo.Remote))
        windowsEngine = [pscustomobject]@{
            context     = [string]$Config.windowsContext
            reachable   = [bool]$windows.Reachable
            error       = [string]$windows.Error
            remote      = [bool]$windowsInfo.Remote
            host        = [string]$windowsInfo.Host
            hostInvalid = [bool]$windowsInfo.HostInvalid
        }
        proxyEngine   = [pscustomobject]@{
            context     = $proxyContext
            reachable   = [bool]$proxyEngine.Reachable
            error       = [string]$proxyEngine.Error
            remote      = [bool]$proxyInfo.Remote
            host        = [string]$proxyInfo.Host
            hostInvalid = [bool]$proxyInfo.HostInvalid
        }
        proxy         = [pscustomobject]@{
            enabled    = [bool]$Config.proxy.enabled
            port       = [int]$Config.proxy.port
            state      = $proxyState
            statusText = $proxyStatusText
            url        = "http://$($proxyInfo.Host):$([int]$Config.proxy.port)/"
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
