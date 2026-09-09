<#
.SYNOPSIS
    Media NormalizerをRID別の自己完結型ポータブルフォルダーへ再構築する。

.PARAMETER Runtime
    出力対象のWindows RID。win-x64またはwin-arm64。

.PARAMETER OutputRoot
    出力を格納する既存の親ディレクトリ。相対パスはプロジェクトルート基準。
    プロジェクトルートの場合はartifactsを使用し、それ以外では直下に
    MediaNormalizerBuildsを作成する。

.PARAMETER SelectOutputRoot
    OutputRootが省略された場合、Windowsのフォルダー選択ダイアログを表示する。

.PARAMETER CleanBuild
    既存ランタイムと共有キャッシュを使わず、隔離した空キャッシュへ固定依存物を
    すべて再取得して配布物を構築する。

.PARAMETER DownloadTimeoutSeconds
    完全クリーンビルドまたは初回取得時の、1回の依存取得に対するタイムアウト秒数。

.PARAMETER DownloadRetryCount
    完全クリーンビルドまたは初回取得時の、初回失敗後の追加試行回数。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('win-x64', 'win-arm64')]
    [string]$Runtime,
    [string]$OutputRoot,
    [switch]$SelectOutputRoot,
    [string]$PreparedRuntimeRoot,
    [switch]$CleanBuild,
    [ValidateRange(30, 3600)]
    [int]$DownloadTimeoutSeconds = 900,
    [ValidateRange(0, 5)]
    [int]$DownloadRetryCount = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'shared\secret-patterns.ps1')

if ($CleanBuild -and -not [string]::IsNullOrWhiteSpace($PreparedRuntimeRoot)) {
    throw 'CleanBuild cannot be combined with PreparedRuntimeRoot.'
}

function ConvertTo-GuardedDirectoryPath {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $filesystemRoot = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath -ieq $filesystemRoot) {
        return $filesystemRoot
    }

    return $fullPath.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-PathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $rootFull = ConvertTo-GuardedDirectoryPath -Path $Root
    $pathFull = [IO.Path]::GetFullPath($Path)
    $rootPrefix = if ($rootFull.EndsWith(
            [IO.Path]::DirectorySeparatorChar.ToString(),
            [StringComparison]::Ordinal)) {
        $rootFull
    }
    else {
        $rootFull + [IO.Path]::DirectorySeparatorChar
    }

    if ($pathFull -ne $rootFull -and
        -not $pathFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate outside the allowed root: $pathFull"
    }
    return $pathFull
}

function Assert-ManagedDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ExpectedLeaf
    )

    $pathFull = Assert-PathWithinRoot -Path $Path -Root $Root
    if ((Split-Path -Leaf $pathFull) -cne $ExpectedLeaf) {
        throw "Refusing to manage an unexpected directory: $pathFull"
    }
    if (Test-Path -LiteralPath $pathFull) {
        if (-not (Test-Path -LiteralPath $pathFull -PathType Container)) {
            throw "Managed path exists but is not a directory: $pathFull"
        }
        if ((Get-Item -LiteralPath $pathFull -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Managed directory cannot be a symbolic link or junction: $pathFull"
        }
    }
    return $pathFull
}

function Clear-DirectoryContents {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AllowedRoot
    )

    $pathFull = Assert-PathWithinRoot -Path $Path -Root $AllowedRoot
    New-Item -ItemType Directory -Path $pathFull -Force | Out-Null
    Get-ChildItem -LiteralPath $pathFull -Force | ForEach-Object {
        $child = Assert-PathWithinRoot -Path $_.FullName -Root $pathFull
        Remove-Item -LiteralPath $child -Recurse -Force
    }
}

function Remove-PortablePythonBytecode {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$StagingRoot
    )

    $packageFull = Assert-PathWithinRoot -Path $PackageRoot -Root $StagingRoot
    $pythonRoot = Assert-PathWithinRoot `
        -Path (Join-Path $packageFull 'runtime\python') `
        -Root $packageFull
    if (-not (Test-Path -LiteralPath $pythonRoot -PathType Container)) {
        throw "Portable Python root is missing: $pythonRoot"
    }

    $pythonItems = @(Get-ChildItem -LiteralPath $pythonRoot -Recurse -Force)
    $reparsePoint = $pythonItems |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
        Select-Object -First 1
    if ($null -ne $reparsePoint) {
        throw "Portable Python cannot contain a symbolic link or junction: $($reparsePoint.FullName)"
    }

    $bytecodeFiles = @($pythonItems | Where-Object {
            -not $_.PSIsContainer -and $_.Extension -ieq '.pyc'
        })
    foreach ($file in $bytecodeFiles) {
        $safeFile = Assert-PathWithinRoot -Path $file.FullName -Root $pythonRoot
        Remove-Item -LiteralPath $safeFile -Force
    }

    $cacheDirectories = @($pythonItems | Where-Object {
            $_.PSIsContainer -and $_.Name -ceq '__pycache__'
        } | Sort-Object { $_.FullName.Length } -Descending)
    foreach ($directory in $cacheDirectories) {
        $safeDirectory = Assert-PathWithinRoot -Path $directory.FullName -Root $pythonRoot
        if ((Split-Path -Leaf $safeDirectory) -cne '__pycache__') {
            throw "Refusing to remove an unexpected Python cache directory: $safeDirectory"
        }
        if (Test-Path -LiteralPath $safeDirectory -PathType Container) {
            Remove-Item -LiteralPath $safeDirectory -Recurse -Force
        }
    }

    $remaining = @(Get-ChildItem -LiteralPath $pythonRoot -Recurse -Force |
            Where-Object {
                ($_.PSIsContainer -and $_.Name -ceq '__pycache__') -or
                (-not $_.PSIsContainer -and $_.Extension -ieq '.pyc')
            })
    if ($remaining.Count -gt 0) {
        throw 'Portable Python bytecode cleanup did not reach the required empty state.'
    }

    Write-Host (
        "Excluded Python bytecode from the portable package: " +
        "$($bytecodeFiles.Count) file(s), $($cacheDirectories.Count) cache directory/directories."
    ) -ForegroundColor DarkCyan
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    $sourceFull = Assert-PathWithinRoot -Path $Source -Root $SourceRoot
    $destinationFull = Assert-PathWithinRoot -Path $Destination -Root $DestinationRoot
    if (-not (Test-Path -LiteralPath $sourceFull -PathType Container)) {
        throw "Copy source is not a directory: $sourceFull"
    }
    $reparsePoint = Get-ChildItem -LiteralPath $sourceFull -Recurse -Force |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
        Select-Object -First 1
    if ($null -ne $reparsePoint) {
        throw "Copy source cannot contain a symbolic link or junction: $($reparsePoint.FullName)"
    }
    New-Item -ItemType Directory -Path $destinationFull -Force | Out-Null
    Get-ChildItem -LiteralPath $sourceFull -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $destinationFull -Recurse -Force
    }
}

function Sync-DirectoryContents {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    $sourceFull = Assert-PathWithinRoot -Path $Source -Root $SourceRoot
    $destinationFull = Assert-PathWithinRoot -Path $Destination -Root $DestinationRoot
    if (-not (Test-Path -LiteralPath $sourceFull -PathType Container)) {
        throw "Sync source is not a directory: $sourceFull"
    }

    $sourceItems = @(Get-ChildItem -LiteralPath $sourceFull -Recurse -Force)
    $destinationItems = if (Test-Path -LiteralPath $destinationFull -PathType Container) {
        @(Get-ChildItem -LiteralPath $destinationFull -Recurse -Force)
    }
    else {
        @()
    }
    $reparsePoint = @($sourceItems + $destinationItems) |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
        Select-Object -First 1
    if ($null -ne $reparsePoint) {
        throw "Synchronized directories cannot contain a symbolic link or junction: $($reparsePoint.FullName)"
    }

    $sourceRelativePaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($sourceItem in $sourceItems) {
        [void]$sourceRelativePaths.Add(
            [IO.Path]::GetRelativePath($sourceFull, $sourceItem.FullName))
    }

    foreach ($destinationItem in $destinationItems |
        Sort-Object { $_.FullName.Length } -Descending) {
        $relativePath = [IO.Path]::GetRelativePath($destinationFull, $destinationItem.FullName)
        if (-not $sourceRelativePaths.Contains($relativePath)) {
            $safeItem = Assert-PathWithinRoot -Path $destinationItem.FullName -Root $destinationFull
            Remove-Item -LiteralPath $safeItem -Recurse -Force
        }
    }

    New-Item -ItemType Directory -Path $destinationFull -Force | Out-Null
    foreach ($sourceDirectory in $sourceItems |
        Where-Object { $_.PSIsContainer } |
        Sort-Object FullName) {
        $relativePath = [IO.Path]::GetRelativePath($sourceFull, $sourceDirectory.FullName)
        $destinationDirectory = Assert-PathWithinRoot `
            -Path (Join-Path $destinationFull $relativePath) `
            -Root $destinationFull
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }
    foreach ($sourceFile in $sourceItems | Where-Object { -not $_.PSIsContainer }) {
        $relativePath = [IO.Path]::GetRelativePath($sourceFull, $sourceFile.FullName)
        $destinationFile = Assert-PathWithinRoot `
            -Path (Join-Path $destinationFull $relativePath) `
            -Root $destinationFull
        $unchanged = (Test-Path -LiteralPath $destinationFile -PathType Leaf) -and
            (Get-Item -LiteralPath $destinationFile).Length -eq $sourceFile.Length -and
            (Get-FileHash -LiteralPath $destinationFile -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
        if (-not $unchanged) {
            Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationFile -Force
        }
    }
}

function Get-DirectoryDigest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AllowedRoot
    )

    $pathFull = Assert-PathWithinRoot -Path $Path -Root $AllowedRoot
    $lines = foreach ($file in Get-ChildItem -LiteralPath $pathFull -File -Recurse -Force |
        Sort-Object FullName) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Digest source cannot contain a symbolic link: $($file.FullName)"
        }
        $relativePath = [IO.Path]::GetRelativePath($pathFull, $file.FullName).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        "$relativePath`t$($file.Length)`t$hash"
    }
    $manifest = $lines -join "`n"
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($manifest)))
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

function Publish-Launcher {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$StagingRoot,
        [Parameter(Mandatory)][ValidateSet('win-x64', 'win-arm64')][string]$Runtime
    )

    $dotnet = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $dotnet) {
        throw 'MediaNormalizer.exe の生成には .NET 10 SDK (dotnet) が必要です。'
    }

    $launcherProject = Assert-PathWithinRoot `
        -Path (Join-Path $ProjectRoot 'src\MediaNormalizer.Launcher\MediaNormalizer.Launcher.csproj') `
        -Root $ProjectRoot
    if (-not (Test-Path -LiteralPath $launcherProject -PathType Leaf)) {
        throw "Launcher project was not found: $launcherProject"
    }

    $publishRoot = Assert-ManagedDirectory `
        -Path (Join-Path $PackageRoot '.launcher-publish') `
        -Root $StagingRoot `
        -ExpectedLeaf '.launcher-publish'
    New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null

    Write-Host "Publishing self-contained launcher: $Runtime" -ForegroundColor Cyan
    & $dotnet.Source publish $launcherProject `
        --configuration Release `
        --runtime $Runtime `
        --self-contained true `
        --output $publishRoot `
        -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true `
        -p:EnableCompressionInSingleFile=true `
        -p:DebugSymbols=false `
        -p:DebugType=None
    if ($LASTEXITCODE -ne 0) {
        throw "Launcher publish failed for $Runtime with exit code $LASTEXITCODE."
    }

    $publishedFiles = @(Get-ChildItem -LiteralPath $publishRoot -File -Recurse)
    $publishedLauncher = Join-Path $publishRoot 'MediaNormalizer.exe'
    if ($publishedFiles.Count -ne 1 -or
        -not (Test-Path -LiteralPath $publishedLauncher -PathType Leaf)) {
        throw "Launcher publish must produce exactly one MediaNormalizer.exe: $publishRoot"
    }

    $expectedMachine = if ($Runtime -eq 'win-arm64') { 0xAA64 } else { 0x8664 }
    $actualMachine = Get-PeMachine -Path $publishedLauncher
    if ($actualMachine -ne $expectedMachine) {
        throw ('Launcher architecture mismatch. Expected 0x{0:X4}, actual 0x{1:X4}: {2}' -f
            $expectedMachine, $actualMachine, $publishedLauncher)
    }

    $launcherDestination = Assert-PathWithinRoot `
        -Path (Join-Path $PackageRoot 'MediaNormalizer.exe') `
        -Root $StagingRoot
    Copy-Item -LiteralPath $publishedLauncher -Destination $launcherDestination
    Remove-Item -LiteralPath $publishRoot -Recurse -Force
}

function Get-RequiredInputSnapshot {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string[]]$RequiredRelativePaths
    )

    $packageFull = Assert-PathWithinRoot -Path $PackageRoot -Root $PackageRoot
    $entries = foreach ($relative in @($RequiredRelativePaths | Sort-Object)) {
        $safeRelative = [string]$relative
        if ([IO.Path]::IsPathRooted($safeRelative) -or $safeRelative -match '(^|[\\/])\.\.?([\\/]|$)' -or $safeRelative -match ':') {
            throw "Required file path must be relative: $safeRelative"
        }
        $filePath = Assert-PathWithinRoot -Path (Join-Path $packageFull $safeRelative) -Root $packageFull
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "Required input snapshot file is missing: $safeRelative"
        }
        $file = Get-Item -LiteralPath $filePath -Force
        [pscustomobject]@{
            Path = $safeRelative.Replace('\', '/')
            Size = [long]$file.Length
            Sha256 = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $manifest = ($entries | ForEach-Object { "$($_.Path)`t$($_.Size)`t$($_.Sha256)" }) -join "`n"
    [pscustomobject]@{
        Entries = @($entries)
        SnapshotDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes($manifest))).ToLowerInvariant()
    }
}

function Write-Utf8JsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$InputObject)
    $json = $InputObject | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($Path, $json + "`r`n", [Text.UTF8Encoding]::new($false))
}

function Select-OutputRootFolder {
    param([Parameter(Mandatory)][string]$InitialDirectory)

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw 'フォルダー選択画面を表示するには、PowerShellを-STAオプション付きで起動してください。'
    }

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    try {
        $dialog.Description = 'Media Normalizerを保存する既存の親フォルダーを選択してください。プロジェクトルート以外を選択すると、その中に MediaNormalizerBuilds フォルダーを作成します。'
        $dialog.UseDescriptionForTitle = $false
        $dialog.AutoUpgradeEnabled = $true
        $dialog.ShowNewFolderButton = $true
        $dialog.SelectedPath = $InitialDirectory
        $result = $dialog.ShowDialog()
        if ($result -ne [Windows.Forms.DialogResult]::OK -or
            [string]::IsNullOrWhiteSpace($dialog.SelectedPath)) {
            Write-Host '保存先の選択がキャンセルされました。ファイルは生成していません。' -ForegroundColor Yellow
            exit 3
        }
        return $dialog.SelectedPath
    }
    finally {
        $dialog.Dispose()
    }
}

function Copy-BuildInputs {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$StagingDirectory,
        [Parameter(Mandatory)][string]$StagingRoot
    )

    $entries = @(
        [pscustomobject]@{
            SourceRelativePath = 'scripts\package-templates\media-normalizer.bat'
            DestinationRelativePath = 'media-normalizer.bat'
            PathType = 'Leaf'
        }
        [pscustomobject]@{
            SourceRelativePath = 'media-normalizer.ps1'
            DestinationRelativePath = 'media-normalizer.ps1'
            PathType = 'Leaf'
        }
        [pscustomobject]@{
            SourceRelativePath = 'diagnostics\diagnose.bat'
            DestinationRelativePath = 'diagnose.bat'
            PathType = 'Leaf'
        }
        [pscustomobject]@{
            SourceRelativePath = 'diagnostics\diagnose.ps1'
            DestinationRelativePath = 'diagnose.ps1'
            PathType = 'Leaf'
        }
        [pscustomobject]@{
            SourceRelativePath = 'launcher-legacy\runtime-env.bat'
            DestinationRelativePath = 'runtime-env.bat'
            PathType = 'Leaf'
        }
        [pscustomobject]@{
            SourceRelativePath = 'diagnostics\runtime-check.bat'
            DestinationRelativePath = 'runtime-check.bat'
            PathType = 'Leaf'
        }
        [pscustomobject]@{
            SourceRelativePath = 'diagnostics\runtime-check.ps1'
            DestinationRelativePath = 'runtime-check.ps1'
            PathType = 'Leaf'
        }
        [pscustomobject]@{
            SourceRelativePath = 'THIRD-PARTY-NOTICES.md'
            DestinationRelativePath = 'THIRD-PARTY-NOTICES.md'
            PathType = 'Leaf'
        }
        [pscustomobject]@{
            SourceRelativePath = 'README.md'
            DestinationRelativePath = 'README.md'
            PathType = 'Leaf'
        }
        [pscustomobject]@{
            SourceRelativePath = 'assets'
            DestinationRelativePath = 'assets'
            PathType = 'Container'
        }
        [pscustomobject]@{
            SourceRelativePath = 'docs'
            DestinationRelativePath = 'docs'
            PathType = 'Container'
        }
        [pscustomobject]@{
            SourceRelativePath = 'lib'
            DestinationRelativePath = 'lib'
            PathType = 'Container'
        }
    )

    New-Item -ItemType Directory -Path $StagingDirectory -Force | Out-Null
    foreach ($entry in $entries) {
        $source = Assert-PathWithinRoot `
            -Path (Join-Path $ProjectRoot $entry.SourceRelativePath) `
            -Root $ProjectRoot
        if (-not (Test-Path -LiteralPath $source -PathType $entry.PathType)) {
            throw "Required build input is missing: $source"
        }
        if ((Get-Item -LiteralPath $source -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Build input cannot be a symbolic link or junction: $source"
        }
        if ($entry.PathType -eq 'Container') {
            $nestedReparsePoint = Get-ChildItem -LiteralPath $source -Recurse -Force |
                Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
                Select-Object -First 1
            if ($null -ne $nestedReparsePoint) {
                throw "Build input cannot contain a symbolic link or junction: $($nestedReparsePoint.FullName)"
            }
        }

        $destination = Assert-PathWithinRoot `
            -Path (Join-Path $StagingDirectory $entry.DestinationRelativePath) `
            -Root $StagingRoot
        Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
    }
}

function Copy-PreparedRuntime {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][ValidateSet('win-x64', 'win-arm64')][string]$Runtime,
        [Parameter(Mandatory)][string]$LockedDependencyManifest
    )

    $sourceFull = [IO.Path]::GetFullPath($SourceRoot)
    $manifestPath = Join-Path $sourceFull 'dependency-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $nestedRuntime = Join-Path $sourceFull 'runtime'
        if (Test-Path -LiteralPath (Join-Path $nestedRuntime 'dependency-manifest.json') -PathType Leaf) {
            $sourceFull = $nestedRuntime
            $manifestPath = Join-Path $sourceFull 'dependency-manifest.json'
        }
    }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Prepared runtime manifest was not found: $SourceRoot"
    }
    if ((Get-Item -LiteralPath $sourceFull -Force).Attributes -band
        [IO.FileAttributes]::ReparsePoint) {
        throw "Prepared runtime cannot be a symbolic link or junction: $sourceFull"
    }
    $reparsePoint = Get-ChildItem -LiteralPath $sourceFull -Recurse -Force |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
        Select-Object -First 1
    if ($null -ne $reparsePoint) {
        throw "Prepared runtime cannot contain a symbolic link or junction: $($reparsePoint.FullName)"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.runtime -ne $Runtime) {
        throw "Prepared runtime manifest does not match $Runtime."
    }

    $lockedManifestPath = [IO.Path]::GetFullPath($LockedDependencyManifest)
    if (-not (Test-Path -LiteralPath $lockedManifestPath -PathType Leaf)) {
        throw "Locked dependency manifest was not found: $lockedManifestPath"
    }
    $locked = Get-Content -LiteralPath $lockedManifestPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
    if ([int]$locked.schemaVersion -ne 1) {
        throw "Locked dependency manifest schema is not supported: $lockedManifestPath"
    }
    $lockedFfmpegRuntime = $locked.ffmpeg.runtimes.PSObject.Properties[$Runtime].Value
    $lockedPythonRuntime = $locked.python.runtimes.PSObject.Properties[$Runtime].Value
    $lockedNormalize = @($locked.pythonPackages |
            Where-Object name -eq 'ffmpeg-normalize' |
            Select-Object -First 1)
    if ($null -eq $lockedFfmpegRuntime -or
        $null -eq $lockedPythonRuntime -or
        $lockedNormalize.Count -ne 1) {
        throw "Locked dependency manifest does not define $Runtime completely."
    }
    if ([string]$manifest.ffmpeg.version -ne [string]$locked.ffmpeg.version -or
        [string]$manifest.ffmpeg.binarySha256 -ine [string]$lockedFfmpegRuntime.sha256 -or
        [string]$manifest.python.version -ne [string]$locked.python.version -or
        [string]$manifest.python.binarySha256 -ine [string]$lockedPythonRuntime.sha256 -or
        [string]$manifest.ffmpegNormalize.version -ne [string]$lockedNormalize[0].version) {
        throw "Prepared runtime versions do not match the locked dependencies for $Runtime."
    }
    foreach ($lockedPackage in $locked.pythonPackages) {
        $preparedPackage = @($manifest.pythonPackages |
                Where-Object name -eq $lockedPackage.name |
                Select-Object -First 1)
        if ($preparedPackage.Count -ne 1 -or
            [string]$preparedPackage[0].version -ne [string]$lockedPackage.version -or
            [string]$preparedPackage[0].sha256 -ine [string]$lockedPackage.sha256) {
            throw "Prepared runtime Python package does not match the lock: $($lockedPackage.name)"
        }
    }

    foreach ($fileEntry in $manifest.criticalFiles) {
        $filePath = Assert-PathWithinRoot `
            -Path (Join-Path $sourceFull ([string]$fileEntry.path)) `
            -Root $sourceFull
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "Prepared runtime is missing a critical file: $filePath"
        }
        $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
        if ($actualHash -ine [string]$fileEntry.sha256) {
            throw "Prepared runtime hash mismatch: $filePath"
        }
    }

    $expectedMachine = if ($Runtime -eq 'win-arm64') { 0xAA64 } else { 0x8664 }
    foreach ($relativePath in @(
            'ffmpeg\bin\ffmpeg.exe',
            'ffmpeg\bin\ffprobe.exe',
            'python\python.exe')) {
        $pePath = Assert-PathWithinRoot `
            -Path (Join-Path $sourceFull $relativePath) `
            -Root $sourceFull
        $actualMachine = Get-PeMachine -Path $pePath
        if ($actualMachine -ne $expectedMachine) {
            throw ('Prepared runtime architecture mismatch. Expected 0x{0:X4}, actual 0x{1:X4}: {2}' -f
                $expectedMachine, $actualMachine, $pePath)
        }
    }

    $destination = Assert-PathWithinRoot `
        -Path (Join-Path $PackageRoot 'runtime') `
        -Root $PackageRoot
    Copy-Item -LiteralPath $sourceFull -Destination $destination -Recurse -Force
}

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$lockedDependencyManifest = Assert-PathWithinRoot `
    -Path (Join-Path $projectRoot 'portable-dependencies.json') `
    -Root $projectRoot
$buildPathsScript = Assert-PathWithinRoot `
    -Path (Join-Path $PSScriptRoot 'resolve-media-normalizer-build-paths.ps1') `
    -Root $projectRoot
. $buildPathsScript

if ($SelectOutputRoot -and [string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Select-OutputRootFolder -InitialDirectory $projectRoot
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = $projectRoot
}

foreach ($path in @($projectRoot, $OutputRoot, $PreparedRuntimeRoot)) {
    if (-not [string]::IsNullOrWhiteSpace($path) -and
        (Test-SecretFilePath -FilePath $path)) {
        throw "MEDIA_NORMALIZER_SECRET_PATH_REJECTED: $path"
    }
}

$requestedOutputRoot = if ([IO.Path]::IsPathFullyQualified($OutputRoot)) {
    $OutputRoot
}
else {
    Join-Path $projectRoot $OutputRoot
}
$resolvedOutputRoot = Assert-MediaNormalizerOutputParent -Path $requestedOutputRoot
$buildPaths = Resolve-MediaNormalizerBuildPaths `
    -ProjectRoot $projectRoot `
    -OutputRoot $resolvedOutputRoot

$managedRootLeaf = if ($buildPaths.UsesExternalRoot) { 'MediaNormalizerBuilds' } else { 'artifacts' }
$managedRoot = Assert-ManagedDirectory `
    -Path $buildPaths.ManagedRoot `
    -Root $resolvedOutputRoot `
    -ExpectedLeaf $managedRootLeaf
$outputName = "media-normalizer-$Runtime"
$outputDirectory = Assert-ManagedDirectory `
    -Path (Join-Path $managedRoot $outputName) `
    -Root $managedRoot `
    -ExpectedLeaf $outputName

$mutexHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($projectRoot.ToUpperInvariant()))).Substring(0, 16)
$temporaryRoot = ConvertTo-GuardedDirectoryPath -Path ([IO.Path]::GetTempPath())
$stagingParentName = "MediaNormalizerStaging-$mutexHash"
$stagingParent = Assert-ManagedDirectory `
    -Path (Join-Path $temporaryRoot $stagingParentName) `
    -Root $temporaryRoot `
    -ExpectedLeaf $stagingParentName
$stagingManagedRoot = Assert-ManagedDirectory `
    -Path (Join-Path $stagingParent 'MediaNormalizerBuilds') `
    -Root $stagingParent `
    -ExpectedLeaf 'MediaNormalizerBuilds'
$stagingName = ".staging-media-normalizer-$Runtime-$([guid]::NewGuid().ToString('N'))"
$stagingDirectory = Assert-ManagedDirectory `
    -Path (Join-Path $stagingManagedRoot $stagingName) `
    -Root $stagingManagedRoot `
    -ExpectedLeaf $stagingName

$backupName = ".rollback-media-normalizer-$Runtime"
$backupRoot = Assert-ManagedDirectory `
    -Path $managedRoot `
    -Root $resolvedOutputRoot `
    -ExpectedLeaf $managedRootLeaf
$backupDirectory = Assert-ManagedDirectory `
    -Path (Join-Path $backupRoot $backupName) `
    -Root $backupRoot `
    -ExpectedLeaf $backupName
$backupZip = Assert-PathWithinRoot `
    -Path (Join-Path $backupRoot "$backupName.zip") `
    -Root $backupRoot
$backupChecksum = Assert-PathWithinRoot `
    -Path (Join-Path $backupRoot "$backupName.zip.sha256") `
    -Root $backupRoot

$updateMutex = [Threading.Mutex]::new($false, "Local\MediaNormalizer-Rebuild-$mutexHash")
$updateLockTaken = $false
$backupPrepared = $false
$outputExisted = Test-Path -LiteralPath $outputDirectory
$outputZip = Assert-PathWithinRoot `
    -Path (Join-Path $managedRoot "$outputName.zip") `
    -Root $managedRoot
$outputChecksum = Assert-PathWithinRoot `
    -Path (Join-Path $managedRoot "$outputName.zip.sha256") `
    -Root $managedRoot
$outputZipExisted = Test-Path -LiteralPath $outputZip -PathType Leaf
$outputChecksumExisted = Test-Path -LiteralPath $outputChecksum -PathType Leaf
$stagingZip = Assert-PathWithinRoot `
    -Path (Join-Path $stagingManagedRoot "$stagingName.zip") `
    -Root $stagingManagedRoot

try {
    try {
        $updateLockTaken = $updateMutex.WaitOne(0)
    }
    catch [Threading.AbandonedMutexException] {
        $updateLockTaken = $true
    }
    if (-not $updateLockTaken) {
        throw 'Another Media Normalizer rebuild is already running. Wait for it to finish, then try again.'
    }

    New-Item -ItemType Directory -Path $managedRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $stagingManagedRoot -Force | Out-Null

    Write-Host "Output parent: $resolvedOutputRoot" -ForegroundColor Cyan
    Write-Host "Managed output: $managedRoot" -ForegroundColor Cyan
    Write-Host "Architecture: $Runtime portable package." -ForegroundColor Cyan
    if ($CleanBuild) {
        Write-Host (
            'Build mode: complete clean build. Existing runtimes and the shared ' +
            'dependency cache will not be used.'
        ) -ForegroundColor Magenta
    }
    else {
        Write-Host 'Build mode: safe rebuild with verified runtime reuse.' `
            -ForegroundColor DarkCyan
    }
    Write-Host "The managed $outputName directory will be replaced only after staging succeeds." -ForegroundColor Yellow

    Copy-BuildInputs `
        -ProjectRoot $projectRoot `
        -StagingDirectory $stagingDirectory `
        -StagingRoot $stagingManagedRoot

    Publish-Launcher `
        -ProjectRoot $projectRoot `
        -PackageRoot $stagingDirectory `
        -StagingRoot $stagingManagedRoot `
        -Runtime $Runtime

    $runtimePrepared = $false
    if (-not $CleanBuild -and
        [string]::IsNullOrWhiteSpace($PreparedRuntimeRoot)) {
        $runtimeCandidates = [Collections.Generic.List[string]]::new()
        $runtimeCandidateSet = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        foreach ($candidate in @(
                (Join-Path $outputDirectory 'runtime'),
                (Join-Path $projectRoot "artifacts\$outputName\runtime"))) {
            $candidateFull = [IO.Path]::GetFullPath($candidate)
            if ($runtimeCandidateSet.Add($candidateFull) -and
                (Test-Path -LiteralPath (
                        Join-Path $candidateFull 'dependency-manifest.json'
                    ) -PathType Leaf)) {
                $runtimeCandidates.Add($candidateFull)
            }
        }
        foreach ($candidate in $runtimeCandidates) {
            try {
                Copy-PreparedRuntime `
                    -SourceRoot $candidate `
                    -PackageRoot $stagingDirectory `
                    -Runtime $Runtime `
                    -LockedDependencyManifest $lockedDependencyManifest
                Write-Host "Using verified existing runtime: $candidate" -ForegroundColor DarkCyan
                $runtimePrepared = $true
                break
            }
            catch {
                if (Test-Path -LiteralPath (Join-Path $stagingDirectory 'runtime')) {
                    throw
                }
                Write-Host (
                    "Existing runtime cannot be reused: $candidate`n" +
                    "  $($_.Exception.Message)") -ForegroundColor Yellow
            }
        }
    }

    if (-not $runtimePrepared -and
        [string]::IsNullOrWhiteSpace($PreparedRuntimeRoot)) {
        $prepareRuntimeScript = Assert-PathWithinRoot `
            -Path (Join-Path $PSScriptRoot 'prepare-portable-runtime.ps1') `
            -Root $projectRoot
        $dependencyCache = if ($CleanBuild) {
            Assert-ManagedDirectory `
                -Path (Join-Path $stagingDirectory '.clean-dependency-cache') `
                -Root $stagingDirectory `
                -ExpectedLeaf '.clean-dependency-cache'
        }
        else {
            Assert-PathWithinRoot `
                -Path (Join-Path $projectRoot '.work\portable-cache') `
                -Root $projectRoot
        }
        if ($CleanBuild) {
            Write-Host (
                'Preparing runtime from an isolated empty dependency cache: ' +
                $dependencyCache
            ) -ForegroundColor Magenta
        }
        & $prepareRuntimeScript `
            -Runtime $Runtime `
            -PackageRoot $stagingDirectory `
            -CacheRoot $dependencyCache `
            -DownloadTimeoutSeconds $DownloadTimeoutSeconds `
            -DownloadRetryCount $DownloadRetryCount
        $runtimePrepared = $true
        if ($CleanBuild -and (Test-Path -LiteralPath $dependencyCache)) {
            $safeCleanCache = Assert-ManagedDirectory `
                -Path $dependencyCache `
                -Root $stagingDirectory `
                -ExpectedLeaf '.clean-dependency-cache'
            Remove-Item -LiteralPath $safeCleanCache -Recurse -Force
            Write-Host 'Removed isolated clean-build dependency cache.' `
                -ForegroundColor DarkCyan
        }
    }
    elseif (-not $runtimePrepared) {
        Copy-PreparedRuntime `
            -SourceRoot $PreparedRuntimeRoot `
            -PackageRoot $stagingDirectory `
            -Runtime $Runtime `
            -LockedDependencyManifest $lockedDependencyManifest
        $runtimePrepared = $true
    }

    Remove-PortablePythonBytecode `
        -PackageRoot $stagingDirectory `
        -StagingRoot $stagingManagedRoot

    $portableMarker = Assert-PathWithinRoot `
        -Path (Join-Path $stagingDirectory 'portable-package.marker') `
        -Root $stagingDirectory
    [IO.File]::WriteAllText(
        $portableMarker,
        "media-normalizer-portable`r`n",
        [Text.UTF8Encoding]::new($false))

    $requiredFilesDefinitionPath = Join-Path $PSScriptRoot 'media-normalizer-required-files.psd1'
    $requiredFilesDefinition = Import-PowerShellDataFile -LiteralPath $requiredFilesDefinitionPath
    foreach ($requiredRelativePath in $requiredFilesDefinition.RequiredRelativePaths) {
        $requiredPath = Assert-PathWithinRoot `
            -Path (Join-Path $stagingDirectory $requiredRelativePath) `
            -Root $stagingDirectory
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Staged package is incomplete: $requiredPath"
        }
    }

    $buildId = [guid]::NewGuid().ToString('N')
    $requiredSnapshot = Get-RequiredInputSnapshot `
        -PackageRoot $stagingDirectory `
        -RequiredRelativePaths @($requiredFilesDefinition.RequiredRelativePaths)
    $provenancePath = Assert-PathWithinRoot `
        -Path (Join-Path $stagingDirectory 'build-provenance.json') `
        -Root $stagingDirectory
    Write-Utf8JsonFile -Path $provenancePath -InputObject ([pscustomobject]@{
            SchemaVersion = 1
            Runtime = $Runtime
            BuildId = $buildId
            OutputName = $outputName
            CreatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            SnapshotDigest = $requiredSnapshot.SnapshotDigest
        })
    $stagingSnapshotPath = Assert-PathWithinRoot `
        -Path (Join-Path $stagingManagedRoot "$stagingName.build-input-snapshot.json") `
        -Root $stagingManagedRoot
    Write-Utf8JsonFile -Path $stagingSnapshotPath -InputObject ([pscustomobject]@{
            SchemaVersion = 1
            Runtime = $Runtime
            BuildId = $buildId
            OutputName = $outputName
            Entries = $requiredSnapshot.Entries
            SnapshotDigest = $requiredSnapshot.SnapshotDigest
        })

    $stagingDigest = Get-DirectoryDigest `
        -Path $stagingDirectory `
        -AllowedRoot $stagingManagedRoot

    Write-Host "Creating portable ZIP: $outputName.zip" -ForegroundColor Cyan
    Compress-Archive `
        -Path (Join-Path $stagingDirectory '*') `
        -DestinationPath $stagingZip `
        -CompressionLevel Optimal
    $stagingZipHash = (Get-FileHash -LiteralPath $stagingZip -Algorithm SHA256).Hash

    if ($outputExisted) {
        Clear-DirectoryContents -Path $backupDirectory -AllowedRoot $backupRoot
        Copy-DirectoryContents `
            -Source $outputDirectory `
            -Destination $backupDirectory `
            -SourceRoot $managedRoot `
            -DestinationRoot $backupRoot
        if ((Get-DirectoryDigest -Path $backupDirectory -AllowedRoot $backupRoot) -ne
            (Get-DirectoryDigest -Path $outputDirectory -AllowedRoot $managedRoot)) {
            throw 'Backup verification failed before updating the current build.'
        }
        if ($outputZipExisted) {
            Copy-Item -LiteralPath $outputZip -Destination $backupZip -Force
        }
        elseif (Test-Path -LiteralPath $backupZip) {
            Remove-Item -LiteralPath $backupZip -Force
        }
        if ($outputChecksumExisted) {
            Copy-Item -LiteralPath $outputChecksum -Destination $backupChecksum -Force
        }
        elseif (Test-Path -LiteralPath $backupChecksum) {
            Remove-Item -LiteralPath $backupChecksum -Force
        }
        $backupPrepared = $true
    }

    try {
        Sync-DirectoryContents `
            -Source $stagingDirectory `
            -Destination $outputDirectory `
            -SourceRoot $stagingManagedRoot `
            -DestinationRoot $managedRoot
        if ((Get-DirectoryDigest -Path $outputDirectory -AllowedRoot $managedRoot) -ne
            $stagingDigest) {
            throw 'Package verification failed after copying the staged build.'
        }
        Copy-Item -LiteralPath $stagingZip -Destination $outputZip -Force
        if ((Get-FileHash -LiteralPath $outputZip -Algorithm SHA256).Hash -ne
            $stagingZipHash) {
            throw 'Portable ZIP verification failed after copying the staged archive.'
        }
        "$($stagingZipHash.ToLowerInvariant())  $outputName.zip" |
            Set-Content -LiteralPath $outputChecksum -Encoding ascii
        & (Join-Path $PSScriptRoot 'test-artifact-integrity.ps1') `
            -Runtime $Runtime `
            -ArtifactsRoot $managedRoot `
            -RequiredFilesManifest $requiredFilesDefinitionPath `
            -BuildInputSnapshotPath $stagingSnapshotPath

        $promotedSnapshotPath = Assert-PathWithinRoot `
            -Path (Join-Path $managedRoot "$outputName.build-input-snapshot.json") `
            -Root $managedRoot
        Copy-Item -LiteralPath $stagingSnapshotPath -Destination $promotedSnapshotPath -Force
    }
    catch {
        if ($backupPrepared) {
            Sync-DirectoryContents `
                -Source $backupDirectory `
                -Destination $outputDirectory `
                -SourceRoot $backupRoot `
                -DestinationRoot $managedRoot
            if ($outputZipExisted) {
                Copy-Item -LiteralPath $backupZip -Destination $outputZip -Force
            }
            elseif (Test-Path -LiteralPath $outputZip) {
                Remove-Item -LiteralPath $outputZip -Force
            }
            if ($outputChecksumExisted) {
                Copy-Item -LiteralPath $backupChecksum -Destination $outputChecksum -Force
            }
            elseif (Test-Path -LiteralPath $outputChecksum) {
                Remove-Item -LiteralPath $outputChecksum -Force
            }
        }
        elseif (-not $outputExisted -and (Test-Path -LiteralPath $outputDirectory)) {
            $safePartialOutput = Assert-ManagedDirectory `
                -Path $outputDirectory `
                -Root $managedRoot `
                -ExpectedLeaf $outputName
            Remove-Item -LiteralPath $safePartialOutput -Recurse -Force
            if (Test-Path -LiteralPath $outputZip) { Remove-Item -LiteralPath $outputZip -Force }
            if (Test-Path -LiteralPath $outputChecksum) { Remove-Item -LiteralPath $outputChecksum -Force }
        }
        throw
    }

    Write-Host "Updated portable build: $outputDirectory" -ForegroundColor Green
    Write-Host "Launcher: $(Join-Path $outputDirectory 'media-normalizer.bat')" -ForegroundColor Green
    Write-Host "ZIP: $outputZip" -ForegroundColor Green
    Write-Host "SHA-256: $($stagingZipHash.ToLowerInvariant())" -ForegroundColor Green
    Write-Host "Build ID: $buildId" -ForegroundColor Green
    Write-Host "Build input snapshot: $promotedSnapshotPath" -ForegroundColor Green
    if ($backupPrepared) {
        Write-Host "Previous build retained for rollback: $backupDirectory" -ForegroundColor Yellow
    }
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory) {
        $safeStaging = Assert-ManagedDirectory `
            -Path $stagingDirectory `
            -Root $stagingManagedRoot `
            -ExpectedLeaf $stagingName
        Remove-Item -LiteralPath $safeStaging -Recurse -Force
    }
    if (Test-Path -LiteralPath $stagingZip) {
        $safeStagingZip = Assert-PathWithinRoot -Path $stagingZip -Root $stagingManagedRoot
        Remove-Item -LiteralPath $safeStagingZip -Force
    }
    if ($updateLockTaken) {
        $updateMutex.ReleaseMutex()
    }
    $updateMutex.Dispose()
}
