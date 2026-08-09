<#
.SYNOPSIS
    固定・検証済み依存からMedia Normalizerのポータブルランタイムを生成する。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('win-x64', 'win-arm64')]
    [string]$Runtime,
    [Parameter(Mandatory)]
    [string]$PackageRoot,
    [Parameter(Mandatory)]
    [string]$CacheRoot,
    [string]$DependencyManifest = (Join-Path (Split-Path -Parent $PSScriptRoot) 'portable-dependencies.json'),
    [ValidateRange(30, 3600)]
    [int]$DownloadTimeoutSeconds = 900,
    [ValidateRange(0, 5)]
    [int]$DownloadRetryCount = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'shared\secret-patterns.ps1')

function ConvertTo-CanonicalPath {
    param([Parameter(Mandatory)][string]$Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-PathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $rootFull = ConvertTo-CanonicalPath -Path $Root
    $pathFull = [IO.Path]::GetFullPath($Path)
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if ($pathFull -ne $rootFull -and
        -not $pathFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate outside the allowed root: $pathFull"
    }
    return $pathFull
}

function New-DependencyWebRequestParameters {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $command = Get-Command Invoke-WebRequest -CommandType Cmdlet -ErrorAction Stop
    $parameters = @{
        Uri             = $Url
        OutFile         = $OutFile
        UseBasicParsing = $true
    }
    if ($command.Parameters.ContainsKey('OperationTimeoutSeconds')) {
        $parameters.OperationTimeoutSeconds = $TimeoutSeconds
        if ($command.Parameters.ContainsKey('ConnectionTimeoutSeconds')) {
            $parameters.ConnectionTimeoutSeconds = [Math]::Min($TimeoutSeconds, 60)
        }
    }
    elseif ($command.Parameters.ContainsKey('TimeoutSec')) {
        $parameters.TimeoutSec = $TimeoutSeconds
    }
    else {
        throw 'This PowerShell 7 version does not expose a supported Invoke-WebRequest timeout parameter.'
    }

    return $parameters
}

function Invoke-DependencyTransfer {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $curlCommand = @(Get-Command curl.exe -CommandType Application `
            -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($null -ne $curlCommand) {
        $connectionTimeoutSeconds = [Math]::Min($TimeoutSeconds, 60)
        $curlArguments = @(
            '--fail',
            '--location',
            '--show-error',
            '--progress-bar',
            '--proto',
            '=https',
            '--proto-redir',
            '=https',
            '--connect-timeout',
            [string]$connectionTimeoutSeconds,
            '--max-time',
            [string]$TimeoutSeconds,
            '--output',
            $OutFile,
            '--url',
            $Url
        )
        & $curlCommand.Source @curlArguments
        if ($LASTEXITCODE -ne 0) {
            throw "curl.exe failed with exit code $LASTEXITCODE."
        }
        return
    }

    Write-Warning (
        'curl.exe was not found. Falling back to Invoke-WebRequest; ' +
        'download progress may be less detailed.'
    )
    $requestParameters = New-DependencyWebRequestParameters `
        -Url $Url `
        -OutFile $OutFile `
        -TimeoutSeconds $TimeoutSeconds
    Invoke-WebRequest @requestParameters
}

function Get-VerifiedArtifact {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][string]$CacheDirectory,
        [Parameter(Mandatory)][int]$DownloadTimeoutSeconds,
        [Parameter(Mandatory)][int]$DownloadRetryCount
    )

    $cacheFull = ConvertTo-CanonicalPath -Path $CacheDirectory
    New-Item -ItemType Directory -Path $cacheFull -Force | Out-Null
    $hashPrefix = $Sha256.Substring(0, 16).ToLowerInvariant()
    $cachedPath = Assert-PathWithinRoot `
        -Path (Join-Path $cacheFull "$hashPrefix-$FileName") `
        -Root $cacheFull
    if (Test-Path -LiteralPath $cachedPath -PathType Leaf) {
        $cachedHash = (Get-FileHash -LiteralPath $cachedPath -Algorithm SHA256).Hash
        if ($cachedHash -ine $Sha256) {
            throw "Cached dependency hash mismatch. Remove this file manually and rebuild: $cachedPath"
        }
        Write-Host "Using cached dependency: $FileName" -ForegroundColor DarkCyan
        return $cachedPath
    }

    $downloadName = ".$hashPrefix-$FileName-$([Guid]::NewGuid().ToString('N')).download"
    $downloadPath = Assert-PathWithinRoot `
        -Path (Join-Path $cacheFull $downloadName) `
        -Root $cacheFull
    try {
        $totalAttempts = $DownloadRetryCount + 1
        for ($attempt = 1; $attempt -le $totalAttempts; $attempt++) {
            try {
                if (Test-Path -LiteralPath $downloadPath) {
                    Remove-Item -LiteralPath $downloadPath -Force
                }
                Write-Host (
                    "Downloading: $FileName " +
                    "(attempt $attempt/$totalAttempts, timeout ${DownloadTimeoutSeconds}s)"
                ) -ForegroundColor Cyan
                Invoke-DependencyTransfer `
                    -Url $Url `
                    -OutFile $downloadPath `
                    -TimeoutSeconds $DownloadTimeoutSeconds
                Write-Host "Download completed. Verifying SHA-256: $FileName" `
                    -ForegroundColor DarkCyan
                $actualHash = (
                    Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256
                ).Hash
                if ($actualHash -ine $Sha256) {
                    throw "Downloaded dependency hash mismatch: $FileName"
                }
                Move-Item -LiteralPath $downloadPath -Destination $cachedPath
                Write-Host "Downloaded and verified: $FileName" -ForegroundColor Green
                return $cachedPath
            }
            catch {
                if (Test-Path -LiteralPath $downloadPath) {
                    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
                }
                if ($attempt -ge $totalAttempts) {
                    throw [InvalidOperationException]::new(
                        "Dependency download failed after $totalAttempts attempts: $FileName. " +
                        "Last error: $($_.Exception.Message)",
                        $_.Exception)
                }
                $retryDelaySeconds = [Math]::Min(
                    [int][Math]::Pow(2, $attempt),
                    10)
                Write-Warning (
                    "Download attempt $attempt failed for $FileName. " +
                    "Retrying in $retryDelaySeconds seconds. $($_.Exception.Message)"
                )
                Start-Sleep -Seconds $retryDelaySeconds
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $downloadPath) {
            Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Expand-VerifiedZip {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $destinationFull = ConvertTo-CanonicalPath -Path $Destination
    New-Item -ItemType Directory -Path $destinationFull -Force | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $relativePath = $entry.FullName.Replace(
                [IO.Path]::AltDirectorySeparatorChar,
                [IO.Path]::DirectorySeparatorChar)
            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                continue
            }

            $unixFileType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixFileType -eq 0xA000) {
                throw "Archive contains a symbolic link: $($entry.FullName)"
            }

            $target = Assert-PathWithinRoot `
                -Path (Join-Path $destinationFull $relativePath) `
                -Root $destinationFull
            if ([string]::IsNullOrEmpty($entry.Name)) {
                New-Item -ItemType Directory -Path $target -Force | Out-Null
                continue
            }

            $targetParent = Split-Path -Parent $target
            New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
            if (Test-Path -LiteralPath $target) {
                throw "Archive entries overlap an existing file: $target"
            }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-PeMachine {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset + 6 -gt $stream.Length) {
            throw "Invalid PE header offset: $Path"
        }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Invalid PE signature: $Path"
        }
        return $reader.ReadUInt16()
    }
    finally {
        $stream.Dispose()
    }
}

function Copy-LicenseFiles {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $licenseFiles = @(
        Get-ChildItem -LiteralPath $SourceRoot -File -Force |
            Where-Object {
                $_.Name -match '(?i)(license|copying|readme|notice)' -or
                $_.Extension -in @('.md', '.txt')
            }
    )
    foreach ($file in $licenseFiles) {
        Copy-Item -LiteralPath $file.FullName -Destination $Destination -Force
    }
}

foreach ($path in @($PackageRoot, $CacheRoot, $DependencyManifest)) {
    if (Test-SecretFilePath -FilePath $path) {
        throw "MEDIA_NORMALIZER_SECRET_PATH_REJECTED: $path"
    }
}

$packageRootFull = ConvertTo-CanonicalPath -Path $PackageRoot
$cacheRootFull = ConvertTo-CanonicalPath -Path $CacheRoot
$manifestFull = [IO.Path]::GetFullPath($DependencyManifest)
if (-not (Test-Path -LiteralPath $manifestFull -PathType Leaf)) {
    throw "Dependency manifest was not found: $manifestFull"
}
$dependencies = Get-Content -LiteralPath $manifestFull -Raw -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop
if ([int]$dependencies.schemaVersion -ne 1) {
    throw "Unsupported portable dependency manifest schema: $($dependencies.schemaVersion)"
}

$ffmpegRuntime = $dependencies.ffmpeg.runtimes.PSObject.Properties[$Runtime].Value
$pythonRuntime = $dependencies.python.runtimes.PSObject.Properties[$Runtime].Value
if ($null -eq $ffmpegRuntime -or $null -eq $pythonRuntime) {
    throw "Dependency manifest does not define runtime: $Runtime"
}

$runtimeRoot = Assert-PathWithinRoot `
    -Path (Join-Path $packageRootFull 'runtime') `
    -Root $packageRootFull
if (Test-Path -LiteralPath $runtimeRoot) {
    $existingItems = @(Get-ChildItem -LiteralPath $runtimeRoot -Force)
    if ($existingItems.Count -gt 0) {
        throw "Portable runtime destination must be empty: $runtimeRoot"
    }
}
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null

$extractRoot = Assert-PathWithinRoot `
    -Path (Join-Path $runtimeRoot '.extract') `
    -Root $runtimeRoot
$ffmpegExtract = Join-Path $extractRoot 'ffmpeg'
$pythonRoot = Join-Path $runtimeRoot 'python'
$sitePackages = Join-Path $pythonRoot 'Lib\site-packages'
$ffmpegDestination = Join-Path $runtimeRoot 'ffmpeg'
$licenseRoot = Join-Path $runtimeRoot 'licenses'

try {
    $ffmpegArchive = Get-VerifiedArtifact `
        -Url ([string]$ffmpegRuntime.url) `
        -FileName ([string]$ffmpegRuntime.archiveName) `
        -Sha256 ([string]$ffmpegRuntime.sha256) `
        -CacheDirectory $cacheRootFull `
        -DownloadTimeoutSeconds $DownloadTimeoutSeconds `
        -DownloadRetryCount $DownloadRetryCount
    $pythonArchive = Get-VerifiedArtifact `
        -Url ([string]$pythonRuntime.url) `
        -FileName ([string]$pythonRuntime.archiveName) `
        -Sha256 ([string]$pythonRuntime.sha256) `
        -CacheDirectory $cacheRootFull `
        -DownloadTimeoutSeconds $DownloadTimeoutSeconds `
        -DownloadRetryCount $DownloadRetryCount

    Expand-VerifiedZip -ArchivePath $ffmpegArchive -Destination $ffmpegExtract
    Expand-VerifiedZip -ArchivePath $pythonArchive -Destination $pythonRoot

    $ffmpegExe = Get-ChildItem -LiteralPath $ffmpegExtract -Recurse -File -Filter 'ffmpeg.exe' |
        Where-Object { (Split-Path -Leaf (Split-Path -Parent $_.FullName)) -ieq 'bin' } |
        Select-Object -First 1
    if ($null -eq $ffmpegExe) {
        throw 'FFmpeg archive does not contain bin\ffmpeg.exe.'
    }
    $ffmpegBin = Split-Path -Parent $ffmpegExe.FullName
    $ffprobeExe = Join-Path $ffmpegBin 'ffprobe.exe'
    if (-not (Test-Path -LiteralPath $ffprobeExe -PathType Leaf)) {
        throw 'FFmpeg archive does not contain bin\ffprobe.exe beside ffmpeg.exe.'
    }

    $ffmpegArchiveRoot = Split-Path -Parent $ffmpegBin
    $ffmpegOutputBin = Join-Path $ffmpegDestination 'bin'
    New-Item -ItemType Directory -Path $ffmpegOutputBin -Force | Out-Null
    Copy-Item -LiteralPath $ffmpegExe.FullName -Destination $ffmpegOutputBin
    Copy-Item -LiteralPath $ffprobeExe -Destination $ffmpegOutputBin
    Copy-LicenseFiles `
        -SourceRoot $ffmpegArchiveRoot `
        -Destination (Join-Path $licenseRoot 'FFmpeg')

    $pythonPth = Get-ChildItem -LiteralPath $pythonRoot -File -Filter 'python*._pth' |
        Select-Object -First 1
    if ($null -eq $pythonPth) {
        throw 'Python embeddable archive does not contain python*._pth.'
    }
    @(
        'python313.zip'
        '.'
        'Lib\site-packages'
        'import site'
    ) | Set-Content -LiteralPath $pythonPth.FullName -Encoding ascii
    New-Item -ItemType Directory -Path $sitePackages -Force | Out-Null

    foreach ($package in $dependencies.pythonPackages) {
        $wheel = Get-VerifiedArtifact `
            -Url ([string]$package.url) `
            -FileName ([string]$package.archiveName) `
            -Sha256 ([string]$package.sha256) `
            -CacheDirectory $cacheRootFull `
            -DownloadTimeoutSeconds $DownloadTimeoutSeconds `
            -DownloadRetryCount $DownloadRetryCount
        Expand-VerifiedZip -ArchivePath $wheel -Destination $sitePackages
    }

    $pythonLicense = Join-Path $pythonRoot 'LICENSE.txt'
    if (-not (Test-Path -LiteralPath $pythonLicense -PathType Leaf)) {
        throw 'Python embeddable archive does not contain LICENSE.txt.'
    }
    $pythonLicenseDestination = Join-Path $licenseRoot 'Python'
    New-Item -ItemType Directory -Path $pythonLicenseDestination -Force | Out-Null
    Copy-Item -LiteralPath $pythonLicense -Destination $pythonLicenseDestination -Force

    $expectedMachine = if ($Runtime -eq 'win-arm64') { 0xAA64 } else { 0x8664 }
    $criticalPaths = [ordered]@{
        FFmpeg = Join-Path $ffmpegOutputBin 'ffmpeg.exe'
        ffprobe = Join-Path $ffmpegOutputBin 'ffprobe.exe'
        Python = Join-Path $pythonRoot 'python.exe'
        PythonRuntime = Join-Path $pythonRoot 'python313.dll'
    }
    foreach ($entry in $criticalPaths.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
            throw "Portable runtime is missing $($entry.Key): $($entry.Value)"
        }
    }
    foreach ($pePath in @(
            $criticalPaths.FFmpeg,
            $criticalPaths.ffprobe,
            $criticalPaths.Python)) {
        $machine = Get-PeMachine -Path $pePath
        if ($machine -ne $expectedMachine) {
            throw ('PE architecture mismatch for {0}. Expected 0x{1:X4}, actual 0x{2:X4}.' -f
                $pePath, $expectedMachine, $machine)
        }
    }

    $hostRuntime = if (
        [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq
        [Runtime.InteropServices.Architecture]::Arm64) {
        'win-arm64'
    }
    else {
        'win-x64'
    }
    if ($hostRuntime -eq $Runtime) {
        $oldPath = $env:PATH
        $oldPythonHome = $env:PYTHONHOME
        $oldPythonPath = $env:PYTHONPATH
        $oldFfmpegPath = $env:FFMPEG_PATH
        $oldPythonDontWriteBytecode = $env:PYTHONDONTWRITEBYTECODE
        try {
            $env:PATH = "$ffmpegOutputBin;$pythonRoot;$oldPath"
            $env:PYTHONHOME = $pythonRoot
            $env:PYTHONPATH = $sitePackages
            $env:FFMPEG_PATH = $criticalPaths.FFmpeg
            $env:PYTHONDONTWRITEBYTECODE = '1'

            $ffmpegVersion = & $criticalPaths.FFmpeg -version 2>&1
            if ($LASTEXITCODE -ne 0 -or
                ($ffmpegVersion | Out-String) -notmatch
                [regex]::Escape([string]$dependencies.ffmpeg.version)) {
                throw 'Bundled FFmpeg version check failed.'
            }
            $normalizeVersion = & $criticalPaths.Python `
                -m ffmpeg_normalize --version 2>&1
            if ($LASTEXITCODE -ne 0 -or
                ($normalizeVersion | Out-String) -notmatch
                [regex]::Escape([string]$dependencies.pythonPackages[0].version)) {
                throw 'Bundled ffmpeg-normalize import/version check failed.'
            }
        }
        finally {
            $env:PATH = $oldPath
            $env:PYTHONHOME = $oldPythonHome
            $env:PYTHONPATH = $oldPythonPath
            $env:FFMPEG_PATH = $oldFfmpegPath
            $env:PYTHONDONTWRITEBYTECODE = $oldPythonDontWriteBytecode
        }
    }

    $criticalFiles = foreach ($entry in $criticalPaths.GetEnumerator()) {
        [pscustomobject]@{
            name   = [string]$entry.Key
            path   = [IO.Path]::GetRelativePath($runtimeRoot, $entry.Value).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $entry.Value -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $runtimeManifest = [ordered]@{
        schemaVersion    = 1
        runtime          = $Runtime
        ffmpeg           = [ordered]@{
            version = [string]$dependencies.ffmpeg.version
            license = [string]$dependencies.ffmpeg.license
            source  = [string]$dependencies.ffmpeg.sourceUrl
            binarySha256 = [string]$ffmpegRuntime.sha256
        }
        python            = [ordered]@{
            version = [string]$dependencies.python.version
            license = [string]$dependencies.python.license
            source  = [string]$dependencies.python.sourceUrl
            binarySha256 = [string]$pythonRuntime.sha256
        }
        ffmpegNormalize   = [ordered]@{
            version = [string]$dependencies.pythonPackages[0].version
            license = [string]$dependencies.pythonPackages[0].license
        }
        pythonPackages    = @(
            $dependencies.pythonPackages | ForEach-Object {
                [ordered]@{
                    name    = [string]$_.name
                    version = [string]$_.version
                    license = [string]$_.license
                    sha256  = [string]$_.sha256
                }
            }
        )
        criticalFiles     = @($criticalFiles)
    }
    $runtimeManifest | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $runtimeRoot 'dependency-manifest.json') -Encoding utf8

    Write-Host "Portable runtime prepared: $Runtime" -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $extractRoot) {
        $safeExtractRoot = Assert-PathWithinRoot -Path $extractRoot -Root $runtimeRoot
        Remove-Item -LiteralPath $safeExtractRoot -Recurse -Force
    }
}
