<#
.SYNOPSIS
    Self-checks for the control panel. No docker and no test framework needed.
.DESCRIPTION
    powershell -NoProfile -ExecutionPolicy Bypass -File panel\tests\Invoke-Tests.ps1

    Exits with 1 when any check fails. The server check starts the panel from a
    throwaway copy, so the real panel\runtime folder is never touched.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$panelRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($lib in 'Common', 'Config', 'Compose', 'Docker') { . (Join-Path $panelRoot "lib\$lib.ps1") }

$script:failed = 0

function Check {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Write-Host "ok    $Name"
    } catch {
        $script:failed++
        Write-Host "FAIL  $Name : $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-True {
    param($Condition, [string]$Message = 'condition is false')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual)
    if ($Expected -cne $Actual) { throw "expected [$Expected], got [$Actual]" }
}

function New-TempDir {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('rss-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

# A repo root that only has what version discovery looks at.
function New-FakeRepo {
    param([int[]]$Years = @(2022, 2025))
    $root = New-TempDir
    foreach ($year in $Years) { New-Item -ItemType Directory -Path (Join-Path $root "src\rs$year") -Force | Out-Null }
    return $root
}

# ---------------------------------------------------------- argument quoting --

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RssArgv {
    [DllImport("shell32.dll", SetLastError = true)]
    static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string line, out int count);
    public static string[] Parse(string line) {
        int n; IntPtr p = CommandLineToArgvW(line, out n);
        var r = new string[n];
        for (int i = 0; i < n; i++) r[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(p, i * IntPtr.Size));
        return r;
    }
}
'@

Check 'ConvertTo-CliArg survives the Windows argv parser' {
    $cases = @(
        'plain',
        'with space',
        'C:\dir with space\',
        'C:\dir with space\sub\file.yml',
        'say "hi" there',
        'a"b',
        'back\\"q',
        'R&D',
        'a^b',
        'trail+'
    )
    foreach ($case in $cases) {
        $parsed = [RssArgv]::Parse('x.exe ' + (ConvertTo-CliArg $case))
        Assert-True ($parsed.Count -eq 2) "[$case] became $($parsed.Count - 1) arguments"
        Assert-Equal $case $parsed[1]
    }
}

Check 'ConvertTo-CliArg quotes cmd.exe metacharacters' {
    foreach ($case in @('a&b', 'a|b', 'a<b', 'a>b', 'a^b', '(a)')) {
        Assert-Equal ('"' + $case + '"') (ConvertTo-CliArg $case)
    }
}

# -------------------------------------------------------------------- config --

Check 'default config is valid' {
    $repo = New-FakeRepo
    $config = New-DefaultConfig -RepoRoot $repo
    Assert-Equal 2 @($config.versions).Count
    Assert-Equal 0 @(Test-PanelConfig -Config $config).Count
}

Check 'compose project name is validated' {
    $config = New-DefaultConfig -RepoRoot (New-FakeRepo)
    foreach ($bad in @('x&calc', 'My Project', 'UPPER', '-lead', 'a%PATH%', "samples`n")) {
        $config.composeProject = $bad
        Assert-True (@(Test-PanelConfig -Config $config).Count -ge 1) "[$bad] was accepted"
    }
    foreach ($good in @('samples', 'revit-server-stack', 'rs_1')) {
        $config.composeProject = $good
        Assert-Equal 0 @(Test-PanelConfig -Config $config).Count
    }
}

Check 'docker context names are validated' {
    $config = New-DefaultConfig -RepoRoot (New-FakeRepo)
    foreach ($bad in @('a&b', 'two words', 'x"y', "ctx`n")) {
        $config.windowsContext = $bad
        Assert-True (@(Test-PanelConfig -Config $config).Count -ge 1) "[$bad] was accepted as windowsContext"
    }
    $config.windowsContext = 'desktop-windows'
    $config.proxyContext = 'a|b'
    Assert-True (@(Test-PanelConfig -Config $config).Count -ge 1) 'bad proxyContext was accepted'
    $config.proxyContext = ''
    Assert-Equal 0 @(Test-PanelConfig -Config $config).Count
}

Check 'port clashes and a second port 808 owner are rejected' {
    $config = New-DefaultConfig -RepoRoot (New-FakeRepo)
    $config.versions[1].hostPort = $config.versions[0].hostPort
    Assert-True (@(Test-PanelConfig -Config $config).Count -ge 1) 'duplicate host port was accepted'

    $config = New-DefaultConfig -RepoRoot (New-FakeRepo)
    $config.versions[0].revitClients = $true
    $config.versions[1].revitClients = $true
    Assert-True (@(Test-PanelConfig -Config $config).Count -ge 1) 'two port 808 owners were accepted'
}

Check 'saved settings overlay the discovered versions' {
    $defaults = New-DefaultConfig -RepoRoot (New-FakeRepo)
    $saved = '{"panelPort":9001,"versions":[{"year":2022,"hostPort":9999},{"year":2019,"hostPort":1}]}' | ConvertFrom-Json
    $merged = Merge-ConfigWithDefaults -Loaded $saved -Defaults $defaults
    Assert-Equal 9001 $merged.panelPort
    Assert-Equal 2 @($merged.versions).Count
    Assert-Equal 9999 (Get-VersionConfig -Config $merged -Year 2022).hostPort
    Assert-True ($null -eq (Get-VersionConfig -Config $merged -Year 2019)) 'a version without a Dockerfile folder appeared'
}

# ------------------------------------------------------------ generated files --

Check 'compose and nginx files are generated from the config' {
    $repo = New-FakeRepo
    $composeDir = Join-Path (New-TempDir) 'compose'
    $config = New-DefaultConfig -RepoRoot $repo
    $config.versions[0].revitClients = $true
    $config.versions[1].enabled = $false
    $config.windowsContext = 'rss-test-no-such-context' # not a real context: the engine counts as local

    Update-GeneratedFiles -Config $config -RepoRoot $repo -ComposeDir $composeDir | Out-Null

    $compose2022 = Get-Content -LiteralPath (Join-Path $composeDir 'docker-compose.2022.yml') -Raw
    Assert-True ($compose2022 -match "'2022:80'") 'host port mapping is missing'
    Assert-True ($compose2022 -match "'808:808'") 'port 808 mapping is missing'

    $compose2025 = Get-Content -LiteralPath (Join-Path $composeDir 'docker-compose.2025.yml') -Raw
    Assert-True ($compose2025 -notmatch '808:808') 'port 808 leaked into a version that does not serve Revit'

    $nginx = Get-Content -LiteralPath (Join-Path $composeDir 'proxy\nginx.conf') -Raw
    Assert-True ($nginx -match 'upstream rs2022') 'enabled version is missing from nginx'
    Assert-True ($nginx -notmatch 'upstream rs2025') 'disabled version is routed by nginx'
}

# ------------------------------------------------------------------- engines --

Check 'engines: local and remote endpoints are told apart' {
    $cases = @(
        @{ Endpoint = '';                                            Remote = $false; Host = 'localhost' },
        @{ Endpoint = 'npipe:////./pipe/dockerDesktopWindowsEngine'; Remote = $false; Host = 'localhost' },
        @{ Endpoint = 'unix:///var/run/docker.sock';                 Remote = $false; Host = 'localhost' },
        @{ Endpoint = 'tcp://localhost:2375';                        Remote = $false; Host = 'localhost' },
        @{ Endpoint = 'tcp://127.0.0.1:2375';                        Remote = $false; Host = 'localhost' },
        @{ Endpoint = 'tcp://10.0.0.5:2376';                         Remote = $true;  Host = '10.0.0.5' },
        @{ Endpoint = 'tcp://revit.example.com:2376';                Remote = $true;  Host = 'revit.example.com' },
        @{ Endpoint = 'ssh://builder@rss-test-host.invalid';         Remote = $true;  Host = 'rss-test-host.invalid' }
    )
    foreach ($case in $cases) {
        $found = Resolve-EngineEndpoint $case.Endpoint
        Assert-Equal $case.Remote $found.Remote
        Assert-Equal $case.Host $found.Host
        Assert-Equal $false $found.HostInvalid
    }

    $v6 = Resolve-EngineEndpoint 'tcp://[fd00::5]:2376'
    Assert-True ($v6.Remote -and -not $v6.HostInvalid) 'a bracketed IPv6 address was not accepted'

    # A remote engine whose address cannot be used must not pass for a local one.
    foreach ($bad in 'tcp://a;b:2376', 'tcp://under_score:2376', 'ssh://host name') {
        $found = Resolve-EngineEndpoint $bad
        Assert-True ($found.Remote -and $found.HostInvalid) "[$bad] was not reported as an unusable remote address"
    }
}

Check 'engines: the address override wins, and addresses are validated' {
    foreach ($good in '', 'srv', '10.0.0.5', 'srv.example.com', '[fd00::5]') {
        $config = New-DefaultConfig -RepoRoot (New-FakeRepo)
        $config.windowsHost = $good
        $config.proxyHost = $good
        Assert-Equal 0 @(Test-PanelConfig -Config $config).Count
    }
    foreach ($bad in 'http://srv', 'srv:2022', 'a b', 'a;b', 'a/b', '-srv', 'srv}') {
        $config = New-DefaultConfig -RepoRoot (New-FakeRepo)
        $config.windowsHost = $bad
        Assert-True (@(Test-PanelConfig -Config $config).Count -ge 1) "[$bad] was accepted as windowsHost"
        $config.windowsHost = ''
        $config.proxyHost = $bad
        Assert-True (@(Test-PanelConfig -Config $config).Count -ge 1) "[$bad] was accepted as proxyHost"
    }

    $info = Get-EngineInfo -Context 'rss-test-no-such-context' -HostOverride ' revit-srv '
    Assert-Equal 'revit-srv' $info.Host
    Assert-Equal 'localhost' $info.DetectedHost
}

Check 'engines: the proxy upstream follows the engine of the Windows containers' {
    $repo = New-FakeRepo -Years @(2022)
    $composeDir = Join-Path (New-TempDir) 'compose'
    $config = New-DefaultConfig -RepoRoot $repo
    $config.windowsContext = 'rss-test-no-such-context'

    Update-GeneratedFiles -Config $config -RepoRoot $repo -ComposeDir $composeDir | Out-Null
    $nginx = Get-Content -LiteralPath (Join-Path $composeDir 'proxy\nginx.conf') -Raw
    Assert-True ($nginx -match 'server host\.docker\.internal:2022;') 'a local engine is not reached through host.docker.internal'

    $config.windowsHost = 'revit-srv.example.com'
    Update-GeneratedFiles -Config $config -RepoRoot $repo -ComposeDir $composeDir | Out-Null
    $nginx = Get-Content -LiteralPath (Join-Path $composeDir 'proxy\nginx.conf') -Raw
    Assert-True ($nginx -match 'server revit-srv\.example\.com:2022;') 'the address of the server is not used as the upstream'
    Assert-True ($nginx -notmatch 'server host\.docker\.internal') 'host.docker.internal is still an upstream'

    # Nothing but a host name may reach nginx.conf.
    $refused = $false
    try { Write-ProxyNginxConf -Config $config -ComposeDir $composeDir -UpstreamHost 'a;b' | Out-Null } catch { $refused = $true }
    Assert-True $refused 'an upstream with ";" was written into nginx.conf'
}

Check 'engines: a remote engine needs a models folder on the server' {
    $root = 'C:\work\stack'
    foreach ($good in 'D:\RevitServerData\rs2022', 'D:/RevitServerData/rs2022', '\\nas\revit\rs2022', 'C:\work\stack2\rs2022') {
        Assert-True (Test-RemoteDataDir -Path $good -RepoRoot $root) "[$good] was refused"
    }
    foreach ($bad in 'rs2022', '.\rs2022', 'C:\work\stack\samples\rs2022', 'c:/work/stack/samples/rs2022', '') {
        Assert-True (-not (Test-RemoteDataDir -Path $bad -RepoRoot $root)) "[$bad] was accepted"
    }
}

Check 'proxy compose: nginx.conf travels inside the file, not as a bind mount' {
    $repo = New-FakeRepo -Years @(2022)
    $composeDir = Join-Path (New-TempDir) 'compose'
    $config = New-DefaultConfig -RepoRoot $repo
    $config.windowsContext = 'rss-test-no-such-context'
    $config.windowsHost = 'revit-srv.example.com'
    Update-GeneratedFiles -Config $config -RepoRoot $repo -ComposeDir $composeDir | Out-Null

    # A bind mount names a path on the machine of the engine: wrong for a remote one.
    $composePath = Join-Path $composeDir 'docker-compose.proxy.yml'
    $yml = Get-Content -LiteralPath $composePath -Raw
    Assert-True ($yml -notmatch 'type: bind') 'the proxy still mounts a file of this machine'
    Assert-True ($yml -match 'NGINX_CONF: \|') 'the config is not in the compose file'

    $composeCli = $false
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        & docker compose version 2>$null | Out-Null
        $composeCli = ($LASTEXITCODE -eq 0)
    }
    if (-not $composeCli) {
        Write-Host '      the round trip through "docker compose config" was skipped: no docker compose'
        return
    }
    $model = (& docker compose -p samples -f $composePath config --format json) -join "`n" | ConvertFrom-Json
    # config prints a literal $ as $$ again, so that its output can be fed back
    $seen = ([string]$model.services.'revit-proxy'.environment.NGINX_CONF).Replace('$$', '$').TrimEnd()
    $generated = (Read-TextFileUtf8 (Join-Path $composeDir 'proxy\nginx.conf')).Replace("`r`n", "`n").TrimEnd()
    Assert-True ($seen -ceq $generated) 'the container would get an nginx.conf different from the generated one'
    Assert-True (([string]($model.services.'revit-proxy'.command -join ' ')) -match 'exec nginx') 'the container does not start nginx'
}

Check 'actions: a remote engine gets a folder on the server, a local one gets it created' {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host '      skipped: no docker CLI'
        return
    }
    $saved = $env:DOCKER_CONFIG
    $env:DOCKER_CONFIG = New-TempDir
    try {
        . (Join-Path $panelRoot 'lib\Jobs.ps1')
        . (Join-Path $panelRoot 'lib\Actions.ps1')
        Initialize-JobStore -Directory (Join-Path (New-TempDir) 'jobs')
        # Takes the place of the real one for this check: record the command, run nothing.
        $script:captured = $null
        function Start-PanelJob {
            param($Title, $Kind, $Target, $CommandLine, $WorkingDirectory = '')
            $script:captured = $CommandLine
            return [pscustomobject]@{ id = 'test'; title = $Title }
        }

        Assert-True (New-RemoteContext -Name 'rss-win' -Endpoint 'ssh://builder@win-server').ok 'the context was not created'
        $repo = New-FakeRepo -Years @(2022)
        $composeDir = Join-Path (New-TempDir) 'compose'
        $config = New-DefaultConfig -RepoRoot $repo
        $config.windowsContext = 'rss-win'
        Update-GeneratedFiles -Config $config -RepoRoot $repo -ComposeDir $composeDir | Out-Null
        $localFolder = Join-Path $repo 'samples\rs2022'

        # The default folder is inside this repository: refuse, create nothing, start nothing.
        $result = Invoke-VersionAction -Config $config -Year 2022 -Action 'up' -ComposeDir $composeDir -RepoRoot $repo
        Assert-True (-not $result.ok) 'a remote engine was given a folder of this machine'
        Assert-True ($null -eq $script:captured) 'a job was started anyway'
        Assert-True (-not (Test-Path -LiteralPath $localFolder)) 'a local folder was created for a remote engine'

        # A path on the server: the job goes to the remote context, and nothing is created here.
        (Get-VersionConfig -Config $config -Year 2022).dataDir = 'D:\RevitServerData\rs2022'
        $result = Invoke-VersionAction -Config $config -Year 2022 -Action 'up' -ComposeDir $composeDir -RepoRoot $repo
        Assert-True $result.ok 'a folder on the server was refused'
        Assert-True ($script:captured -match 'docker --context rss-win compose -p samples -f .*docker-compose\.2022\.yml up -d') "unexpected command: $script:captured"
        Assert-True (-not (Test-Path -LiteralPath $localFolder)) 'a local folder was created for a remote engine'

        # A local engine: the folder is created here, as before.
        $config.windowsContext = 'rss-test-no-such-context'
        (Get-VersionConfig -Config $config -Year 2022).dataDir = $localFolder
        $script:captured = $null
        $result = Invoke-VersionAction -Config $config -Year 2022 -Action 'up' -ComposeDir $composeDir -RepoRoot $repo
        Assert-True $result.ok 'a local engine was refused'
        Assert-True (Test-Path -LiteralPath $localFolder -PathType Container) 'the local folder was not created'
    } finally {
        if ($null -eq $saved) { Remove-Item Env:\DOCKER_CONFIG -ErrorAction SilentlyContinue } else { $env:DOCKER_CONFIG = $saved }
    }
}

Check 'engines: names and addresses of contexts are validated strictly' {
    foreach ($good in 'revit-server', 'win_2022', 'a.b+c') {
        Assert-True (Test-ContextName $good) "[$good] was refused as a context name"
    }
    foreach ($bad in '', 'has space', '-lead', 'x"y', 'a&b', "name`n") {
        Assert-True (-not (Test-ContextName $bad)) "[$($bad -replace "`n", '\n')] was accepted as a context name"
    }
    foreach ($good in 'ssh://srv', 'ssh://builder@win-server', 'ssh://builder@10.0.0.5:2222', 'tcp://srv:2376', 'tcp://[fd00::5]:2376') {
        Assert-True (Test-ContextEndpoint $good) "[$good] was refused as an address"
    }
    foreach ($bad in '', 'srv', 'npipe:////./pipe/x', 'ssh://', 'ssh://-oFoo@srv', 'ssh://a b', 'tcp://a;b', 'ssh://srv/x', "ssh://srv`n") {
        Assert-True (-not (Test-ContextEndpoint $bad)) "[$($bad -replace "`n", '\n')] was accepted as an address"
    }
}

Check 'engines: remote contexts are created and read back' {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host '      skipped: no docker CLI (the engine is not needed, only the CLI)'
        return
    }
    $saved = $env:DOCKER_CONFIG
    $env:DOCKER_CONFIG = New-TempDir   # contexts of this check never touch the real ones
    try {
        foreach ($bad in @(@('has space', 'ssh://srv'), @('-lead', 'ssh://srv'), @('ok-name', 'npipe:////./pipe/x'),
                           @('ok-name', 'ssh://-oFoo@srv'), @('ok-name', 'tcp://a;b'), @('ok-name', "ssh://srv`n"))) {
            Assert-True (-not (New-RemoteContext -Name $bad[0] -Endpoint $bad[1]).ok) "[$($bad -join ' ')] was accepted"
        }

        Assert-True (New-RemoteContext -Name 'rss-win' -Endpoint 'ssh://builder@win-server').ok 'the ssh context was not created'
        Assert-True (New-RemoteContext -Name 'rss-tcp' -Endpoint 'tcp://10.0.0.5:2376').ok 'the tcp context was not created'
        Assert-True (-not (New-RemoteContext -Name 'rss-win' -Endpoint 'ssh://other').ok) 'a second context with the same name was accepted'

        $ssh = Get-EngineInfo -Context 'rss-win'
        Assert-True $ssh.Remote 'the ssh context counts as local'
        Assert-Equal 'win-server' $ssh.Host
        $tcp = Get-EngineInfo -Context 'rss-tcp'
        Assert-True $tcp.Remote 'the tcp context counts as local'
        Assert-Equal '10.0.0.5' $tcp.Host
        Assert-True (@(Get-DockerContextNames) -contains 'rss-win') 'the new context is not in the list'
    } finally {
        if ($null -eq $saved) { Remove-Item Env:\DOCKER_CONFIG -ErrorAction SilentlyContinue } else { $env:DOCKER_CONFIG = $saved }
    }
}

# -------------------------------------------------------------------- server --

function Get-FreePort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    return $port
}

# Returns the HTTP status and body; WebException still carries both.
function Send-TestRequest {
    param([string]$Url, [string]$Method = 'GET', [hashtable]$Headers = @{}, [string]$HostHeader = '', [string]$Body = '')

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = $Method
    $request.Timeout = 15000
    if ($HostHeader) { $request.Host = $HostHeader }
    foreach ($name in $Headers.Keys) { $request.Headers[$name] = [string]$Headers[$name] }
    if ($Method -eq 'POST') {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentType = 'application/json'
        $request.ContentLength = $bytes.Length
        if ($bytes.Length -gt 0) {
            $stream = $request.GetRequestStream()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Close() }
        }
    }

    try {
        $response = $request.GetResponse()
    } catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if (-not $response) { throw }
    }
    try {
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        return [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $reader.ReadToEnd() }
    } finally { $response.Close() }
}

Check 'server: token, Host header, path traversal, shutdown' {
    $copy = New-FakeRepo -Years @(2022)
    Copy-Item -LiteralPath $panelRoot -Destination (Join-Path $copy 'panel') -Recurse
    $runtimeCopy = Join-Path $copy 'panel\runtime'
    if (Test-Path -LiteralPath $runtimeCopy) { Remove-Item -LiteralPath $runtimeCopy -Recurse -Force }

    # The panel reads and writes docker contexts: give it a config folder of its own.
    $hasDocker = [bool](Get-Command docker -ErrorAction SilentlyContinue)
    $savedDockerConfig = $env:DOCKER_CONFIG
    if ($hasDocker) { $env:DOCKER_CONFIG = New-TempDir }

    $port = Get-FreePort
    $base = "http://localhost:$port"
    $panelArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Port {1} -NoBrowser' -f (Join-Path $copy 'panel\server.ps1'), $port
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $panelArgs -WindowStyle Hidden -PassThru

    try {
        $index = $null
        for ($i = 0; $i -lt 40 -and -not $index; $i++) {
            Start-Sleep -Milliseconds 500
            if ($proc.HasExited) { throw 'the server exited during start-up' }
            try { $index = Send-TestRequest -Url "$base/" } catch { }
        }
        Assert-True ($null -ne $index) 'the server did not answer within 20 seconds'
        Assert-Equal 200 $index.Status
        Assert-True ($index.Body -match 'Revit Server Stack') 'index.html does not show the project name'
        Assert-True ($index.Body -notmatch '__PANEL_TOKEN__') 'the session token was not injected'
        Assert-True ($index.Body -match 'name="panel-token" content="([0-9a-f]{64})"') 'the token is not in the page'
        $token = $Matches[1]

        Assert-Equal 401 (Send-TestRequest -Url "$base/api/config").Status
        Assert-Equal 401 (Send-TestRequest -Url "$base/api/config" -Headers @{ 'X-Panel-Token' = ('0' * 64) }).Status
        # HTTP.sys answers 400 for a Host that matches no prefix; Test-LocalHost
        # (403) is the second line behind it. Either way the page must not load.
        $foreignHost = (Send-TestRequest -Url "$base/" -HostHeader 'evil.example').Status
        Assert-True (@(400, 403) -contains $foreignHost) "a foreign Host header got HTTP $foreignHost"

        $config = Send-TestRequest -Url "$base/api/config" -Headers @{ 'X-Panel-Token' = $token }
        Assert-Equal 200 $config.Status
        Assert-Equal 2022 (($config.Body | ConvertFrom-Json).config.versions[0].year)

        if ($hasDocker) {
            $auth = @{ 'X-Panel-Token' = $token }
            $new = '{"name":"rss-remote","endpoint":"ssh://builder@win-server"}'
            Assert-Equal 401 (Send-TestRequest -Url "$base/api/context" -Method POST -Body $new).Status
            Assert-Equal 400 (Send-TestRequest -Url "$base/api/context" -Method POST -Headers $auth -Body '{"name":"x y","endpoint":"ssh://srv"}').Status
            Assert-Equal 400 (Send-TestRequest -Url "$base/api/context" -Method POST -Headers $auth -Body '{"name":"ok","endpoint":"npipe:////./pipe/x"}').Status
            Assert-Equal 200 (Send-TestRequest -Url "$base/api/context" -Method POST -Headers $auth -Body $new).Status
            $listed = (Send-TestRequest -Url "$base/api/config" -Headers $auth).Body | ConvertFrom-Json
            Assert-True (@($listed.contexts) -contains 'rss-remote') 'the new context is not offered in the settings'
        }

        Assert-True ((Send-TestRequest -Url "$base/..%5Clib%5CCommon.ps1").Status -ne 200) 'path traversal returned a file'
        Assert-True ((Send-TestRequest -Url "$base/%2e%2e/lib/Common.ps1").Status -ne 200) 'encoded path traversal returned a file'

        Assert-Equal 200 (Send-TestRequest -Url "$base/api/shutdown" -Method POST -Headers @{ 'X-Panel-Token' = $token }).Status
        Assert-True ($proc.WaitForExit(10000)) 'the server did not stop after /api/shutdown'
    } finally {
        if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
        if ($null -eq $savedDockerConfig) { Remove-Item Env:\DOCKER_CONFIG -ErrorAction SilentlyContinue } else { $env:DOCKER_CONFIG = $savedDockerConfig }
    }
}

# ------------------------------------------------------------------ launcher --

$repoRoot = Split-Path -Parent $panelRoot
$buildScript = Join-Path $repoRoot 'launcher\Build.ps1'

Check 'launcher: builds, starts the panel, and the panel stops with it' {
    $outDir = New-TempDir
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $buildScript -OutDir $outDir | Out-Null
    Assert-Equal 0 $LASTEXITCODE
    $exe = Join-Path $outDir 'RevitServerStack.exe'
    Assert-True (Test-Path -LiteralPath $exe) 'RevitServerStack.exe was not built'

    $copy = New-FakeRepo -Years @(2022)
    Copy-Item -LiteralPath $panelRoot -Destination (Join-Path $copy 'panel') -Recurse
    $runtimeCopy = Join-Path $copy 'panel\runtime'
    if (Test-Path -LiteralPath $runtimeCopy) { Remove-Item -LiteralPath $runtimeCopy -Recurse -Force }
    Copy-Item -LiteralPath $exe -Destination $copy

    $launcher = Start-Process -FilePath (Join-Path $copy 'RevitServerStack.exe') -ArgumentList '--no-browser' -PassThru
    $serverId = 0
    try {
        $urlFile = Join-Path $copy 'panel\runtime\panel.url'
        $url = $null
        for ($i = 0; $i -lt 40 -and -not $url; $i++) {
            Start-Sleep -Milliseconds 500
            if ($launcher.HasExited) { throw 'the launcher exited during start-up' }
            if (Test-Path -LiteralPath $urlFile) {
                $text = (Get-Content -LiteralPath $urlFile -Raw).Trim()
                if ($text -match '^http://localhost:\d+/$') { $url = $text }
            }
        }
        Assert-True ($null -ne $url) 'the panel address did not appear within 20 seconds'
        Assert-Equal 200 (Send-TestRequest -Url $url).Status

        $server = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($launcher.Id)" | Where-Object { $_.Name -eq 'powershell.exe' })
        Assert-Equal 1 $server.Count
        $serverId = $server[0].ProcessId

        # A killed launcher must not leave a panel without an icon behind.
        $launcher.Kill()
        $stopped = $false
        for ($i = 0; $i -lt 20 -and -not $stopped; $i++) {
            Start-Sleep -Milliseconds 500
            $stopped = -not (Get-Process -Id $serverId -ErrorAction SilentlyContinue)
        }
        Assert-True $stopped 'the panel kept running after the launcher was killed'
        Assert-True (-not (Test-Path -LiteralPath $urlFile)) 'the address file was left behind'
    } finally {
        if (-not $launcher.HasExited) { try { $launcher.Kill() } catch { } }
        if ($serverId) { Stop-Process -Id $serverId -Force -ErrorAction SilentlyContinue }
    }
}

Check 'release: the archive has the exe and the panel, and no local data' {
    $outDir = New-TempDir
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $buildScript -Release -OutDir $outDir | Out-Null
    Assert-Equal 0 $LASTEXITCODE
    $zipFile = @(Get-ChildItem -LiteralPath $outDir -Filter 'RevitServerStack-*.zip')
    Assert-Equal 1 $zipFile.Count

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipFile[0].FullName)
    try { $names = @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }

    $top = $zipFile[0].BaseName
    foreach ($must in 'RevitServerStack.exe', 'panel/server.ps1', 'panel/www/index.html', 'src/rs2022/Dockerfile',
                      'src/rs2027/Dockerfile', 'README.md', 'LICENSE.md', 'Start-Panel.cmd') {
        Assert-True ($names -contains "$top/$must") "$must is missing from the archive"
    }
    foreach ($mustNot in '^[^/]+/panel/runtime/', '^[^/]+/samples/rs20\d\d/', '^[^/]+/launcher/', '^[^/]+/panel/tests/', '\\') {
        Assert-Equal 0 @($names | Where-Object { $_ -match $mustNot }).Count
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $outDir 'RELEASE_NOTES.md')) 'RELEASE_NOTES.md was not written'
    Assert-True ((Get-Content -LiteralPath "$($zipFile[0].FullName).sha256" -Raw) -match '^[0-9a-f]{64}  ') 'the .sha256 file is malformed'
}

if ($script:failed -gt 0) {
    Write-Host "$script:failed check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed.' -ForegroundColor Green
