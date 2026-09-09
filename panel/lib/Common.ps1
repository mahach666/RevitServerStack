# Common helpers shared by the control panel modules.
# PowerShell 5.1 compatible - no ternary, no null-coalescing, no ?. operators.

Set-StrictMode -Version 1.0

# Quote a single argument for a Windows command line.
# Start-Process -ArgumentList joins items with spaces without quoting them,
# so anything containing a space has to be quoted here or it becomes two args.
function ConvertTo-CliArg {
    param([string]$Value)

    if ($null -eq $Value) { return '""' }
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    # Escape backslashes that precede a quote, then the quote itself.
    $escaped = $Value -replace '(\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function ConvertTo-CliArgLine {
    param([string[]]$Arguments)

    if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return '' }
    $parts = @()
    foreach ($a in $Arguments) { $parts += (ConvertTo-CliArg $a) }
    return ($parts -join ' ')
}

function Read-TextFileUtf8 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
            return $reader.ReadToEnd()
        } finally { $stream.Dispose() }
    } catch {
        return ''
    }
}

function Write-TextFileUtf8 {
    param([string]$Path, [string]$Content, [switch]$WithCrLf)

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $text = $Content
    if ($WithCrLf) {
        $text = ($Content -replace "`r`n", "`n") -replace "`n", "`r`n"
    }
    # UTF8 without BOM: cmd.exe and docker both choke on a BOM in some cases.
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $text, $enc)
}

<#
.SYNOPSIS
    Runs an executable, captures stdout/stderr, and enforces a hard timeout.
.DESCRIPTION
    Docker CLI calls block for a long time when the engine is unreachable
    (named-pipe connect retries). The panel's HTTP loop is single threaded,
    so every docker call must be bounded or the whole UI freezes.
#>
function Invoke-Cli {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 20
    )

    $result = [pscustomobject]@{
        ExitCode = -1
        StdOut   = ''
        StdErr   = ''
        TimedOut = $false
        Launched = $false
    }

    # Deliberately not Start-Process: with both streams redirected it returns a
    # Process object whose ExitCode reads back as $null, which would make every
    # successful docker call look like a failure. Owning the Process gives a
    # reliable exit code.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (ConvertTo-CliArgLine $Arguments)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    try {
        try {
            $proc.Start() | Out-Null
            $result.Launched = $true
        } catch {
            $result.StdErr = $_.Exception.Message
            return $result
        }

        # Read both pipes asynchronously: reading one to the end before the
        # other deadlocks as soon as the child fills the second pipe's buffer.
        $stdOutTask = $proc.StandardOutput.ReadToEndAsync()
        $stdErrTask = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            $result.TimedOut = $true
            try { $proc.Kill() } catch { }
            try { $proc.WaitForExit(3000) | Out-Null } catch { }
        } else {
            $result.ExitCode = $proc.ExitCode
        }

        try { if ($stdOutTask.Wait(3000)) { $result.StdOut = $stdOutTask.Result } } catch { }
        try { if ($stdErrTask.Wait(3000)) { $result.StdErr = $stdErrTask.Result } } catch { }
        return $result
    } finally {
        try { $proc.Dispose() } catch { }
    }
}

# Probes an HTTP endpoint. Used to tell "container is up" apart from "IIS
# inside the container has finished starting".
#
# Start and Complete are split so several endpoints can be probed at once: the
# panel's HTTP loop is single threaded, and probing six versions one after
# another would block it for the sum of the timeouts instead of the longest one.
#
# GET, not HEAD: this is the request a browser makes, so it measures what the
# user will actually experience.
function Start-HttpProbe {
    param([string]$Url, [int]$TimeoutMs = 6000)

    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.AllowAutoRedirect = $true
        $request.UserAgent = 'revit-server-panel'
        $async = $request.BeginGetResponse($null, $null)
        return [pscustomobject]@{ Url = $Url; Request = $request; Async = $async; Error = '' }
    } catch {
        return [pscustomobject]@{ Url = $Url; Request = $null; Async = $null; Error = $_.Exception.Message }
    }
}

function Complete-HttpProbe {
    param($Probe, [int]$TimeoutMs = 6000)

    if (-not $Probe -or -not $Probe.Async) {
        return [pscustomobject]@{ Reachable = $false; StatusCode = 0 }
    }
    if ($TimeoutMs -lt 0) { $TimeoutMs = 0 }

    try {
        if (-not $Probe.Async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            try { $Probe.Request.Abort() } catch { }
            return [pscustomobject]@{ Reachable = $false; StatusCode = 0 }
        }
        $response = $Probe.Request.EndGetResponse($Probe.Async)
        try {
            # Headers are enough; closing without draining skips the body.
            return [pscustomobject]@{ Reachable = $true; StatusCode = [int]$response.StatusCode }
        } finally { $response.Close() }
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if ($resp) {
            # 401/403/404 still prove the web server answered.
            return [pscustomobject]@{ Reachable = $true; StatusCode = [int]$resp.StatusCode }
        }
        return [pscustomobject]@{ Reachable = $false; StatusCode = 0 }
    } catch {
        return [pscustomobject]@{ Reachable = $false; StatusCode = 0 }
    }
}

function Test-HttpEndpoint {
    param([string]$Url, [int]$TimeoutMs = 6000)

    $probe = Start-HttpProbe -Url $Url -TimeoutMs $TimeoutMs
    return (Complete-HttpProbe -Probe $probe -TimeoutMs $TimeoutMs)
}

function Get-UnixMillis {
    param([datetime]$Value = (Get-Date))
    $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01', [System.DateTimeKind]::Utc)
    return [long]([math]::Round(($Value.ToUniversalTime() - $epoch).TotalMilliseconds))
}
