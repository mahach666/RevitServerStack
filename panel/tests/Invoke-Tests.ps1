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
$repoRoot = Split-Path -Parent $panelRoot
foreach ($lib in 'Common', 'I18n', 'Config', 'Compose', 'Docker') { . (Join-Path $panelRoot "lib\$lib.ps1") }
Initialize-I18n -Directory (Join-Path $panelRoot 'www\i18n')

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

function Read-Catalog {
    param([string]$Code)
    $text = [System.IO.File]::ReadAllText((Join-Path $panelRoot "www\i18n\$Code.json"), [System.Text.Encoding]::UTF8)
    $table = [ordered]@{}
    foreach ($entry in ($text | ConvertFrom-Json).PSObject.Properties) { $table[$entry.Name] = [string]$entry.Value }
    return $table
}

function Get-Placeholders { param([string]$Text) return (([regex]::Matches($Text, '\{(\d+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object) -join ',') }
function Get-Markup { param([string]$Text) return (([regex]::Matches($Text, '</?[a-zA-Z][^>]*>') | ForEach-Object { $_.Value }) -join '') }

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

Check 'config: port 808 is checked against host ports and the proxy, a disabled version does not own it' {
    $config = New-DefaultConfig -RepoRoot (New-FakeRepo)
    $config.versions[0].hostPort = 808
    $config.versions[1].revitClients = $true
    $errors = @(Test-PanelConfig -Config $config)
    Assert-True ($errors -contains (T 'cfg.port808Version' 2022 '2025')) "host port 808 next to a 808 owner was accepted: $($errors -join ' | ')"

    # The version that owns 808 for Revit cannot also publish its own HTTP port there.
    $config = New-DefaultConfig -RepoRoot (New-FakeRepo)
    $config.versions[0].hostPort = 808
    $config.versions[0].revitClients = $true
    Assert-True (@(Test-PanelConfig -Config $config).Count -ge 1) 'hostPort 808 with revitClients on the same version was accepted'

    # Nothing is published for a disabled version, so it clashes with nobody.
    $config = New-DefaultConfig -RepoRoot (New-FakeRepo)
    $config.versions[0].hostPort = 808
    $config.versions[0].enabled = $false
    $config.versions[1].revitClients = $true
    Assert-Equal 0 @(Test-PanelConfig -Config $config).Count
    $config.versions[0].enabled = $true
    $config.versions[0].hostPort = 2022
    $config.versions[0].revitClients = $true
    $config.versions[0].enabled = $false
    Assert-Equal 0 @(Test-PanelConfig -Config $config).Count   # a disabled version with revitClients does not block another one
    $config.versions[0].enabled = $true
    Assert-True (@(Test-PanelConfig -Config $config).Count -ge 1) 'two enabled port 808 owners were accepted'

    # The proxy port.
    $config = New-DefaultConfig -RepoRoot (New-FakeRepo)
    $config.proxy.port = 808
    Assert-Equal 0 @(Test-PanelConfig -Config $config).Count
    $config.versions[1].revitClients = $true
    $errors = @(Test-PanelConfig -Config $config)
    Assert-True ($errors -contains (T 'cfg.port808Proxy' '2025')) "proxy port 808 next to a 808 owner was accepted: $($errors -join ' | ')"
    $config.proxy.enabled = $false
    Assert-Equal 0 @(Test-PanelConfig -Config $config).Count
}

Check 'config: an invalid saved file is reported and replaced by the defaults, a valid one is kept' {
    $repo = New-FakeRepo
    $path = Join-Path (New-TempDir) 'panel.config.json'
    $bad = @(
        '{"versions":[{"year":2022,"hostPort":"abc"}]}',
        '{"composeProject":"x&calc"}',
        '{"windowsContext":"a|b"}',
        '{"panelPort":0}',
        '{"versions":[{"year":"zz"}]}',
        '5',
        '[1]',
        'null',
        '{"panelPort": 8787,'
    )
    foreach ($text in $bad) {
        [System.IO.File]::WriteAllText($path, $text)
        Remove-Item -LiteralPath "$path.invalid.bak" -ErrorAction SilentlyContinue
        $config = Get-PanelConfig -RepoRoot $repo -ConfigPath $path -WarningVariable warned -WarningAction SilentlyContinue
        Assert-True (@($warned).Count -eq 2) "[$text] was not reported with its backup"
        # The next save overwrites the file: the hand edits must survive in the backup
        Assert-Equal $text ([System.IO.File]::ReadAllText("$path.invalid.bak"))
        Assert-Equal 2022 ((Get-VersionConfig -Config $config -Year 2022).hostPort)
        Assert-Equal 'samples' $config.composeProject
        # What the panel starts with must be usable: this is what used to throw.
        Update-GeneratedFiles -Config $config -RepoRoot $repo -ComposeDir (Join-Path (New-TempDir) 'compose') | Out-Null
    }

    [System.IO.File]::WriteAllText($path, '{"composeProject":"mine","versions":[{"year":2022,"hostPort":9000}]}')
    Remove-Item -LiteralPath "$path.invalid.bak" -ErrorAction SilentlyContinue
    $config = Get-PanelConfig -RepoRoot $repo -ConfigPath $path -WarningVariable warned -WarningAction SilentlyContinue
    Assert-Equal 0 @($warned).Count
    Assert-True (-not (Test-Path -LiteralPath "$path.invalid.bak")) 'a valid file was backed up'
    Assert-Equal 'mine' $config.composeProject
    Assert-Equal 9000 ((Get-VersionConfig -Config $config -Year 2022).hostPort)
}

Check 'config: a backup that cannot be written is a warning, the defaults are still used' {
    $repo = New-FakeRepo
    $path = Join-Path (New-TempDir) 'panel.config.json'
    [System.IO.File]::WriteAllText($path, '{"panelPort": 8787,')
    [System.IO.File]::WriteAllText("$path.invalid.bak", 'old')
    $lock = [System.IO.File]::Open("$path.invalid.bak", 'Open', 'ReadWrite', 'None')
    try {
        $config = Get-PanelConfig -RepoRoot $repo -ConfigPath $path -WarningVariable warned -WarningAction SilentlyContinue
    } finally { $lock.Dispose() }
    Assert-Equal 2 @($warned).Count
    Assert-True ("$($warned[1])" -match [regex]::Escape("$path.invalid.bak")) 'the failed backup was not reported'
    Assert-Equal 'samples' $config.composeProject
}

Check 'page and launcher: a persistent log error stops polling; Exit never leaves a launcher without icon' {
    $js = [System.IO.File]::ReadAllText((Join-Path $panelRoot 'www\app.js'), [System.Text.Encoding]::UTF8)
    Assert-True ($js -match 'logFailures >= 3\) \{\s+stopLogPolling\(\)') 'polling is not stopped after repeated errors'
    Assert-True ($js -match 'state\.logOffset = 0;\s+state\.logFailures = 0;') 'a new job does not reset the failure count'
    $cs = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'launcher\RevitServerStack.cs'), [System.Text.Encoding]::UTF8)
    Assert-True ($cs -match 'Win32Exception\) \{ \}.*\s+finally\s+\{[^}]*ExitThread\(\);') 'ExitThread is not in a finally after Kill'
}

Check 'token: 32 bytes from the cryptographic generator, compared in constant time' {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    for ($i = 0; $i -lt 200; $i++) {
        $token = New-SessionToken
        Assert-True ($token -cmatch '^[0-9a-f]{64}\z') "[$token] is not 32 bytes of hex"
        [void]$seen.Add($token)
    }
    Assert-Equal 200 $seen.Count

    $a = New-SessionToken
    Assert-True (Test-SecretEqual $a $a) 'equal tokens differ'
    Assert-True (-not (Test-SecretEqual $a (New-SessionToken))) 'different tokens are equal'
    Assert-True (-not (Test-SecretEqual $a $a.Substring(0, 63))) 'a prefix is equal'
    Assert-True (-not (Test-SecretEqual $a ($a + '0'))) 'a longer string is equal'
    Assert-True (-not (Test-SecretEqual $a '')) 'an empty string is equal'
    Assert-True (-not (Test-SecretEqual 'ab' 'AB')) 'the comparison ignores case'

    $server = [System.IO.File]::ReadAllText((Join-Path $panelRoot 'server.ps1'), [System.Text.Encoding]::UTF8)
    Assert-True ($server -notmatch 'Get-Random') 'server.ps1 draws something from Get-Random'
    Assert-True ($server -match '\$script:Token = New-SessionToken') 'the token is not made by New-SessionToken'
}

# Whether "docker compose config" can be used to read back what the panel wrote.
function Test-ComposeCli {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    & docker compose version 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

Check 'compose: a "$" in a path or a name is escaped, and the installer hash reaches the build' {
    $root = New-TempDir
    $repo = Join-Path $root 'repo$x'
    New-Item -ItemType Directory -Path (Join-Path $repo 'src\rs2022') -Force | Out-Null
    $composeDir = Join-Path $root 'compose'
    $config = New-DefaultConfig -RepoRoot $repo
    $config.windowsContext = 'rss-test-no-such-context'
    $config.versions[0].dataDir = 'D:\a$b\${x}\rs'

    Update-GeneratedFiles -Config $config -RepoRoot $repo -ComposeDir $composeDir | Out-Null
    $path = Join-Path $composeDir 'docker-compose.2022.yml'
    $yml = [System.IO.File]::ReadAllText($path)
    Assert-True ($yml.Contains('source: ''D:/a$$b/$${x}/rs''')) "the data folder is not escaped:`n$yml"
    Assert-True ($yml.Contains('repo$$x/src/rs2022''')) "the build context is not escaped:`n$yml"
    Assert-True ($yml.Contains('INSTALLER_SHA256: ''${RS2022_INSTALLER_SHA256:-}''')) "the installer hash is not handed to the build:`n$yml"

    if (-not (Test-ComposeCli)) {
        Write-Host '      the round trip through "docker compose config" was skipped: no docker compose'
        return
    }
    $saved = $env:RS2022_INSTALLER_SHA256
    $env:RS2022_INSTALLER_SHA256 = 'ABC123'
    try {
        $model = (& docker compose -p samples -f $path config --format json 2>&1) -join "`n" | ConvertFrom-Json
    } finally {
        if ($null -eq $saved) { Remove-Item Env:\RS2022_INSTALLER_SHA256 -ErrorAction SilentlyContinue } else { $env:RS2022_INSTALLER_SHA256 = $saved }
    }
    $service = $model.services.rs2022
    # config prints a literal $ as $$ again, so that its output can be fed back
    $source = ([string]$service.volumes[0].source).Replace('$$', '$').Replace('\', '/')
    Assert-Equal 'D:/a$b/${x}/rs' $source
    $context = ([string]$service.build.context).Replace('$$', '$').Replace('\', '/')
    Assert-True ($context.EndsWith('repo$x/src/rs2022')) "the build context is [$context]"
    Assert-Equal 'ABC123' ([string]$service.build.args.INSTALLER_SHA256)
}

Check 'dockerfiles: the installer is compared with INSTALLER_SHA256 when it is set' {
    $dockerfiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src') -Recurse -Filter 'Dockerfile')
    Assert-Equal 8 $dockerfiles.Count
    foreach ($file in $dockerfiles) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        $year = [regex]::Match($file.FullName, 'rs(\d{4})').Groups[1].Value
        $installer = [regex]::Match($text, '(?m)^ADD "[^"]+/([^/"]+\.sfx\.exe)"').Groups[1].Value
        Assert-True ($installer.Length -gt 0) "rs${year}: no installer in the ADD line"
        $check = [regex]::Match($text, '(?m)^RUN powershell -NoProfile -Command "[^"]*Get-FileHash ' + [regex]::Escape($installer) + ' -Algorithm SHA256\)\.Hash -ne \$env:INSTALLER_SHA256\)[^"]*"')
        Assert-True $check.Success "rs${year}: the installer is not checked"
        $arg = $text.IndexOf("`nARG INSTALLER_SHA256=")
        Assert-True ($arg -ge 0 -and $arg -lt $check.Index) "rs${year}: ARG INSTALLER_SHA256 does not come before the check"
        # The check and the use of the installer are one instruction: nothing is unpacked unchecked.
        $rest = $text.Substring($check.Index + 4)
        $next = [regex]::Match($rest, '(?m)^(RUN|WORKDIR|COPY|ADD|ENV|EXPOSE|ARG) ')
        $instruction = $check.Value
        if ($next.Success) { $instruction = $text.Substring($check.Index, 4 + $next.Index) }
        Assert-True ($instruction -match '(START /W|7zr\.exe x)') "rs${year}: the check and the use of the installer are in different layers"
        # The compose sample passes the variable of its version on.
        $sample = [System.IO.File]::ReadAllText((Join-Path $repoRoot "samples\docker-compose.$year.yml"), [System.Text.Encoding]::UTF8)
        Assert-True ($sample.Contains('INSTALLER_SHA256: ${RS' + $year + '_INSTALLER_SHA256:-}')) "samples/docker-compose.$year.yml does not pass the hash"
    }

    # Run the very command of a Dockerfile the way docker does (cmd /S /C), against a stand-in file.
    $text = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'src\rs2022\Dockerfile'), [System.Text.Encoding]::UTF8)
    $installer = [regex]::Match($text, '(?m)^ADD "[^"]+/([^/"]+\.sfx\.exe)"').Groups[1].Value
    $command = [regex]::Match($text, '(?m)^RUN (powershell -NoProfile -Command "[^"]*")').Groups[1].Value
    $work = New-TempDir
    [System.IO.File]::WriteAllText((Join-Path $work $installer), 'not an installer')
    $real = (Get-FileHash -LiteralPath (Join-Path $work $installer) -Algorithm SHA256).Hash
    $cases = @(
        @{ Hash = '';                      ExitCode = 0 },
        @{ Hash = $real;                   ExitCode = 0 },
        @{ Hash = $real.ToLowerInvariant(); ExitCode = 0 },
        @{ Hash = ('0' * 64);              ExitCode = 1 }
    )
    $savedHash = $env:INSTALLER_SHA256
    try {
        foreach ($case in $cases) {
            $env:INSTALLER_SHA256 = $case.Hash
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'cmd.exe'
            $psi.Arguments = '/S /C "' + $command + '"'
            $psi.WorkingDirectory = $work
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardOutput.ReadToEnd() | Out-Null
            $proc.StandardError.ReadToEnd() | Out-Null
            $proc.WaitForExit()
            Assert-Equal ([int]$case.ExitCode -ne 0) ($proc.ExitCode -ne 0)
        }
    } finally {
        if ($null -eq $savedHash) { Remove-Item Env:\INSTALLER_SHA256 -ErrorAction SilentlyContinue } else { $env:INSTALLER_SHA256 = $savedHash }
    }
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

# -------------------------------------------------------------------- jobs --

# Waits until the job is no longer among the running ones; returns its stored state.
function Wait-TestJob {
    param([string]$Id, [int]$Seconds = 30)
    for ($i = 0; $i -lt $Seconds * 5; $i++) {
        $running = @(Update-JobStates | Where-Object { $_.id -eq $Id })
        if ($running.Count -eq 0) { break }
        Start-Sleep -Milliseconds 200
    }
    return (Get-PanelJob -Id $Id)
}

Check 'jobs: ids are validated before they reach a path' {
    . (Join-Path $panelRoot 'lib\Jobs.ps1')
    foreach ($good in '0123456789ab', 'ffffffffffff') {
        Assert-True (Test-JobId $good) "[$good] was refused"
    }
    foreach ($bad in '', '..\..\x', '0123456789AB', "0123456789ab`n", '0123456789abc', '0123456789a', '01234567/9ab', 'zzzzzzzzzzzz') {
        Assert-True (-not (Test-JobId $bad)) "[$bad] was accepted as a job id"
    }

    # A .json file outside the jobs folder must not be read as a job, nor written back.
    $base = New-TempDir
    Initialize-JobStore -Directory (Join-Path $base 'jobs')
    $victim = Join-Path $base 'victim.json'
    $original = '{"id":"v","pid":0,"finishedAt":null}'
    [System.IO.File]::WriteAllText($victim, $original)
    Assert-True ($null -eq (Get-PanelJob -Id '..\victim')) 'a file outside the jobs folder was read as a job'
    Assert-True (-not (Stop-PanelJob -Id '..\victim')) 'a file outside the jobs folder was taken for a job to cancel'
    Assert-Equal $original ([System.IO.File]::ReadAllText($victim))
}

Check 'jobs: a command runs, its exit code and log are kept, and % reaches it unchanged' {
    . (Join-Path $panelRoot 'lib\Jobs.ps1')
    # The jobs folder itself has percent signs in its path: the wrapper must still start.
    $base = New-TempDir
    Initialize-JobStore -Directory (Join-Path $base 'x%TEMP%y\jobs')

    $ok = Start-PanelJob -Title 'echo' -Kind 'test' -Target 'rs1' -CommandLine 'echo a%TEMP%b'
    Assert-True (Test-JobId $ok.id) "[$($ok.id)] is not a job id"
    $done = Wait-TestJob $ok.id
    Assert-True ($null -ne $done.finishedAt) 'the job did not finish'
    Assert-Equal 'completed' ([string]$done.finishedReason)
    Assert-Equal 0 ([int]$done.exitCode)
    $log = (Get-JobLogChunk -Id $ok.id).text
    Assert-True ($log.Contains('a%TEMP%b')) "the percent signs were expanded: $log"
    Assert-True ($log.Contains('=== echo ===')) 'the header is missing from the log'

    $fail = Start-PanelJob -Title 'exit' -Kind 'test' -Target 'rs2' -CommandLine 'cmd /c exit 3'
    $done = Wait-TestJob $fail.id
    Assert-Equal 3 ([int]$done.exitCode)

    # Offsets: what was read is not sent again, and an offset past the end is clamped.
    $first = Get-JobLogChunk -Id $ok.id
    Assert-True ($first.offset -gt 0)
    $again = Get-JobLogChunk -Id $ok.id -Offset $first.offset
    Assert-Equal '' $again.text
    Assert-Equal $first.offset $again.offset
    $past = Get-JobLogChunk -Id $ok.id -Offset 999999
    Assert-Equal '' $past.text
    Assert-Equal $first.offset $past.offset
    Assert-Equal $first.text (Get-JobLogChunk -Id $ok.id -Offset -5).text
}

Check 'jobs: a running job keeps its target busy, and cancel stops the process' {
    . (Join-Path $panelRoot 'lib\Jobs.ps1')
    Initialize-JobStore -Directory (Join-Path (New-TempDir) 'jobs')

    $job = Start-PanelJob -Title 'ping' -Kind 'test' -Target 'rs3' -CommandLine 'ping -n 60 127.0.0.1'
    try {
        $busy = Get-RunningJobForTarget -Target 'rs3'
        Assert-True ($null -ne $busy -and $busy.id -eq $job.id) 'a running job was not found for its target'
        Assert-True ($null -eq (Get-RunningJobForTarget -Target 'rs4')) 'another target is busy'

        Assert-True (Stop-PanelJob -Id $job.id) 'a running job was not cancelled'
        $stored = Get-PanelJob -Id $job.id
        Assert-Equal 'cancelled' ([string]$stored.finishedReason)
        Assert-True ($null -eq (Get-Process -Id ([int]$job.pid) -ErrorAction SilentlyContinue)) 'the process of a cancelled job is still running'
        Assert-True ($null -eq (Get-RunningJobForTarget -Target 'rs3')) 'a cancelled job keeps its target busy'
        Assert-True (-not (Stop-PanelJob -Id $job.id)) 'a finished job was cancelled again'
    } finally {
        Stop-Process -Id ([int]$job.pid) -Force -ErrorAction SilentlyContinue
    }
}

Check 'jobs: a job that outlived the panel is "detached", and a recycled PID is not the job' {
    . (Join-Path $panelRoot 'lib\Jobs.ps1')
    Initialize-JobStore -Directory (Join-Path (New-TempDir) 'jobs')

    $job = Start-PanelJob -Title 'short' -Kind 'test' -Target 'rs5' -CommandLine 'ping -n 2 127.0.0.1'
    $script:ActiveProcesses.Clear()   # as after a restart of the panel: the handle is gone
    $done = Wait-TestJob $job.id
    Assert-Equal 'detached' ([string]$done.finishedReason)
    Assert-True ($null -eq $done.exitCode) 'an exit code was reported that nobody observed'

    $me = Get-Process -Id $PID
    $same = [pscustomobject]@{ pid = $PID; pidStartedAt = $me.StartTime.ToString('o') }
    $recycled = [pscustomobject]@{ pid = $PID; pidStartedAt = $me.StartTime.AddHours(-3).ToString('o') }
    Assert-True (Test-JobProcessAlive $same) 'the process of the job is not seen'
    Assert-True (-not (Test-JobProcessAlive $recycled)) 'a process that started later was taken for the job'
}

Check 'jobs: old finished jobs are removed with their files, unfinished ones stay' {
    . (Join-Path $panelRoot 'lib\Jobs.ps1')
    $dir = Join-Path (New-TempDir) 'jobs'
    Initialize-JobStore -Directory $dir
    $old = (Get-Date).AddDays(-30)
    foreach ($case in @(@{ Id = 'aaaaaaaaaaaa'; Finished = $true }, @{ Id = 'bbbbbbbbbbbb'; Finished = $false })) {
        $finished = $null
        if ($case.Finished) { $finished = $old.ToString('o') }
        Save-JobMeta ([pscustomobject]@{ id = $case.Id; target = 't'; finishedAt = $finished })
        foreach ($ext in 'json', 'log', 'cmd') {
            $file = Join-Path $dir "$($case.Id).$ext"
            if (-not (Test-Path -LiteralPath $file)) { [System.IO.File]::WriteAllText($file, 'x') }
            (Get-Item -LiteralPath $file).LastWriteTime = $old
        }
    }
    Remove-OldJobs
    foreach ($ext in 'json', 'log', 'cmd') {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $dir "aaaaaaaaaaaa.$ext"))) "an old finished job left its .$ext"
        Assert-True (Test-Path -LiteralPath (Join-Path $dir "bbbbbbbbbbbb.$ext")) "an unfinished job lost its .$ext"
    }
}

Check 'actions: Start all and Stop all say when a target failed' {
    . (Join-Path $panelRoot 'lib\Jobs.ps1')
    . (Join-Path $panelRoot 'lib\Actions.ps1')
    Initialize-JobStore -Directory (Join-Path (New-TempDir) 'jobs')
    # Takes the place of the real one: nothing is started.
    function Start-PanelJob {
        param($Title, $Kind, $Target, $CommandLine, $WorkingDirectory = '')
        return [pscustomobject]@{ id = 'test'; title = $Title }
    }

    Assert-True (Test-AllResultsOk @()) 'no results is not a success'
    Assert-True (Test-AllResultsOk @([pscustomobject]@{ target = 'a'; result = [pscustomobject]@{ ok = $true } })) 'a success was reported as a failure'
    Assert-True (-not (Test-AllResultsOk @(
        [pscustomobject]@{ target = 'a'; result = [pscustomobject]@{ ok = $true } },
        [pscustomobject]@{ target = 'b'; result = [pscustomobject]@{ ok = $false } }))) 'a failure among successes was lost'

    $repo = New-FakeRepo
    $composeDir = Join-Path (New-TempDir) 'compose'
    $config = New-DefaultConfig -RepoRoot $repo
    $config.windowsContext = 'rss-test-no-such-context'

    # No compose files yet: every target fails.
    $results = @(Invoke-StopAll -Config $config -ComposeDir $composeDir)
    Assert-Equal 3 $results.Count
    Assert-True (-not (Test-AllResultsOk $results)) 'Stop all with nothing to stop reported success'
    Assert-Equal 0 @($results | Where-Object { $_.result.ok }).Count

    Update-GeneratedFiles -Config $config -RepoRoot $repo -ComposeDir $composeDir | Out-Null
    Assert-True (Test-AllResultsOk (Invoke-StopAll -Config $config -ComposeDir $composeDir)) 'Stop all failed although every target could be stopped'
    Assert-True (Test-AllResultsOk (Invoke-StartAll -Config $config -ComposeDir $composeDir -RepoRoot $repo)) 'Start all failed although every target could be started'

    # One target without a compose file: the rest still goes, and the whole is not "ok".
    Remove-Item -LiteralPath (Join-Path $composeDir 'docker-compose.2025.yml')
    $results = @(Invoke-StartAll -Config $config -ComposeDir $composeDir -RepoRoot $repo)
    Assert-Equal 3 $results.Count
    Assert-True (-not (Test-AllResultsOk $results)) 'a failed target did not fail Start all'
    Assert-Equal 2 @($results | Where-Object { $_.result.ok }).Count
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
        # The list of contexts is a list even with one context in it (docker has "default" only here).
        Assert-True (($config.Body | ConvertFrom-Json).contexts -is [array]) 'the contexts were sent as one string, not as a list'

        # The same refusal comes back in the language of the page (the name is
        # checked before docker is called, so no docker is needed here).
        $badName = '{"name":"x y","endpoint":"ssh://srv"}'
        foreach ($code in @('en', 'ru', 'de', 'ja')) {
            $answer = Send-TestRequest -Url "$base/api/context" -Method POST -Headers @{ 'X-Panel-Token' = $token; 'X-Panel-Lang' = $code } -Body $badName
            Assert-Equal 400 $answer.Status
            $expected = (Read-Catalog $code)['ctx.badName']
            Assert-Equal $expected (($answer.Body | ConvertFrom-Json).error)
        }
        $noHeader = Send-TestRequest -Url "$base/api/context" -Method POST -Headers @{ 'X-Panel-Token' = $token } -Body $badName
        Assert-Equal (Read-Catalog 'en')['ctx.badName'] (($noHeader.Body | ConvertFrom-Json).error)
        $unknown = Send-TestRequest -Url "$base/api/context" -Method POST -Headers @{ 'X-Panel-Token' = $token; 'X-Panel-Lang' = '../../x' } -Body $badName
        Assert-Equal (Read-Catalog 'en')['ctx.badName'] (($unknown.Body | ConvertFrom-Json).error)

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

Check 'server: settings are merged and checked, bad bodies and paths are refused' {
    $copy = New-FakeRepo -Years @(2022)
    Copy-Item -LiteralPath $panelRoot -Destination (Join-Path $copy 'panel') -Recurse
    $runtimeCopy = Join-Path $copy 'panel\runtime'
    if (Test-Path -LiteralPath $runtimeCopy) { Remove-Item -LiteralPath $runtimeCopy -Recurse -Force }
    # A hand-edited file with a bad value: the panel has to start anyway, with the defaults.
    New-Item -ItemType Directory -Path $runtimeCopy -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $runtimeCopy 'panel.config.json'), '{"versions":[{"year":2022,"hostPort":"abc"}]}')

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
            if ($proc.HasExited) { throw 'the server exited during start-up (an invalid saved config must not stop it)' }
            try { $index = Send-TestRequest -Url "$base/" } catch { }
        }
        Assert-True ($null -ne $index) 'the server did not answer within 20 seconds'
        Assert-True ($index.Body -match 'name="panel-token" content="([0-9a-f]{64})"') 'the token is not in the page'
        $auth = @{ 'X-Panel-Token' = $Matches[1] }
        $english = Read-Catalog 'en'

        function Get-TestConfig { return ((Send-TestRequest -Url "$base/api/config" -Headers $auth).Body | ConvertFrom-Json).config }
        function Save-TestConfig { param([string]$Body) return (Send-TestRequest -Url "$base/api/config" -Method POST -Headers $auth -Body $Body) }

        # Start-up: the bad value was not used.
        Assert-Equal 2022 (Get-TestConfig).versions[0].hostPort

        # A body that is not an object changes nothing.
        foreach ($body in '5', '"text"', '[1]', 'true') {
            $answer = Save-TestConfig $body
            Assert-Equal 400 $answer.Status
            Assert-Equal $english['srv.notObject'] (($answer.Body | ConvertFrom-Json).error)
        }
        Assert-Equal 2022 (Get-TestConfig).versions[0].hostPort

        # A partial body changes what it names and nothing else.
        Assert-Equal 200 (Save-TestConfig '{"windowsContext":"my-ctx"}').Status
        Assert-Equal 'my-ctx' (Get-TestConfig).windowsContext
        Assert-Equal 200 (Save-TestConfig '{"composeProject":"zz"}').Status
        $now = Get-TestConfig
        Assert-Equal 'my-ctx' $now.windowsContext
        Assert-Equal 'zz' $now.composeProject
        Assert-Equal 200 (Save-TestConfig '{"versions":[{"year":2022,"hostPort":9123}]}').Status
        $now = Get-TestConfig
        Assert-Equal 9123 $now.versions[0].hostPort
        Assert-Equal 'zz' $now.composeProject
        Assert-Equal 'my-ctx' $now.windowsContext
        $saved = [System.IO.File]::ReadAllText((Join-Path $runtimeCopy 'panel.config.json')) | ConvertFrom-Json
        Assert-Equal 'zz' $saved.composeProject
        Assert-Equal 9123 $saved.versions[0].hostPort

        # The checks of a save: refused with the list of errors, nothing changes.
        $refused = Save-TestConfig '{"panelPort":0}'
        Assert-Equal 400 $refused.Status
        Assert-True (@(($refused.Body | ConvertFrom-Json).errors) -contains $english['cfg.panelPort']) 'the port error is missing'
        $refused = Save-TestConfig '{"versions":[{"year":2022,"hostPort":808,"revitClients":true}]}'
        Assert-Equal 400 $refused.Status
        $refused = Save-TestConfig '{"versions":[{"year":"zz"}]}'
        Assert-Equal 400 $refused.Status
        Assert-True (@(($refused.Body | ConvertFrom-Json).errors).Count -ge 1) 'a value of the wrong type gave no error'
        Assert-Equal 9123 (Get-TestConfig).versions[0].hostPort

        # A "$" in the folder reaches the compose file escaped.
        Assert-Equal 200 (Save-TestConfig '{"versions":[{"year":2022,"dataDir":"D:\\a$b\\rs"}]}').Status
        $yml = [System.IO.File]::ReadAllText((Join-Path $runtimeCopy 'compose\docker-compose.2022.yml'))
        Assert-True ($yml.Contains('D:/a$$b/rs')) 'the "$" of the folder was not escaped in the compose file'

        # Malformed JSON is said to be malformed, wherever a body is read.
        foreach ($path in '/api/config', '/api/action', '/api/job/cancel', '/api/context') {
            $answer = Send-TestRequest -Url "$base$path" -Method POST -Headers $auth -Body '{bad'
            Assert-Equal 400 $answer.Status
            Assert-Equal $english['srv.badJson'] (($answer.Body | ConvertFrom-Json).error)
        }

        # Paths with ":" are "not found", not a server error with the text of an exception.
        foreach ($path in '/C:/Windows/win.ini', '/index.html::$DATA', '/i18n/en.json:x') {
            $answer = Send-TestRequest -Url ($base + $path)
            Assert-Equal 404 $answer.Status
            Assert-True ($answer.Body -notmatch 'GetFullPath|Exception') "the answer for $path leaks an exception: $($answer.Body)"
        }
        Assert-True ((Send-TestRequest -Url "$base/C%3A/Windows/win.ini").Status -ne 500) 'an encoded ":" gave a server error'
        Assert-Equal 200 (Send-TestRequest -Url "$base/app.js").Status

        # Cancel and log take the same kind of id.
        $answer = Send-TestRequest -Url "$base/api/job/cancel" -Method POST -Headers $auth -Body '{"id":"..\\..\\..\\x"}'
        Assert-Equal 400 $answer.Status
        Assert-Equal $english['srv.badJobId'] (($answer.Body | ConvertFrom-Json).error)
        Assert-Equal 400 (Send-TestRequest -Url "$base/api/job/cancel" -Method POST -Headers $auth -Body '{"id":"0123456789AB"}').Status
        Assert-Equal 400 (Send-TestRequest -Url "$base/api/job?id=0123456789AB" -Headers $auth).Status
        $answer = Send-TestRequest -Url "$base/api/job/cancel" -Method POST -Headers $auth -Body '{"id":"0123456789ab"}'
        Assert-Equal 200 $answer.Status
        Assert-Equal $false (($answer.Body | ConvertFrom-Json).ok)

        Assert-Equal 200 (Send-TestRequest -Url "$base/api/shutdown" -Method POST -Headers $auth).Status
        Assert-True ($proc.WaitForExit(10000)) 'the server did not stop after /api/shutdown'
    } finally {
        if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
        if ($null -eq $savedDockerConfig) { Remove-Item Env:\DOCKER_CONFIG -ErrorAction SilentlyContinue } else { $env:DOCKER_CONFIG = $savedDockerConfig }
    }
}

# --------------------------------------------------------------------- i18n --

$languageCodes = @((([System.IO.File]::ReadAllText((Join-Path $panelRoot 'www\i18n\index.json'), [System.Text.Encoding]::UTF8)) | ConvertFrom-Json) | ForEach-Object { [string]$_.code })

Check 'i18n: every language has the keys, placeholders and markup of English' {
    Assert-True ($languageCodes -contains 'en' -and $languageCodes -contains 'ru') 'English and Russian must be listed'
    $english = Read-Catalog 'en'
    foreach ($code in $languageCodes) {
        $catalog = Read-Catalog $code
        $missing = @($english.Keys | Where-Object { -not $catalog.Contains($_) })
        $extra = @($catalog.Keys | Where-Object { -not $english.Contains($_) })
        Assert-True ($missing.Count -eq 0) "$code lacks: $($missing -join ', ')"
        Assert-True ($extra.Count -eq 0) "$code has keys English does not: $($extra -join ', ')"
        foreach ($key in $english.Keys) {
            $value = $catalog[$key]
            Assert-True (-not [string]::IsNullOrWhiteSpace($value)) "$code/$key is empty"
            Assert-Equal (Get-Placeholders $english[$key]) (Get-Placeholders $value)
            Assert-Equal (Get-Markup $english[$key]) (Get-Markup $value)
            # String.Format and the page both read {0}; any other brace would break them.
            Assert-True (($value -replace '\{\d+\}', '') -notmatch '[{}]') "$code/$key has a stray brace"
        }
    }
}

Check 'i18n: no text of the code is left outside the catalogs' {
    $cyrillic = '[\u0400-\u04FF]'
    $files = @(Get-ChildItem -LiteralPath (Join-Path $panelRoot 'lib') -Filter '*.ps1' -File) +
        @(Get-Item -LiteralPath (Join-Path $panelRoot 'server.ps1')) +
        @(Get-Item -LiteralPath (Join-Path $panelRoot 'www\app.js')) +
        @(Get-Item -LiteralPath (Join-Path $panelRoot 'www\index.html')) +
        @(Get-Item -LiteralPath (Join-Path $repoRoot 'launcher\Build.ps1'))
    foreach ($file in $files) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        Assert-True ($text -notmatch $cyrillic) "$($file.Name) has Russian text, it belongs in panel\www\i18n\ru.json"
    }
    foreach ($code in $languageCodes | Where-Object { $_ -ne 'ru' }) {
        $text = [System.IO.File]::ReadAllText((Join-Path $panelRoot "www\i18n\$code.json"), [System.Text.Encoding]::UTF8)
        Assert-True ($text -notmatch $cyrillic) "$code.json has Russian text"
    }
}

Check 'i18n: every key the code asks for exists, and every key is used' {
    $english = Read-Catalog 'en'
    $used = New-Object 'System.Collections.Generic.HashSet[string]'
    $sources = @(Get-ChildItem -LiteralPath (Join-Path $panelRoot 'lib') -Filter '*.ps1' -File) + @(Get-Item -LiteralPath (Join-Path $panelRoot 'server.ps1'))
    foreach ($file in $sources) {
        $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        foreach ($m in [regex]::Matches($text, "\bT '([A-Za-z0-9.]+)'")) { [void]$used.Add($m.Groups[1].Value) }
        foreach ($m in [regex]::Matches($text, "\bLabel = '([A-Za-z0-9.]+)'")) { [void]$used.Add($m.Groups[1].Value) }
    }
    $js = [System.IO.File]::ReadAllText((Join-Path $panelRoot 'www\app.js'), [System.Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($js, "\bt\('([A-Za-z0-9.]+)'")) { [void]$used.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($js, "key = '([A-Za-z0-9.]+)'")) { [void]$used.Add($m.Groups[1].Value) }
    $html = [System.IO.File]::ReadAllText((Join-Path $panelRoot 'www\index.html'), [System.Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($html, 'data-i18n(?:-html|-title|-placeholder|-aria-label)?="([A-Za-z0-9.]+)"')) { [void]$used.Add($m.Groups[1].Value) }

    $missing = @($used | Where-Object { -not $english.Contains($_) })
    Assert-True ($missing.Count -eq 0) "keys used but not in English: $($missing -join ', ')"
    # Built from a variable at run time: job.<action>, state.<state>.
    $built = @('job.up', 'job.build', 'job.stop', 'job.restart', 'job.down', 'state.running', 'state.starting', 'state.stopped', 'state.absent', 'state.error', 'state.unknown')
    $unused = @($english.Keys | Where-Object { -not $used.Contains($_) -and $built -notcontains $_ })
    Assert-True ($unused.Count -eq 0) "keys nobody uses: $($unused -join ', ')"
}

Check 'i18n: the languages Windows may ask for map to a catalog' {
    $cases = @{ 'ru-RU' = 'ru'; 'RU' = 'ru'; 'en-GB' = 'en'; 'zh' = 'zh-CN'; 'zh-TW' = 'zh-CN'; 'pt-PT' = 'pt-BR'; 'de-AT' = 'de'; 'ja-JP' = 'ja'; 'xx' = 'en'; '' = 'en'; '../x' = 'en' }
    foreach ($name in $cases.Keys) { Assert-Equal $cases[$name] (Resolve-Language $name) }
}

Check 'i18n: T answers in the language asked for, and falls back to English' {
    $saved = $script:Language
    try {
        $script:Language = 'en'
        Assert-Equal 'Port 1 is used by two versions at once (2 and 3).' (T 'cfg.dupPort' 1 2 3)
        $script:Language = 'ru'
        Assert-True ((T 'cfg.dupPort' 1 2 3) -match '[\u0400-\u04FF]') 'the Russian text is not Russian'
        Assert-True ((T 'cfg.dupPort' 1 2 3) -match '1.*2.*3') 'the arguments were not filled in'
        Assert-Equal 'no.such.key' (T 'no.such.key')
    } finally { $script:Language = $saved }
}

Check 'i18n: the tray launcher has every text in all eight languages' {
    $source = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'launcher\RevitServerStack.cs'), [System.Text.Encoding]::UTF8)
    $table = [regex]::Match($source, '(?s)Dictionary<string, string\[\]> Texts.*?\n        \};')
    Assert-True $table.Success 'the text table of the launcher was not found'
    $entries = [regex]::Matches($table.Value, '(?s)\{ "(\w+)", new\[\] \{(.*?)\} \},')
    Assert-True ($entries.Count -ge 11) "only $($entries.Count) entries found"
    foreach ($entry in $entries) {
        $literals = @([regex]::Matches($entry.Groups[2].Value, '"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value })
        Assert-Equal 8 $literals.Count
        $first = Get-Placeholders $literals[0]
        foreach ($literal in $literals) { Assert-Equal $first (Get-Placeholders $literal) }
    }
}

# ------------------------------------------------------------------ launcher --

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

Check 'launcher: the address of a panel that died is not left behind' {
    $outDir = New-TempDir
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $buildScript -OutDir $outDir | Out-Null
    Assert-Equal 0 $LASTEXITCODE
    $exe = Join-Path $outDir 'RevitServerStack.exe'

    $copy = New-FakeRepo -Years @(2022)
    Copy-Item -LiteralPath $panelRoot -Destination (Join-Path $copy 'panel') -Recurse
    $runtimeCopy = Join-Path $copy 'panel\runtime'
    if (Test-Path -LiteralPath $runtimeCopy) { Remove-Item -LiteralPath $runtimeCopy -Recurse -Force }
    Copy-Item -LiteralPath $exe -Destination $copy

    $launcher = Start-Process -FilePath (Join-Path $copy 'RevitServerStack.exe') -ArgumentList '--no-browser' -PassThru
    $serverId = 0
    try {
        $urlFile = Join-Path $copy 'panel\runtime\panel.url'
        $found = $false
        for ($i = 0; $i -lt 40 -and -not $found; $i++) {
            Start-Sleep -Milliseconds 500
            if ($launcher.HasExited) { throw 'the launcher exited during start-up' }
            $found = Test-Path -LiteralPath $urlFile
        }
        Assert-True $found 'the panel address did not appear within 20 seconds'
        $server = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($launcher.Id)" | Where-Object { $_.Name -eq 'powershell.exe' })
        Assert-Equal 1 $server.Count
        $serverId = $server[0].ProcessId

        # The panel is killed, so its own clean-up cannot run: the launcher has to remove the file.
        Stop-Process -Id $serverId -Force
        $gone = $false
        for ($i = 0; $i -lt 20 -and -not $gone; $i++) {
            Start-Sleep -Milliseconds 500
            $gone = -not (Test-Path -LiteralPath $urlFile)
        }
        Assert-True $gone 'the address of a dead panel was left in panel.url'
        Assert-True (-not $launcher.HasExited) 'the launcher itself went away (its icon must stay to restart the panel)'
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
    foreach ($mustNot in '^[^/]+/panel/runtime/', '^[^/]+/samples/rs20\d\d/', '^[^/]+/launcher/', '^[^/]+/panel/tests/', '^[^/]+/docs/(?!images/)', '^[^/]+/\.github/', '^[^/]+/\.config/', '^[^/]+/docfx\.json$', '^[^/]+/_site/', '\\') {
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
