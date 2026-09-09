# Background job runner for the docker commands the panel issues.
#
# Building a Revit Server image downloads ~5 GB and takes 20-45 minutes, so no
# docker command may run inside the HTTP handler. Each job is written out as a
# small .cmd wrapper and started detached; stdout and stderr are merged into one
# log file by the wrapper (Start-Process cannot redirect both to one file), and
# the UI tails that log.
#
# Job metadata is persisted, so a panel restart during a long build does not
# lose track of it: the recorded PID plus its start time identify the process.

Set-StrictMode -Version 1.0

$script:JobsDir = ''
$script:ActiveProcesses = @{}

function Initialize-JobStore {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $script:JobsDir = $Directory
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
}

function Get-JobMetaPath {
    param([string]$Id)
    return (Join-Path $script:JobsDir "$Id.json")
}

function Get-JobLogPath {
    param([string]$Id)
    return (Join-Path $script:JobsDir "$Id.log")
}

function Save-JobMeta {
    param($Job)
    Write-TextFileUtf8 -Path (Get-JobMetaPath $Job.id) -Content ($Job | ConvertTo-Json -Depth 6)
}

function Get-PanelJob {
    param([Parameter(Mandatory = $true)][string]$Id)

    $path = Get-JobMetaPath $Id
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw = Read-TextFileUtf8 $path
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Get-PanelJobs {
    param([int]$Limit = 30)

    $jobs = @()
    if (-not (Test-Path -LiteralPath $script:JobsDir)) { return $jobs }

    Get-ChildItem -LiteralPath $script:JobsDir -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $Limit |
        ForEach-Object {
            $raw = Read-TextFileUtf8 $_.FullName
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                try { $jobs += ($raw | ConvertFrom-Json) } catch { }
            }
        }
    return $jobs
}

function Test-JobProcessAlive {
    param($Job)

    if (-not $Job.pid) { return $false }
    $proc = Get-Process -Id ([int]$Job.pid) -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }

    # Guard against PID reuse: a recycled PID belongs to a process that started
    # later than the one we launched.
    if ($Job.pidStartedAt) {
        try {
            $recorded = [datetime]::Parse([string]$Job.pidStartedAt)
            if ([math]::Abs(($proc.StartTime - $recorded).TotalSeconds) -gt 2) { return $false }
        } catch { }
    }
    return $true
}

<#
.SYNOPSIS
    Refreshes the state of every unfinished job and returns the running ones.
#>
function Update-JobStates {
    $running = @()
    foreach ($job in (Get-PanelJobs -Limit 60)) {
        if ($job.finishedAt) { continue }

        $isAlive = $false
        $exitCode = $null
        $reason = 'completed'

        if ($script:ActiveProcesses.ContainsKey($job.id)) {
            $proc = $script:ActiveProcesses[$job.id]
            try {
                if ($proc.HasExited) {
                    $exitCode = $proc.ExitCode
                    $script:ActiveProcesses.Remove($job.id)
                } else {
                    $isAlive = $true
                }
            } catch {
                $script:ActiveProcesses.Remove($job.id)
                $isAlive = Test-JobProcessAlive $job
                $reason = 'unknown'
            }
        } else {
            $isAlive = Test-JobProcessAlive $job
            if (-not $isAlive) {
                # The panel was restarted while this job ran: the process is gone
                # but its exit code died with the handle. Never report success we
                # did not observe - say so and let the log speak.
                $reason = 'detached'
            }
        }

        if ($isAlive) {
            $running += $job
            continue
        }

        $job.exitCode = $exitCode
        $job.finishedAt = (Get-Date).ToString('o')
        $job.finishedReason = $reason
        Save-JobMeta $job
    }
    return $running
}

function Get-RunningJobForTarget {
    param([string]$Target)

    foreach ($job in (Update-JobStates)) {
        if ([string]$job.target -eq $Target) { return $job }
    }
    return $null
}

<#
.SYNOPSIS
    Starts a command line as a tracked background job.
.PARAMETER CommandLine
    Full command line, already quoted, executed by cmd.exe.
#>
function Start-PanelJob {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [string]$WorkingDirectory = ''
    )

    $id = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $logPath = Get-JobLogPath $id
    $cmdPath = Join-Path $script:JobsDir "$id.cmd"

    $header = @(
        "=== $Title ===",
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $CommandLine",
        ''
    ) -join "`r`n"
    Write-TextFileUtf8 -Path $logPath -Content $header -WithCrLf

    $wrapper = @(
        '@echo off',
        'chcp 65001 >nul',
        "$CommandLine >> $(ConvertTo-CliArg $logPath) 2>&1",
        'exit /b %ERRORLEVEL%'
    ) -join "`r`n"
    Write-TextFileUtf8 -Path $cmdPath -Content $wrapper -WithCrLf

    # Deliberately not Start-Process: the Process object it hands back does not
    # keep the handle, so ExitCode reads as $null once the job finishes and the
    # panel could never tell success from failure. Owning the Process fixes that.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = "/c $(ConvertTo-CliArg $cmdPath)"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null

    $job = [pscustomobject]@{
        id             = $id
        kind           = $Kind
        target         = $Target
        title          = $Title
        commandLine    = $CommandLine
        startedAt      = (Get-Date).ToString('o')
        startedAtText  = (Get-Date).ToString('HH:mm:ss')
        pid            = $proc.Id
        pidStartedAt   = $null
        logFile        = $logPath
        cmdFile        = $cmdPath
        exitCode       = $null
        finishedAt     = $null
        finishedReason = $null
    }
    try { $job.pidStartedAt = $proc.StartTime.ToString('o') } catch { }

    $script:ActiveProcesses[$id] = $proc
    Save-JobMeta $job
    return $job
}

function Stop-PanelJob {
    param([Parameter(Mandatory = $true)][string]$Id)

    $job = Get-PanelJob -Id $Id
    if (-not $job) { return $false }
    if ($job.finishedAt) { return $false }
    if (-not (Test-JobProcessAlive $job)) { return $false }

    # /T kills the docker child too - killing only cmd.exe would orphan it.
    Invoke-Cli -FilePath 'taskkill.exe' -Arguments @('/PID', [string]$job.pid, '/T', '/F') -TimeoutSec 15 | Out-Null

    $job.finishedAt = (Get-Date).ToString('o')
    $job.finishedReason = 'cancelled'
    Save-JobMeta $job
    if ($script:ActiveProcesses.ContainsKey($Id)) { $script:ActiveProcesses.Remove($Id) }
    return $true
}

<#
.SYNOPSIS
    Returns the part of a job log after $Offset characters.
#>
function Get-JobLogChunk {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [int]$Offset = 0
    )

    $text = Read-TextFileUtf8 (Get-JobLogPath $Id)
    if ($Offset -lt 0) { $Offset = 0 }
    if ($Offset -gt $text.Length) { $Offset = $text.Length }

    return [pscustomobject]@{
        text   = $text.Substring($Offset)
        offset = $text.Length
    }
}

function Remove-OldJobs {
    param([int]$KeepDays = 7, [int]$KeepCount = 40)

    if (-not (Test-Path -LiteralPath $script:JobsDir)) { return }

    $metas = Get-ChildItem -LiteralPath $script:JobsDir -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    $cutoff = (Get-Date).AddDays(-$KeepDays)

    $index = 0
    foreach ($meta in $metas) {
        $index++
        if ($index -le $KeepCount -and $meta.LastWriteTime -ge $cutoff) { continue }

        $id = [System.IO.Path]::GetFileNameWithoutExtension($meta.Name)
        $job = Get-PanelJob -Id $id
        if ($job -and -not $job.finishedAt) { continue }

        Remove-Item -LiteralPath $meta.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Get-JobLogPath $id) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $script:JobsDir "$id.cmd") -Force -ErrorAction SilentlyContinue
    }
}
