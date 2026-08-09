[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string[]]$Runtime = @('win-x64', 'win-arm64'),
    [string]$ArtifactsRoot,
    [string]$RequiredFilesManifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'shared\secret-patterns.ps1')

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if ([string]::IsNullOrWhiteSpace($ArtifactsRoot)) {
    $ArtifactsRoot = Join-Path $projectRoot 'artifacts'
}
$artifactsFull = [IO.Path]::GetFullPath($ArtifactsRoot)
if ([string]::IsNullOrWhiteSpace($RequiredFilesManifest)) {
    $RequiredFilesManifest = Join-Path $PSScriptRoot 'media-normalizer-required-files.psd1'
}
foreach ($path in @($ArtifactsRoot, $RequiredFilesManifest)) {
    if (Test-SecretFilePath -FilePath $path) {
        throw "MEDIA_NORMALIZER_SECRET_PATH_REJECTED: $path"
    }
}
$required = (Import-PowerShellDataFile -LiteralPath $RequiredFilesManifest).RequiredRelativePaths

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-StreamSha256 {
    param([Parameter(Mandatory)][IO.Stream]$Stream)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Test-SafeZipEntryName {
    param([Parameter(Mandatory)][string]$Name)
    $normalized = $Name.Replace('/', '\')
    return (-not [string]::IsNullOrWhiteSpace($normalized) -and
        -not [IO.Path]::IsPathRooted($normalized) -and
        -not $normalized.Contains(':') -and
        $normalized -notmatch '(^|[\\/])\.\.?([\\/]|$)')
}

$failures = [Collections.Generic.List[string]]::new()
$receipts = [Collections.Generic.List[object]]::new()
foreach ($rid in $Runtime) {
    $name = "media-normalizer-$rid"
    $package = Join-Path $artifactsFull $name
    $zipPath = Join-Path $artifactsFull "$name.zip"
    $checksumPath = Join-Path $artifactsFull "$name.zip.sha256"
    try {
        if (-not (Test-Path -LiteralPath $package -PathType Container)) {
            throw "展開済み成果物がありません: $package"
        }
        foreach ($path in @($zipPath, $checksumPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "成果物がありません: $path"
            }
        }

        $expectedZipHash = ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -split '\s+')[0]
        $actualZipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expectedZipHash -notmatch '^[0-9a-fA-F]{64}$' -or
            $actualZipHash -ne $expectedZipHash.ToLowerInvariant()) {
            throw "ZIPチェックサムが一致しません: $zipPath"
        }

        $privacyReceipt = & (Join-Path $PSScriptRoot 'test-zip-privacy.ps1') `
            -ZipPath $zipPath

        $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $entryMap = @{}
            $readBytes = 0L
            foreach ($entry in $archive.Entries) {
                if ([string]::IsNullOrEmpty($entry.Name)) { continue }
                if (-not (Test-SafeZipEntryName -Name $entry.FullName)) {
                    throw "危険なZIPエントリです: $($entry.FullName)"
                }
                $key = $entry.FullName.Replace('/', '\').ToLowerInvariant()
                if ($entryMap.ContainsKey($key)) {
                    throw "重複したZIPエントリです: $($entry.FullName)"
                }
                $stream = $entry.Open()
                try {
                    $hash = Get-StreamSha256 -Stream $stream
                    $readBytes += $entry.Length
                } finally {
                    $stream.Dispose()
                }
                $entryMap[$key] = [pscustomobject]@{ Entry = $entry; Sha256 = $hash }
            }

            foreach ($relative in $required) {
                $key = $relative.Replace('/', '\').ToLowerInvariant()
                $filePath = Join-Path $package $relative
                if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                    throw "展開済み成果物の必須ファイルがありません: $relative"
                }
                if (-not $entryMap.ContainsKey($key)) {
                    throw "ZIPの必須ファイルがありません: $relative"
                }
                $fileHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($fileHash -ne $entryMap[$key].Sha256) {
                    throw "ZIPと展開済み成果物の内容が一致しません: $relative"
                }
            }
        } finally {
            $archive.Dispose()
        }

        $dependencyManifestPath = Join-Path $package 'runtime\dependency-manifest.json'
        $dependencyManifest = Get-Content -LiteralPath $dependencyManifestPath -Raw | ConvertFrom-Json
        if ([string]$dependencyManifest.runtime -ne $rid) {
            throw "依存manifestのruntimeが一致しません: $rid"
        }
        foreach ($critical in @($dependencyManifest.criticalFiles)) {
            $criticalPath = Join-Path (Join-Path $package 'runtime') ([string]$critical.path)
            if (-not (Test-Path -LiteralPath $criticalPath -PathType Leaf)) {
                throw "critical fileがありません: $($critical.path)"
            }
            $criticalHash = (Get-FileHash -LiteralPath $criticalPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($criticalHash -ne ([string]$critical.sha256).ToLowerInvariant()) {
                throw "critical fileのSHA-256が一致しません: $($critical.path)"
            }
        }

        $receipts.Add([pscustomobject]@{
            Runtime = $rid
            ZipSha256 = $actualZipHash
            RequiredFiles = @($required).Count
            ZipEntries = $entryMap.Count
            UncompressedBytes = $readBytes
            BytecodeEntries = [int]$privacyReceipt.BytecodeEntries
            LocalWindowsUserPathCandidates =
                [int]$privacyReceipt.LocalWindowsUserPathCandidates
            Status = 'OK'
        })
    } catch {
        $failures.Add("[$rid] $($_.Exception.Message)")
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "成果物整合性検証に失敗しました ($($failures.Count)件)。"
}

$receipts | Format-Table -AutoSize
