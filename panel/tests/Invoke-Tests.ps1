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
foreach ($lib in 'Common', 'Config', 'Compose') { . (Join-Path $panelRoot "lib\$lib.ps1") }

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
    foreach ($bad in @('x&calc', 'My Project', 'UPPER', '-lead', 'a%PATH%')) {
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
    foreach ($bad in @('a&b', 'two words', 'x"y')) {
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
    param([string]$Url, [string]$Method = 'GET', [hashtable]$Headers = @{}, [string]$HostHeader = '')

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = $Method
    $request.Timeout = 15000
    if ($HostHeader) { $request.Host = $HostHeader }
    foreach ($name in $Headers.Keys) { $request.Headers[$name] = [string]$Headers[$name] }
    if ($Method -eq 'POST') { $request.ContentLength = 0 }

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

    $port = Get-FreePort
    $base = "http://localhost:$port"
    $args = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Port {1} -NoBrowser' -f (Join-Path $copy 'panel\server.ps1'), $port
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -PassThru

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

        Assert-True ((Send-TestRequest -Url "$base/..%5Clib%5CCommon.ps1").Status -ne 200) 'path traversal returned a file'
        Assert-True ((Send-TestRequest -Url "$base/%2e%2e/lib/Common.ps1").Status -ne 200) 'encoded path traversal returned a file'

        Assert-Equal 200 (Send-TestRequest -Url "$base/api/shutdown" -Method POST -Headers @{ 'X-Panel-Token' = $token }).Status
        Assert-True ($proc.WaitForExit(10000)) 'the server did not stop after /api/shutdown'
    } finally {
        if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
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
