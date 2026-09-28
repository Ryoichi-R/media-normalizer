[CmdletBinding(DefaultParameterSetName = 'Legacy')]
param(
    [Parameter(Mandatory, ParameterSetName = 'MacApp')][string]$AppPath,
    [Parameter(ParameterSetName = 'Legacy')]
    [Parameter(ParameterSetName = 'Candidate')]
    [ValidateSet('win-x64', 'win-arm64')]
    [string[]]$Runtime = @('win-x64', 'win-arm64'),
    [Parameter(ParameterSetName = 'Legacy')]
    [Parameter(ParameterSetName = 'Candidate')]
    [string]$ArtifactsRoot,
    [Parameter(ParameterSetName = 'Legacy')]
    [Parameter(ParameterSetName = 'Candidate')]
    [string]$RequiredFilesManifest,
    [Parameter(ParameterSetName = 'Candidate', Mandatory)]
    [string]$BuildInputSnapshotPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSCmdlet.ParameterSetName -eq 'MacApp') {
    & (Join-Path $PSScriptRoot 'test-macos-artifact.ps1') -AppPath $AppPath
    return
}

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

function Test-SafeRelativePath {
    param([Parameter(Mandatory)][string]$Path)
    return (-not [string]::IsNullOrWhiteSpace($Path) -and
        -not [IO.Path]::IsPathRooted($Path) -and
        -not $Path.Contains(':') -and
        $Path -notmatch '(^|[\\/])\.\.?([\\/]|$)')
}

function Assert-NoAbsolutePathValues {
    param($Value, [string]$Context = '$')
    if ($Value -is [string]) {
        if ([IO.Path]::IsPathRooted($Value) -or $Value -match '^[A-Za-z]:[\\/]' -or $Value -match '^\\\\') {
            throw "絶対パスを含むprovenance値です: $Context"
        }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { Assert-NoAbsolutePathValues -Value $Value[$key] -Context "$Context.$key" }
        return
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [byte[]]) {
        $index = 0
        foreach ($item in $Value) { Assert-NoAbsolutePathValues -Value $item -Context "$Context[$index]"; $index++ }
        return
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            Assert-NoAbsolutePathValues -Value $property.Value -Context "$Context.$($property.Name)"
        }
    }
}

function Get-FileDigestMap {
    param([Parameter(Mandatory)][string]$Root)
    $map = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force)) {
        $relative = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
        if (-not (Test-SafeRelativePath -Path $relative)) { throw "安全でない成果物相対パスです: $relative" }
        $key = $relative.ToLowerInvariant()
        if ($map.ContainsKey($key)) { throw "重複した成果物相対パスです: $relative" }
        $map[$key] = [pscustomobject]@{
            Path = $relative
            Size = [long]$file.Length
            Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return $map
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
                $key = $entry.FullName.Replace('\', '/').ToLowerInvariant()
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
                $key = $relative.Replace('\', '/').ToLowerInvariant()
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

        if ($PSBoundParameters.ContainsKey('BuildInputSnapshotPath')) {
            if (-not (Test-Path -LiteralPath $BuildInputSnapshotPath -PathType Leaf)) {
                throw "build input snapshotがありません: $BuildInputSnapshotPath"
            }
            $snapshot = Get-Content -LiteralPath $BuildInputSnapshotPath -Raw | ConvertFrom-Json
            Assert-NoAbsolutePathValues -Value $snapshot -Context 'snapshot'
            if ([int]$snapshot.SchemaVersion -ne 1 -or
                [string]$snapshot.Runtime -ne $rid -or
                [string]$snapshot.OutputName -ne $name -or
                [string]::IsNullOrWhiteSpace([string]$snapshot.BuildId)) {
                throw "build input snapshotの識別情報が一致しません: $rid"
            }
            $snapshotEntries = @($snapshot.Entries)
            $expectedKeys = @($required | ForEach-Object { ([string]$_).Replace('\', '/').ToLowerInvariant() })
            $snapshotMap = @{}
            foreach ($entry in $snapshotEntries) {
                $relative = [string]$entry.Path
                if (-not (Test-SafeRelativePath -Path $relative)) { throw "snapshotの相対パスが不正です: $relative" }
                $key = $relative.Replace('\', '/').ToLowerInvariant()
                if ($snapshotMap.ContainsKey($key)) { throw "snapshotに重複entryがあります: $relative" }
                $snapshotMap[$key] = [pscustomobject]@{
                    Path = $relative.Replace('\', '/')
                    Size = [long]$entry.Size
                    Sha256 = ([string]$entry.Sha256).ToLowerInvariant()
                }
            }
            if ((@($snapshotMap.Keys | Sort-Object) -join "`n") -ne
                (@($expectedKeys | Sort-Object) -join "`n")) {
                throw 'snapshotのentry集合がrequired-files manifestと一致しません。'
            }
            $snapshotManifest = foreach ($key in ($snapshotMap.Keys | Sort-Object)) {
                $entry = $snapshotMap[$key]
                "$($entry.Path)`t$($entry.Size)`t$($entry.Sha256)"
            }
            $snapshotDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes(($snapshotManifest -join "`n")))).ToLowerInvariant()
            if ($snapshotDigest -ne ([string]$snapshot.SnapshotDigest).ToLowerInvariant()) {
                throw 'snapshot digestが一致しません。'
            }

            $provenancePath = Join-Path $package 'build-provenance.json'
            if (-not (Test-Path -LiteralPath $provenancePath -PathType Leaf)) {
                throw "build provenanceがありません: $provenancePath"
            }
            $provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
            Assert-NoAbsolutePathValues -Value $provenance -Context 'provenance'
            if ([int]$provenance.SchemaVersion -ne 1 -or
                [string]$provenance.Runtime -ne $rid -or
                [string]$provenance.OutputName -ne $name -or
                [string]$provenance.BuildId -ne [string]$snapshot.BuildId -or
                [string]$provenance.SnapshotDigest -ne [string]$snapshot.SnapshotDigest) {
                throw 'build provenanceとsnapshotの識別情報が一致しません。'
            }
            $packageMap = Get-FileDigestMap -Root $package
            if ($packageMap.Count -ne $entryMap.Count) {
                throw "ZIPと展開済み成果物のファイル件数が一致しません: $($entryMap.Count) != $($packageMap.Count)"
            }
            foreach ($key in $entryMap.Keys) {
                if (-not $packageMap.ContainsKey($key)) {
                    throw "ZIPに対する展開済み成果物のfileがありません: $key"
                }
                if ($entryMap[$key].Sha256 -ne $packageMap[$key].Sha256 -or
                    [long]$entryMap[$key].Entry.Length -ne [long]$packageMap[$key].Size) {
                    throw "ZIPと展開済み成果物の全file照合に失敗しました: $key"
                }
            }
            foreach ($key in $snapshotMap.Keys) {
                $relative = $snapshotMap[$key].Path
                $filePath = Join-Path $package ($relative.Replace('/', '\'))
                if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                    throw "candidateのrequired fileがありません: $relative"
                }
                $file = Get-Item -LiteralPath $filePath -Force
                $hash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ([long]$file.Length -ne [long]$snapshotMap[$key].Size -or $hash -ne $snapshotMap[$key].Sha256) {
                    throw "candidateのrequired fileがsnapshotと一致しません: $relative"
                }
            }
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
