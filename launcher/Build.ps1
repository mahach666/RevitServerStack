<#
.SYNOPSIS
    Builds RevitServerStack.exe, and with -Release the zip archive for GitHub.
.DESCRIPTION
    powershell -NoProfile -ExecutionPolicy Bypass -File launcher\Build.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File launcher\Build.ps1 -Release

    Needs nothing but Windows: the C# compiler of .NET Framework 4 is part of it.
    The version is read from the newest entry of CHANGELOG.md. With -Release
    the archive holds the exe next to the files git would commit (tracked and
    new, minus ignored), without the launcher sources and the tests.
.PARAMETER OutDir
    Output folder, dist\ in the repository by default.
.PARAMETER Release
    Also writes RevitServerStack-<version>.zip, its .sha256 and RELEASE_NOTES.md.
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [switch]$Release
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$launcherDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $launcherDir
if (-not $OutDir) { $OutDir = Join-Path $repo 'dist' }

# ------------------------------------------------------------------ version --

$changelog = Get-Content -LiteralPath (Join-Path $repo 'CHANGELOG.md') -Raw -Encoding UTF8
$match = [regex]::Match($changelog, '(?m)^## \[(\d+\.\d+\.\d+)\]')
if (-not $match.Success) { throw 'CHANGELOG.md has no "## [x.y.z]" entry to take the version from.' }
$version = $match.Groups[1].Value

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('rss-build-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null

try {
    # ---------------------------------------------------------------- icon --

    Add-Type -AssemblyName System.Drawing

    function New-RoundedRect([single]$Size, [single]$Radius) {
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = $Radius * 2
        $path.AddArc(0, 0, $d, $d, 180, 90)
        $path.AddArc($Size - $d, 0, $d, $d, 270, 90)
        $path.AddArc($Size - $d, $Size - $d, $d, $d, 0, 90)
        $path.AddArc(0, $Size - $d, $d, $d, 90, 90)
        $path.CloseFigure()
        return $path
    }

    # A server rack: three light bars with a green status light each, on dark blue.
    function New-IconPng([int]$Size) {
        $bitmap = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.Clear([System.Drawing.Color]::Transparent)
            $back = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 31, 58, 95))
            $bar = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 232, 238, 247))
            $led = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 63, 185, 80))
            $g.FillPath($back, (New-RoundedRect $Size ($Size * 0.2)))
            foreach ($row in 0.20, 0.42, 0.64) {
                $g.FillRectangle($bar, [single]($Size * 0.16), [single]($Size * $row), [single]($Size * 0.68), [single]($Size * 0.16))
                $dot = $Size * 0.09
                $g.FillEllipse($led, [single]($Size * 0.70), [single]($Size * $row + ($Size * 0.16 - $dot) / 2), [single]$dot, [single]$dot)
            }
            $stream = New-Object System.IO.MemoryStream
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            return , $stream.ToArray()
        } finally {
            $g.Dispose()
            $bitmap.Dispose()
        }
    }

    function Write-IconFile([string]$Path) {
        $sizes = 16, 32, 48, 256
        $images = @(foreach ($s in $sizes) { , (New-IconPng $s) })
        $stream = New-Object System.IO.MemoryStream
        $writer = New-Object System.IO.BinaryWriter $stream
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
            $writer.Write([byte]$dim)
            $writer.Write([byte]$dim)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$images[$i].Length)
            $writer.Write([uint32]$offset)
            $offset += $images[$i].Length
        }
        foreach ($image in $images) { $writer.Write($image) }
        $writer.Flush()
        [System.IO.File]::WriteAllBytes($Path, $stream.ToArray())
    }

    $icon = Join-Path $work 'RevitServerStack.ico'
    Write-IconFile $icon

    # ------------------------------------------------------------- compile --

    $assemblyInfo = Join-Path $work 'AssemblyInfo.cs'
    $versionFour = "$version.0"
    [System.IO.File]::WriteAllText($assemblyInfo, @"
using System.Reflection;
[assembly: AssemblyTitle("Revit Server Stack")]
[assembly: AssemblyProduct("Revit Server Stack")]
[assembly: AssemblyDescription("Tray launcher of the Revit Server Stack control panel")]
[assembly: AssemblyCopyright("Copyright (c) 2026 mahach666. MIT License.")]
[assembly: AssemblyVersion("$versionFour")]
[assembly: AssemblyFileVersion("$versionFour")]
[assembly: AssemblyInformationalVersion("$version")]
"@, (New-Object System.Text.UTF8Encoding($false)))

    $csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    if (-not (Test-Path -LiteralPath $csc)) { throw 'csc.exe of .NET Framework 4 was not found.' }

    $exe = Join-Path $OutDir 'RevitServerStack.exe'
    & $csc /nologo /target:winexe /optimize+ /platform:anycpu /codepage:65001 `
        "/out:$exe" "/win32icon:$icon" "/win32manifest:$(Join-Path $launcherDir 'app.manifest')" `
        /reference:System.Windows.Forms.dll /reference:System.Drawing.dll `
        (Join-Path $launcherDir 'RevitServerStack.cs') $assemblyInfo
    if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE." }
    Write-Host "Built $exe (version $version)"

    if (-not $Release) { return }

    # ------------------------------------------------------------- release --

    $top = "RevitServerStack-$version"
    $zipPath = Join-Path $OutDir "$top.zip"

    # Same set of files git would commit: tracked and new, ignored ones left out.
    $previousEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    try {
        $listed = @(& git -C $repo -c core.quotepath=off ls-files --cached --others --exclude-standard)
        if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed.' }
    } finally {
        [Console]::OutputEncoding = $previousEncoding
    }

    $files = @($listed | Where-Object {
        $_ -and
        $_ -notmatch '^(launcher|panel/tests)/' -and
        $_ -notmatch '^\.[^/]*$' -and
        (Test-Path -LiteralPath (Join-Path $repo $_) -PathType Leaf)
    } | Sort-Object -Unique)
    if ($files.Count -eq 0) { throw 'No files to package.' }

    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        # Forward slashes in entry names: Compress-Archive of Windows PowerShell 5.1 writes backslashes.
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $exe, "$top/RevitServerStack.exe",
            [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        foreach ($relative in $files) {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $repo $relative),
                "$top/$($relative -replace '\\', '/')", [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally {
        $zip.Dispose()
    }

    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText("$zipPath.sha256", "$hash  $top.zip`n", (New-Object System.Text.UTF8Encoding($false)))

    # The release notes are the changelog entry of this version.
    $section = [regex]::Match($changelog, "(?ms)^## \[$([regex]::Escape($version))\][^\r\n]*\r?\n(.*?)(?=^## \[|^\[[^\]]+\]: |\z)")
    $notes = "## Revit Server Stack $version`n`n" + ($section.Groups[1].Value.Trim() -replace '\r\n', "`n") + "`n"
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'RELEASE_NOTES.md'), $notes, (New-Object System.Text.UTF8Encoding($false)))

    Write-Host "Packed $($files.Count + 1) files into $zipPath"
    Write-Host "SHA-256 $hash"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
