# Maps panel buttons to docker command lines and launches them as jobs.

Set-StrictMode -Version 1.0

$script:VersionActions = @('up', 'build', 'stop', 'restart', 'down')
$script:ProxyActions = @('up', 'stop', 'restart', 'down')

function Get-ComposeBaseArgs {
    param([string]$Context, [string]$Project, [string]$ComposeFile)

    $parts = @('docker')
    if (-not [string]::IsNullOrWhiteSpace($Context)) {
        $parts += @('--context', $Context)
    }
    $parts += @('compose', '-p', $Project, '-f', $ComposeFile)
    return $parts
}

function Get-ActionTitle {
    param([string]$Action, [string]$Subject)

    switch ($Action) {
        'up'      { return "Запуск $Subject" }
        'build'   { return "Сборка и запуск $Subject" }
        'stop'    { return "Остановка $Subject" }
        'restart' { return "Перезапуск $Subject" }
        'down'    { return "Удаление контейнера $Subject" }
        default   { return "$Action $Subject" }
    }
}

function Get-ActionComposeArgs {
    param([string]$Action)

    switch ($Action) {
        'up'      { return @('up', '-d') }
        'build'   { return @('up', '-d', '--build') }
        'stop'    { return @('stop') }
        'restart' { return @('restart') }
        'down'    { return @('down') }
        default   { return $null }
    }
}

function Invoke-VersionAction {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][int]$Year,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$ComposeDir,
        [string]$RepoRoot = ''
    )

    if ($script:VersionActions -notcontains $Action) {
        return [pscustomobject]@{ ok = $false; error = "Неизвестное действие: $Action" }
    }

    $version = Get-VersionConfig -Config $Config -Year $Year
    if (-not $version) {
        return [pscustomobject]@{ ok = $false; error = "Версия $Year не найдена в настройках." }
    }

    $target = "rs$Year"
    $existing = Get-RunningJobForTarget -Target $target
    if ($existing) {
        return [pscustomobject]@{
            ok    = $false
            error = "Для Revit Server $Year уже выполняется операция «$($existing.title)»."
            jobId = $existing.id
        }
    }

    if ($Action -eq 'up' -or $Action -eq 'build') {
        $engine = Get-EngineInfo -Context ([string]$Config.windowsContext) -HostOverride ([string]$Config.windowsHost)
        if ($engine.Remote) {
            # The folder is on the server: it is not created from here, and a path
            # inside this repository or a relative one does not exist there.
            if (-not (Test-RemoteDataDir -Path ([string]$version.dataDir) -RepoRoot $RepoRoot)) {
                return [pscustomobject]@{
                    ok    = $false
                    error = ("Docker работает на другом компьютере ($($engine.Host)), поэтому папка моделей версии $Year " +
                        "должна быть полным путём на нём, например D:\RevitServerData\rs$Year, и существовать заранее: Docker для Windows " +
                        "сам её не создаёт. Сейчас: $($version.dataDir)")
                }
            }
        } elseif (-not (Initialize-VersionDataDir -Version $version)) {
            # A bind mount to a missing host folder either fails or gets created by
            # the engine with surprising ownership - create it here, deterministically.
            return [pscustomobject]@{ ok = $false; error = "Не задана папка с моделями для версии $Year." }
        }
    }

    $composeFile = Get-VersionComposePath -ComposeDir $ComposeDir -Year $Year
    if (-not (Test-Path -LiteralPath $composeFile)) {
        return [pscustomobject]@{ ok = $false; error = "Не найден compose-файл: $composeFile" }
    }

    $parts = Get-ComposeBaseArgs -Context ([string]$Config.windowsContext) `
        -Project ([string]$Config.composeProject) -ComposeFile $composeFile
    $parts += Get-ActionComposeArgs -Action $Action

    $job = Start-PanelJob -Title (Get-ActionTitle -Action $Action -Subject "Revit Server $Year") `
        -Kind $Action -Target $target -CommandLine (ConvertTo-CliArgLine $parts)

    return [pscustomobject]@{ ok = $true; jobId = $job.id; title = $job.title }
}

function Invoke-ProxyAction {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$ComposeDir
    )

    if ($script:ProxyActions -notcontains $Action) {
        return [pscustomobject]@{ ok = $false; error = "Неизвестное действие: $Action" }
    }

    $existing = Get-RunningJobForTarget -Target 'proxy'
    if ($existing) {
        return [pscustomobject]@{
            ok    = $false
            error = "Для прокси уже выполняется операция «$($existing.title)»."
            jobId = $existing.id
        }
    }

    $composeFile = Get-ProxyComposePath -ComposeDir $ComposeDir
    if (-not (Test-Path -LiteralPath $composeFile)) {
        return [pscustomobject]@{ ok = $false; error = "Не найден compose-файл прокси: $composeFile" }
    }

    $parts = Get-ComposeBaseArgs -Context ([string]$Config.proxyContext) `
        -Project ([string]$Config.composeProject) -ComposeFile $composeFile
    $parts += Get-ActionComposeArgs -Action $Action

    $subject = "прокси (порт $([int]$Config.proxy.port))"
    $job = Start-PanelJob -Title (Get-ActionTitle -Action $Action -Subject $subject) `
        -Kind $Action -Target 'proxy' -CommandLine (ConvertTo-CliArgLine $parts)

    return [pscustomobject]@{ ok = $true; jobId = $job.id; title = $job.title }
}

<#
.SYNOPSIS
    Starts Docker Desktop, or switches the daemon to Windows containers.
#>
function Invoke-EngineAction {
    param([Parameter(Mandatory = $true)][string]$Action)

    $existing = Get-RunningJobForTarget -Target 'engine'
    if ($existing) {
        return [pscustomobject]@{ ok = $false; error = "Уже выполняется: «$($existing.title)»."; jobId = $existing.id }
    }

    switch ($Action) {
        'start-desktop' {
            $exe = Get-DockerDesktopExePath
            if (-not $exe) {
                return [pscustomobject]@{ ok = $false; error = 'Не найден Docker Desktop.exe. Установите Docker Desktop.' }
            }
            $job = Start-PanelJob -Title 'Запуск Docker Desktop' -Kind 'start-desktop' -Target 'engine' `
                -CommandLine ("start `"`" $(ConvertTo-CliArg $exe)")
            return [pscustomobject]@{ ok = $true; jobId = $job.id; title = $job.title }
        }
        'switch-windows' {
            $exe = Get-DockerCliExePath
            if (-not $exe) {
                return [pscustomobject]@{ ok = $false; error = 'Не найден DockerCli.exe. Переключите движок вручную в Docker Desktop.' }
            }
            $job = Start-PanelJob -Title 'Переключение на Windows-контейнеры' -Kind 'switch-windows' -Target 'engine' `
                -CommandLine ("$(ConvertTo-CliArg $exe) -SwitchWindowsEngine")
            return [pscustomobject]@{ ok = $true; jobId = $job.id; title = $job.title }
        }
        default {
            return [pscustomobject]@{ ok = $false; error = "Неизвестное действие: $Action" }
        }
    }
}

<#
.SYNOPSIS
    Starts every enabled version, plus the proxy when it is enabled.
.DESCRIPTION
    Returns one job per target. They run in parallel: each is an independent
    detached process, and docker serialises what it has to on its own.
#>
function Invoke-StartAll {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$ComposeDir,
        [string]$RepoRoot = ''
    )

    $results = @()
    foreach ($version in $Config.versions) {
        if (-not $version.enabled) { continue }
        $results += [pscustomobject]@{
            target = "rs$([int]$version.year)"
            result = (Invoke-VersionAction -Config $Config -Year ([int]$version.year) -Action 'up' -ComposeDir $ComposeDir -RepoRoot $RepoRoot)
        }
    }
    if ($Config.proxy.enabled) {
        $results += [pscustomobject]@{
            target = 'proxy'
            result = (Invoke-ProxyAction -Config $Config -Action 'up' -ComposeDir $ComposeDir)
        }
    }
    return $results
}

function Invoke-StopAll {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$ComposeDir
    )

    $results = @()
    foreach ($version in $Config.versions) {
        $results += [pscustomobject]@{
            target = "rs$([int]$version.year)"
            result = (Invoke-VersionAction -Config $Config -Year ([int]$version.year) -Action 'stop' -ComposeDir $ComposeDir)
        }
    }
    $results += [pscustomobject]@{
        target = 'proxy'
        result = (Invoke-ProxyAction -Config $Config -Action 'stop' -ComposeDir $ComposeDir)
    }
    return $results
}
