#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RuntimeRoot = (Join-Path $PSScriptRoot 'runtime'),
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-RuntimeCheck {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$Checks,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][bool]$Passed,
        [string]$Detail = ''
    )

    $Checks.Add([pscustomobject]@{
            Component = $Name
            Version   = $Version
            Status    = if ($Passed) { 'OK' } else { 'ERROR' }
            Detail    = $Detail
        })
}

function Get-OsArchitectureName {
    try {
        return [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }
    catch {
        if ($env:PROCESSOR_ARCHITEW6432) {
            return $env:PROCESSOR_ARCHITEW6432
        }
        return $env:PROCESSOR_ARCHITECTURE
    }
}

function Invoke-VersionCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return [pscustomobject]@{ ExitCode = -1; Text = ''; Error = 'file not found' }
    }

    try {
        $output = & $FilePath @Arguments 2>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Text     = ($output | Out-String).Trim()
            Error    = ''
        }
    }
    catch {
        return [pscustomobject]@{
            ExitCode = -1
            Text     = ''
            Error    = $_.Exception.Message
        }
    }
}

$resolvedRuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
$manifestPath = Join-Path $resolvedRuntimeRoot 'dependency-manifest.json'
$checks = [Collections.Generic.List[object]]::new()
$hasFailure = $false

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Write-Error "Bundled runtime manifest was not found: $manifestPath"
    exit 1
}

try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Error "Bundled runtime manifest is invalid: $($_.Exception.Message)"
    exit 1
}

$osArchitecture = Get-OsArchitectureName
$expectedArchitecture = if ($manifest.runtime -eq 'win-arm64') { 'Arm64' } else { 'X64' }
$architectureOk = $osArchitecture -ieq $expectedArchitecture
Add-RuntimeCheck `
    -Checks $checks `
    -Name 'Architecture' `
    -Version $osArchitecture `
    -Passed $architectureOk `
    -Detail "expected $expectedArchitecture"
$hasFailure = $hasFailure -or -not $architectureOk

foreach ($fileEntry in $manifest.criticalFiles) {
    $filePath = Join-Path $resolvedRuntimeRoot ([string]$fileEntry.path)
    $fileOk = Test-Path -LiteralPath $filePath -PathType Leaf
    $detail = if ($fileOk) {
        $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
        $fileOk = $actualHash -ieq [string]$fileEntry.sha256
        if ($fileOk) { 'SHA-256 verified' } else { 'SHA-256 mismatch' }
    }
    else {
        'file not found'
    }
    Add-RuntimeCheck `
        -Checks $checks `
        -Name ([string]$fileEntry.name) `
        -Version 'file' `
        -Passed $fileOk `
        -Detail $detail
    $hasFailure = $hasFailure -or -not $fileOk
}

$ffmpegPath = Join-Path $resolvedRuntimeRoot 'ffmpeg\bin\ffmpeg.exe'
$ffprobePath = Join-Path $resolvedRuntimeRoot 'ffmpeg\bin\ffprobe.exe'
$pythonPath = Join-Path $resolvedRuntimeRoot 'python\python.exe'
$pythonRoot = Join-Path $resolvedRuntimeRoot 'python'
$sitePackagesPath = Join-Path $pythonRoot 'Lib\site-packages'

# Keep diagnostics self-contained even when invoked without runtime-env.bat.
$env:PATH = "$(Split-Path -Parent $ffmpegPath);$pythonRoot;$env:PATH"
$env:PYTHONHOME = $pythonRoot
$env:PYTHONPATH = $sitePackagesPath
$env:FFMPEG_PATH = $ffmpegPath

if ($architectureOk) {
    $ffmpegResult = Invoke-VersionCommand -FilePath $ffmpegPath -Arguments @('-version')
    $ffmpegOk = $ffmpegResult.ExitCode -eq 0 -and
        $ffmpegResult.Text -match [regex]::Escape([string]$manifest.ffmpeg.version)
    Add-RuntimeCheck `
        -Checks $checks `
        -Name 'FFmpeg' `
        -Version ([string]$manifest.ffmpeg.version) `
        -Passed $ffmpegOk `
        -Detail $ffmpegResult.Error
    $hasFailure = $hasFailure -or -not $ffmpegOk

    $ffprobeResult = Invoke-VersionCommand -FilePath $ffprobePath -Arguments @('-version')
    $ffprobeOk = $ffprobeResult.ExitCode -eq 0 -and
        $ffprobeResult.Text -match [regex]::Escape([string]$manifest.ffmpeg.version)
    Add-RuntimeCheck `
        -Checks $checks `
        -Name 'ffprobe' `
        -Version ([string]$manifest.ffmpeg.version) `
        -Passed $ffprobeOk `
        -Detail $ffprobeResult.Error
    $hasFailure = $hasFailure -or -not $ffprobeOk

    $pythonResult = Invoke-VersionCommand -FilePath $pythonPath -Arguments @('--version')
    $pythonOk = $pythonResult.ExitCode -eq 0 -and
        $pythonResult.Text -match [regex]::Escape([string]$manifest.python.version)
    Add-RuntimeCheck `
        -Checks $checks `
        -Name 'Python' `
        -Version ("{0} (bundled)" -f $manifest.python.version) `
        -Passed $pythonOk `
        -Detail $pythonResult.Error
    $hasFailure = $hasFailure -or -not $pythonOk

    $normalizeResult = Invoke-VersionCommand `
        -FilePath $pythonPath `
        -Arguments @('-m', 'ffmpeg_normalize', '--version')
    $normalizeOk = $normalizeResult.ExitCode -eq 0 -and
        $normalizeResult.Text -match [regex]::Escape([string]$manifest.ffmpegNormalize.version)
    Add-RuntimeCheck `
        -Checks $checks `
        -Name 'ffmpeg-normalize' `
        -Version ([string]$manifest.ffmpegNormalize.version) `
        -Passed $normalizeOk `
        -Detail $normalizeResult.Error
    $hasFailure = $hasFailure -or -not $normalizeOk

    $filterResult = Invoke-VersionCommand -FilePath $ffmpegPath -Arguments @('-hide_banner', '-filters')
    $filterOk = $filterResult.ExitCode -eq 0 -and $filterResult.Text -match '\bloudnorm\b'
    Add-RuntimeCheck `
        -Checks $checks `
        -Name 'loudnorm filter' `
        -Version 'required' `
        -Passed $filterOk
    $hasFailure = $hasFailure -or -not $filterOk

    $encoderResult = Invoke-VersionCommand -FilePath $ffmpegPath -Arguments @('-hide_banner', '-encoders')
    $requiredEncoders = @(
        'aac',
        'flac',
        'libmp3lame',
        'libopus',
        'libvorbis',
        'libx264',
        'pcm_s24le')
    $missingEncoders = @($requiredEncoders | Where-Object {
        $encoderResult.Text -notmatch ('\b' + [regex]::Escape($_) + '\b')
    })
    $encoderOk = $encoderResult.ExitCode -eq 0 -and $missingEncoders.Count -eq 0
    Add-RuntimeCheck `
        -Checks $checks `
        -Name 'Required encoders' `
        -Version ($requiredEncoders -join ', ') `
        -Passed $encoderOk `
        -Detail $(if ($missingEncoders.Count -gt 0) {
            'Missing: ' + ($missingEncoders -join ', ')
        } else { '' })
    $hasFailure = $hasFailure -or -not $encoderOk
}

$tempPath = [IO.Path]::GetTempPath()
$writeProbe = Join-Path $tempPath ("media-normalizer-write-$([Guid]::NewGuid().ToString('N')).tmp")
$writeOk = $false
$writeDetail = ''
try {
    [IO.File]::WriteAllText($writeProbe, 'ok')
    $writeOk = Test-Path -LiteralPath $writeProbe -PathType Leaf
}
catch {
    $writeDetail = $_.Exception.Message
}
finally {
    if (Test-Path -LiteralPath $writeProbe) {
        Remove-Item -LiteralPath $writeProbe -Force -ErrorAction SilentlyContinue
    }
}
Add-RuntimeCheck `
    -Checks $checks `
    -Name 'Temp write access' `
    -Version $tempPath `
    -Passed $writeOk `
    -Detail $writeDetail
$hasFailure = $hasFailure -or -not $writeOk

try {
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($tempPath))
    $freeGb = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    $spaceOk = $drive.AvailableFreeSpace -ge 1GB
    Add-RuntimeCheck `
        -Checks $checks `
        -Name 'Temp free space' `
        -Version ("{0:N1} GB" -f $freeGb) `
        -Passed $spaceOk `
        -Detail 'minimum 1.0 GB'
    $hasFailure = $hasFailure -or -not $spaceOk
}
catch {
    Add-RuntimeCheck `
        -Checks $checks `
        -Name 'Temp free space' `
        -Version 'unknown' `
        -Passed $false `
        -Detail $_.Exception.Message
    $hasFailure = $true
}

if (-not $Quiet -or $hasFailure) {
    $checks | Format-Table Component, Version, Status, Detail -AutoSize
}

if ($hasFailure) {
    exit 1
}
exit 0
