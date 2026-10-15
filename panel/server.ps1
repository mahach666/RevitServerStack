<#
.SYNOPSIS
    Local control panel of Revit Server Stack: starts, stops and rebuilds the Revit Server docker images.
.DESCRIPTION
    Serves a small web UI on http://localhost:<port>/ and drives docker compose
    behind it. Runs on stock Windows PowerShell 5.1 with no extra installs:
    HttpListener binds a localhost prefix without administrator rights.

    Security: the listener is bound to localhost only and every /api/ call must
    carry the session token that is injected into the page when it is served.
    A page on another origin can neither read that token (CORS) nor set the
    header without a preflight, so it cannot drive docker through this panel.
.PARAMETER Port
    Overrides the port from the saved configuration.
.PARAMETER NoBrowser
    Do not open the browser on start.
.PARAMETER UrlFile
    Once the panel is ready, writes the address it listens on to this file, and
    removes the file on exit. Used by RevitServerStack.exe.
.PARAMETER ParentPid
    Stops the panel when this process is gone, so that it never outlives the
    tray icon that started it. Used by RevitServerStack.exe.
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$NoBrowser,
    [string]$UrlFile = '',
    [int]$ParentPid = 0
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# Start-Panel.cmd puts the console in UTF-8 (chcp 65001); match it here or the
# Russian status messages come out as mojibake. Throws when output is
# redirected, which is fine - nothing to render then.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:PanelRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RepoRoot = Split-Path -Parent $script:PanelRoot
$script:WwwRoot = Join-Path $script:PanelRoot 'www'
$script:RuntimeDir = Join-Path $script:PanelRoot 'runtime'
$script:ComposeDir = Join-Path $script:RuntimeDir 'compose'
$script:ConfigPath = Join-Path $script:RuntimeDir 'panel.config.json'

. (Join-Path $script:PanelRoot 'lib\Common.ps1')
. (Join-Path $script:PanelRoot 'lib\Config.ps1')
. (Join-Path $script:PanelRoot 'lib\Compose.ps1')
. (Join-Path $script:PanelRoot 'lib\Docker.ps1')
. (Join-Path $script:PanelRoot 'lib\Jobs.ps1')
. (Join-Path $script:PanelRoot 'lib\Actions.ps1')

foreach ($dir in @($script:RuntimeDir, $script:ComposeDir)) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

$script:Config = Get-PanelConfig -RepoRoot $script:RepoRoot -ConfigPath $script:ConfigPath
Update-GeneratedFiles -Config $script:Config -RepoRoot $script:RepoRoot -ComposeDir $script:ComposeDir | Out-Null
Initialize-JobStore -Directory (Join-Path $script:RuntimeDir 'jobs')
Remove-OldJobs

$script:Running = $true
$script:StatusCache = $null
$script:StatusCacheAt = [datetime]::MinValue
$script:StatusCacheTtl = [timespan]::FromSeconds(2.5)

$script:Token = -join ((1..32) | ForEach-Object { '{0:x2}' -f (Get-Random -Minimum 0 -Maximum 256) })

# ---------------------------------------------------------------- responses --

function Send-Response {
    param(
        $Context,
        [byte[]]$Bytes,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [int]$StatusCode = 200
    )

    $response = $Context.Response
    try {
        $response.StatusCode = $StatusCode
        $response.ContentType = $ContentType
        $response.Headers['Cache-Control'] = 'no-store'
        # The panel is same-origin only; block framing and sniffing outright.
        $response.Headers['X-Content-Type-Options'] = 'nosniff'
        $response.Headers['X-Frame-Options'] = 'DENY'
        $response.ContentLength64 = $Bytes.Length
        if ($Context.Request.HttpMethod -ne 'HEAD' -and $Bytes.Length -gt 0) {
            $response.OutputStream.Write($Bytes, 0, $Bytes.Length)
        }
    } catch {
        # Client disconnected mid-write: nothing useful to do.
    } finally {
        try { $response.OutputStream.Close() } catch { }
        try { $response.Close() } catch { }
    }
}

function Send-Text {
    param($Context, [string]$Text, [string]$ContentType = 'text/plain; charset=utf-8', [int]$StatusCode = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    Send-Response -Context $Context -Bytes $bytes -ContentType $ContentType -StatusCode $StatusCode
}

function Send-Json {
    param($Context, $Data, [int]$StatusCode = 200)
    $json = $Data | ConvertTo-Json -Depth 10 -Compress
    Send-Text -Context $Context -Text $json -ContentType 'application/json; charset=utf-8' -StatusCode $StatusCode
}

function Send-Error {
    param($Context, [string]$Message, [int]$StatusCode = 400)
    Send-Json -Context $Context -Data ([pscustomobject]@{ ok = $false; error = $Message }) -StatusCode $StatusCode
}

function Get-ContentType {
    param([string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.js'   { return 'application/javascript; charset=utf-8' }
        '.css'  { return 'text/css; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.svg'  { return 'image/svg+xml' }
        '.ico'  { return 'image/x-icon' }
        default { return 'application/octet-stream' }
    }
}

function Send-StaticFile {
    param($Context, [string]$RelativePath)

    $full = Join-Path $script:WwwRoot $RelativePath
    # Trailing separator: without it a sibling folder such as "www-old" would
    # pass the prefix check below.
    $resolvedRoot = [System.IO.Path]::GetFullPath($script:WwwRoot).TrimEnd('\') + '\'
    $resolvedFull = [System.IO.Path]::GetFullPath($full)

    # Refuse anything that escapes www/ (path traversal).
    if (-not $resolvedFull.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Send-Text -Context $Context -Text 'Forbidden' -StatusCode 403
        return
    }
    if (-not (Test-Path -LiteralPath $resolvedFull -PathType Leaf)) {
        Send-Text -Context $Context -Text 'Not found' -StatusCode 404
        return
    }

    if ([System.IO.Path]::GetExtension($resolvedFull) -eq '.html') {
        # The session token is injected here rather than put in the URL, so it
        # never lands in browser history, bookmarks or a Referer header.
        $html = Read-TextFileUtf8 $resolvedFull
        $html = $html.Replace('__PANEL_TOKEN__', $script:Token)
        Send-Text -Context $Context -Text $html -ContentType 'text/html; charset=utf-8'
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($resolvedFull)
    Send-Response -Context $Context -Bytes $bytes -ContentType (Get-ContentType $resolvedFull)
}

# ------------------------------------------------------------------- guards --

function Test-LocalHost {
    param($Request)

    $hostHeader = [string]$Request.Headers['Host']
    if ([string]::IsNullOrWhiteSpace($hostHeader)) { return $false }
    $hostName = ($hostHeader -split ':')[0]
    return @('localhost', '127.0.0.1', '[::1]', '::1') -contains $hostName.ToLowerInvariant()
}

function Test-ApiAuthorized {
    param($Request)

    $supplied = [string]$Request.Headers['X-Panel-Token']
    if ([string]::IsNullOrWhiteSpace($supplied)) { return $false }
    return ($supplied -ceq $script:Token)
}

function Read-RequestBody {
    param($Request)

    if (-not $Request.HasEntityBody) { return $null }
    $encoding = $Request.ContentEncoding
    if (-not $encoding) { $encoding = [System.Text.Encoding]::UTF8 }
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $encoding)
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

# ----------------------------------------------------------------- handlers --

function Get-CachedStatus {
    param([switch]$Force)

    $age = (Get-Date) - $script:StatusCacheAt
    if (-not $Force -and $script:StatusCache -and $age -lt $script:StatusCacheTtl) {
        return $script:StatusCache
    }

    $status = Get-PanelStatus -Config $script:Config -RepoRoot $script:RepoRoot
    $script:StatusCache = $status
    $script:StatusCacheAt = Get-Date
    return $status
}

function Invoke-StatusRequest {
    param($Context)

    $status = Get-CachedStatus
    $runningJobs = @()
    foreach ($job in (Update-JobStates)) {
        $runningJobs += [pscustomobject]@{
            id     = $job.id
            title  = $job.title
            target = $job.target
            kind   = $job.kind
            since  = $job.startedAtText
        }
    }

    Send-Json -Context $Context -Data ([pscustomobject]@{
        ok          = $true
        status      = $status
        runningJobs = $runningJobs
        panel       = [pscustomobject]@{
            repoRoot   = $script:RepoRoot
            composeDir = $script:ComposeDir
            configPath = $script:ConfigPath
        }
    })
}

function Invoke-HealthRequest {
    param($Context)

    $status = Get-CachedStatus
    $health = Get-PanelHealth -Config $script:Config -Status $status
    Send-Json -Context $Context -Data ([pscustomobject]@{ ok = $true; health = $health })
}

function Invoke-ConfigGet {
    param($Context)

    $contexts = Get-DockerContextNames
    # What the contexts point at, so the settings can show it next to the
    # address override fields.
    $windowsEngine = Get-EngineInfo -Context ([string]$script:Config.windowsContext)
    $proxyEngine = Get-EngineInfo -Context ([string]$script:Config.proxyContext)
    Send-Json -Context $Context -Data ([pscustomobject]@{
        ok         = $true
        config     = $script:Config
        contexts   = $contexts
        engines    = [pscustomobject]@{
            windows = [pscustomobject]@{ remote = [bool]$windowsEngine.Remote; detectedHost = [string]$windowsEngine.DetectedHost }
            proxy   = [pscustomobject]@{ remote = [bool]$proxyEngine.Remote; detectedHost = [string]$proxyEngine.DetectedHost }
        }
        repoRoot   = $script:RepoRoot
        composeDir = $script:ComposeDir
    })
}

function Invoke-ContextCreate {
    param($Context, $Body)

    if (-not $Body -or -not $Body.name -or -not $Body.endpoint) {
        Send-Error -Context $Context -Message 'Нужно указать имя контекста и адрес.'
        return
    }

    $result = New-RemoteContext -Name ([string]$Body.name) -Endpoint ([string]$Body.endpoint)
    if (-not $result.ok) {
        Send-Error -Context $Context -Message $result.error
        return
    }

    $script:StatusCache = $null
    Send-Json -Context $Context -Data ([pscustomobject]@{ ok = $true; contexts = (Get-DockerContextNames) })
}

function Invoke-ConfigPost {
    param($Context, $Body)

    if (-not $Body) {
        Send-Error -Context $Context -Message 'Пустое тело запроса.'
        return
    }

    $defaults = New-DefaultConfig -RepoRoot $script:RepoRoot
    $candidate = Merge-ConfigWithDefaults -Loaded $Body -Defaults $defaults

    $errors = Test-PanelConfig -Config $candidate
    if ($errors.Count -gt 0) {
        Send-Json -Context $Context -Data ([pscustomobject]@{ ok = $false; errors = $errors }) -StatusCode 400
        return
    }

    $portChanged = ([int]$candidate.panelPort -ne [int]$script:Config.panelPort)

    $script:Config = $candidate
    Save-PanelConfig -Config $script:Config -ConfigPath $script:ConfigPath
    $written = Update-GeneratedFiles -Config $script:Config -RepoRoot $script:RepoRoot -ComposeDir $script:ComposeDir
    $script:StatusCache = $null

    $notes = @()
    $engine = Get-EngineInfo -Context ([string]$script:Config.windowsContext) -HostOverride ([string]$script:Config.windowsHost)
    if ($engine.Remote) {
        $local = @($script:Config.versions | Where-Object {
            $_.enabled -and -not (Test-RemoteDataDir -Path ([string]$_.dataDir) -RepoRoot $script:RepoRoot)
        } | ForEach-Object { $_.year })
        if ($local.Count -gt 0) {
            $notes += ("Docker работает на другом компьютере ($($engine.Host)): для версий $($local -join ', ') укажите папку моделей " +
                'полным путём на нём, например D:\RevitServerData\rs2022, иначе их нельзя будет запустить. Папку нужно создать на сервере заранее.')
        }
    }
    if ($portChanged) {
        $notes += 'Порт панели изменён — он вступит в силу после перезапуска панели.'
    }
    $notes += 'Изменения портов и папок применяются к контейнеру при следующем запуске (кнопка «Перезапустить» или «Запустить»).'

    Send-Json -Context $Context -Data ([pscustomobject]@{
        ok      = $true
        config  = $script:Config
        written = $written
        notes   = $notes
    })
}

function Invoke-ActionPost {
    param($Context, $Body)

    if (-not $Body -or -not $Body.target -or -not $Body.action) {
        Send-Error -Context $Context -Message 'Нужно указать target и action.'
        return
    }

    $target = [string]$Body.target
    $action = [string]$Body.action
    $script:StatusCache = $null

    if ($target -eq 'all') {
        $results = $null
        if ($action -eq 'up') { $results = Invoke-StartAll -Config $script:Config -ComposeDir $script:ComposeDir -RepoRoot $script:RepoRoot }
        elseif ($action -eq 'stop') { $results = Invoke-StopAll -Config $script:Config -ComposeDir $script:ComposeDir }
        else {
            Send-Error -Context $Context -Message "Для «все» поддерживаются только up и stop."
            return
        }
        Send-Json -Context $Context -Data ([pscustomobject]@{ ok = $true; results = $results })
        return
    }

    if ($target -eq 'proxy') {
        $result = Invoke-ProxyAction -Config $script:Config -Action $action -ComposeDir $script:ComposeDir
        $code = 200
        if (-not $result.ok) { $code = 409 }
        Send-Json -Context $Context -Data $result -StatusCode $code
        return
    }

    if ($target -eq 'engine') {
        $result = Invoke-EngineAction -Action $action
        $code = 200
        if (-not $result.ok) { $code = 409 }
        Send-Json -Context $Context -Data $result -StatusCode $code
        return
    }

    if ($target -match '^rs(\d{4})$') {
        $result = Invoke-VersionAction -Config $script:Config -Year ([int]$Matches[1]) -Action $action -ComposeDir $script:ComposeDir -RepoRoot $script:RepoRoot
        $code = 200
        if (-not $result.ok) { $code = 409 }
        Send-Json -Context $Context -Data $result -StatusCode $code
        return
    }

    Send-Error -Context $Context -Message "Неизвестная цель: $target"
}

function Invoke-JobsRequest {
    param($Context)

    Update-JobStates | Out-Null
    $jobs = @()
    foreach ($job in (Get-PanelJobs -Limit 25)) {
        $jobs += [pscustomobject]@{
            id             = $job.id
            title          = $job.title
            target         = $job.target
            kind           = $job.kind
            startedAt      = $job.startedAt
            startedAtText  = $job.startedAtText
            finishedAt     = $job.finishedAt
            finishedReason = $job.finishedReason
            exitCode       = $job.exitCode
        }
    }
    Send-Json -Context $Context -Data ([pscustomobject]@{ ok = $true; jobs = $jobs })
}

function Invoke-JobLogRequest {
    param($Context, $Query)

    $id = [string]$Query['id']
    if ([string]::IsNullOrWhiteSpace($id) -or $id -notmatch '^[0-9a-f]{12}$') {
        Send-Error -Context $Context -Message 'Некорректный идентификатор задачи.'
        return
    }

    $offset = 0
    if ($Query['offset']) { [int]::TryParse([string]$Query['offset'], [ref]$offset) | Out-Null }

    Update-JobStates | Out-Null
    $job = Get-PanelJob -Id $id
    if (-not $job) {
        Send-Error -Context $Context -Message 'Задача не найдена.' -StatusCode 404
        return
    }

    $chunk = Get-JobLogChunk -Id $id -Offset $offset
    Send-Json -Context $Context -Data ([pscustomobject]@{
        ok             = $true
        id             = $id
        title          = $job.title
        text           = $chunk.text
        offset         = $chunk.offset
        running        = ($null -eq $job.finishedAt)
        exitCode       = $job.exitCode
        finishedReason = $job.finishedReason
    })
}

function Invoke-JobCancel {
    param($Context, $Body)

    if (-not $Body -or -not $Body.id) {
        Send-Error -Context $Context -Message 'Не указан идентификатор задачи.'
        return
    }
    $stopped = Stop-PanelJob -Id ([string]$Body.id)
    $script:StatusCache = $null
    Send-Json -Context $Context -Data ([pscustomobject]@{ ok = $stopped })
}

function Invoke-Request {
    param($Context)

    $request = $Context.Request
    $path = $request.Url.AbsolutePath
    $method = $request.HttpMethod

    if (-not (Test-LocalHost -Request $request)) {
        Send-Text -Context $Context -Text 'Панель принимает запросы только с localhost.' -StatusCode 403
        return
    }

    if (-not $path.StartsWith('/api/')) {
        $relative = $path.TrimStart('/')
        if ([string]::IsNullOrWhiteSpace($relative)) { $relative = 'index.html' }
        Send-StaticFile -Context $Context -RelativePath $relative
        return
    }

    if (-not (Test-ApiAuthorized -Request $request)) {
        Send-Error -Context $Context -Message 'Недействительный токен сессии. Обновите страницу панели.' -StatusCode 401
        return
    }

    $body = $null
    if ($method -eq 'POST') { $body = Read-RequestBody -Request $request }

    switch ($path) {
        '/api/status'     { Invoke-StatusRequest -Context $Context; return }
        '/api/health'     { Invoke-HealthRequest -Context $Context; return }
        '/api/jobs'       { Invoke-JobsRequest -Context $Context; return }
        '/api/job'        { Invoke-JobLogRequest -Context $Context -Query $request.QueryString; return }
        '/api/job/cancel' { Invoke-JobCancel -Context $Context -Body $body; return }
        '/api/context'    { Invoke-ContextCreate -Context $Context -Body $body; return }
        '/api/action'     { Invoke-ActionPost -Context $Context -Body $body; return }
        '/api/config' {
            if ($method -eq 'POST') { Invoke-ConfigPost -Context $Context -Body $body }
            else { Invoke-ConfigGet -Context $Context }
            return
        }
        '/api/shutdown' {
            Send-Json -Context $Context -Data ([pscustomobject]@{ ok = $true })
            $script:Running = $false
            return
        }
        default {
            Send-Error -Context $Context -Message "Неизвестный метод API: $path" -StatusCode 404
        }
    }
}

# --------------------------------------------------------------------- main --

function Start-PanelListener {
    param([int]$PreferredPort)

    for ($candidate = $PreferredPort; $candidate -lt $PreferredPort + 10; $candidate++) {
        $listener = New-Object System.Net.HttpListener
        # localhost prefix only: binding "+" or "*" needs administrator rights
        # and would expose docker control to the whole network.
        $listener.Prefixes.Add("http://localhost:$candidate/")
        try {
            $listener.Start()
            return [pscustomobject]@{ Listener = $listener; Port = $candidate }
        } catch {
            try { $listener.Close() } catch { }
        }
    }
    return $null
}

$preferred = [int]$script:Config.panelPort
if ($Port -gt 0) { $preferred = $Port }

$started = Start-PanelListener -PreferredPort $preferred
if (-not $started) {
    Write-Host ''
    Write-Host "Не удалось занять порт $preferred (и 9 следующих)." -ForegroundColor Red
    Write-Host 'Закройте программу, которая его использует, или задайте другой порт:' -ForegroundColor Red
    Write-Host '    powershell -ExecutionPolicy Bypass -File panel\server.ps1 -Port 9000'
    exit 1
}

$listener = $started.Listener
$url = "http://localhost:$($started.Port)/"

Write-Host ''
Write-Host '  Revit Server Stack: панель управления' -ForegroundColor Cyan
Write-Host "  $url" -ForegroundColor Green
Write-Host ''
Write-Host "  Проект:        $script:RepoRoot"
Write-Host "  Настройки:     $script:ConfigPath"
Write-Host "  Compose-файлы: $script:ComposeDir"
Write-Host ''
Write-Host '  Закрыть панель: Ctrl+C в этом окне (контейнеры продолжат работать).' -ForegroundColor DarkGray
Write-Host ''

if ($UrlFile) { Write-TextFileUtf8 -Path $UrlFile -Content $url }

if (-not $NoBrowser -and $script:Config.autoOpenBrowser) {
    try { Start-Process $url | Out-Null } catch { }
}

try {
    while ($script:Running) {
        # Async accept with a polling wait so Ctrl+C is handled promptly:
        # a blocking GetContext() would swallow it until the next request.
        $task = $listener.GetContextAsync()
        $handle = ([System.IAsyncResult]$task).AsyncWaitHandle
        while ($script:Running -and -not $handle.WaitOne(400)) {
            if ($ParentPid -gt 0 -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) {
                $script:Running = $false
            }
        }
        if (-not $script:Running) { break }
        if (-not $task.IsCompleted) { continue }

        $context = $null
        try { $context = $task.Result } catch { continue }

        try {
            Invoke-Request -Context $context
        } catch {
            Write-Host "Ошибка обработки запроса: $($_.Exception.Message)" -ForegroundColor Red
            try { Send-Error -Context $context -Message $_.Exception.Message -StatusCode 500 } catch { }
        }
    }
} finally {
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
    if ($UrlFile) { Remove-Item -LiteralPath $UrlFile -Force -ErrorAction SilentlyContinue }
    Write-Host ''
    Write-Host 'Панель остановлена. Запущенные контейнеры продолжают работать.' -ForegroundColor DarkGray
}
