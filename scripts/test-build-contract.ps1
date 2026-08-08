[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$workspaceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $projectRoot))
$secretPatterns = Join-Path $PSScriptRoot 'shared\secret-patterns.ps1'
. $secretPatterns
$resolver = Join-Path $PSScriptRoot 'resolve-media-normalizer-build-paths.ps1'
if (Test-SecretFilePath -FilePath $resolver) {
    throw "MEDIA_NORMALIZER_SECRET_PATH_REJECTED: $resolver"
}
. $resolver

$failures = [Collections.Generic.List[string]]::new()

function Assert-Contract {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        $failures.Add($Message)
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        & $Action
        $failures.Add($Message)
    }
    catch {
    }
}

$testRoot = Join-Path $workspaceRoot (
    'TestResults\media-normalizer-build-contract-' + [Guid]::NewGuid().ToString('N'))
$externalParent = Join-Path $testRoot 'external-parent'
$filePath = Join-Path $testRoot 'not-a-directory.txt'

foreach ($path in @($testRoot, $externalParent, $filePath)) {
    if (Test-SecretFilePath -FilePath $path) {
        throw "MEDIA_NORMALIZER_SECRET_PATH_REJECTED: $path"
    }
}

$secretNames = @(
    '.env'
    '.env.local'
    'secrets.json'
    'private.key'
    'private.pem'
    'private.pfx'
    'private.p12'
    'credentials.json'
)
foreach ($secretName in $secretNames) {
    Assert-Contract (
        Test-SecretFilePath -FilePath (Join-Path $testRoot $secretName)
    ) "Secret filename must be rejected: $secretName"
}
Assert-Contract (
    -not (Test-SecretFilePath -FilePath (Join-Path $testRoot 'ordinary.json'))
) 'An ordinary filename must not be rejected.'

try {
    New-Item -ItemType Directory -Path $externalParent -Force | Out-Null
    New-Item -ItemType File -Path $filePath -Force | Out-Null

    $default = Resolve-MediaNormalizerBuildPaths -ProjectRoot $projectRoot -OutputRoot $null
    $expectedArtifacts = ConvertTo-CanonicalDirectoryPath -Path (Join-Path $projectRoot 'artifacts')
    Assert-Contract (-not $default.UsesExternalRoot) 'Default build paths must use the project root.'
    Assert-Contract ($default.ManagedRoot -ieq $expectedArtifacts) "Default managed root must be artifacts: $($default.ManagedRoot)"

    $explicitProject = Resolve-MediaNormalizerBuildPaths `
        -ProjectRoot $projectRoot `
        -OutputRoot $projectRoot
    Assert-Contract (-not $explicitProject.UsesExternalRoot) 'Explicit project root must not be external.'
    Assert-Contract ($explicitProject.ManagedRoot -ieq $expectedArtifacts) 'Explicit project root must use artifacts.'

    $external = Resolve-MediaNormalizerBuildPaths `
        -ProjectRoot $projectRoot `
        -OutputRoot $externalParent
    $expectedExternal = ConvertTo-CanonicalDirectoryPath `
        -Path (Join-Path $externalParent 'MediaNormalizerBuilds')
    Assert-Contract $external.UsesExternalRoot 'External parent must be marked external.'
    Assert-Contract ($external.ManagedRoot -ieq $expectedExternal) "External managed root mismatch: $($external.ManagedRoot)"

    $validatedParent = Assert-MediaNormalizerOutputParent -Path $externalParent
    Assert-Contract (
        $validatedParent -ieq (ConvertTo-CanonicalDirectoryPath -Path $externalParent)
    ) 'Existing directory validation changed the path.'
    Assert-Throws {
        Assert-MediaNormalizerOutputParent -Path $filePath
    } 'A file must be rejected as OutputRoot.'
    Assert-Throws {
        Assert-MediaNormalizerOutputParent -Path (Join-Path $testRoot 'missing')
    } 'A missing OutputRoot must be rejected.'

    $managedLeafParent = Join-Path $testRoot 'MediaNormalizerBuilds'
    New-Item -ItemType Directory -Path $managedLeafParent -Force | Out-Null
    Assert-Throws {
        Resolve-MediaNormalizerBuildPaths `
            -ProjectRoot $projectRoot `
            -OutputRoot $managedLeafParent
    } 'MediaNormalizerBuilds itself must be rejected as OutputRoot.'

    $nestedParent = Join-Path $projectRoot 'nested-output'
    Assert-Throws {
        Resolve-MediaNormalizerBuildPaths `
            -ProjectRoot $projectRoot `
            -OutputRoot $nestedParent
    } 'An OutputRoot inside the project must be rejected.'

    $relativeParent = [IO.Path]::GetRelativePath($projectRoot, $externalParent)
    $relative = Resolve-MediaNormalizerBuildPaths `
        -ProjectRoot $projectRoot `
        -OutputRoot $relativeParent
    Assert-Contract (
        $relative.ManagedRoot -ieq $expectedExternal
    ) 'Relative OutputRoot must resolve from the project root.'

    $batch = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'rebuild-media-normalizer.bat') -Raw
    $x64Batch = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'rebuild-media-normalizer-x64.bat') -Raw
    $arm64Batch = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'rebuild-media-normalizer-arm64.bat') -Raw
    $applicationBatch = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'package-templates\media-normalizer.bat') -Raw
    $uiModule = Get-Content -LiteralPath (
        Join-Path $projectRoot 'lib\MediaNormalizer.Ui.psm1') -Raw
    Assert-Contract (
        -not (Test-Path -LiteralPath (Join-Path $projectRoot 'media-normalizer.bat'))
    ) 'The source root must not expose a direct application launcher.'
    Assert-Contract (
        -not (Test-Path -LiteralPath (
                Join-Path $projectRoot 'rebuild-media-normalizer-x64.bat')) -and
        -not (Test-Path -LiteralPath (
                Join-Path $projectRoot 'rebuild-media-normalizer-arm64.bat'))
    ) 'Architecture-specific rebuild launchers must remain internal under scripts.'
    Assert-Contract (
        $batch.Contains('if not "%~2"==""', [StringComparison]::Ordinal)
    ) 'Batch launcher must reject multiple arguments.'
    Assert-Contract (
        $batch.Contains('rebuild-media-normalizer.ps1', [StringComparison]::Ordinal)
    ) 'Batch launcher must invoke the common rebuild script.'
    Assert-Contract (
        $batch.Contains('PROCESSOR_ARCHITECTURE', [StringComparison]::OrdinalIgnoreCase)
    ) 'Common batch launcher must detect the host architecture.'
    Assert-Contract (
        $batch.Contains('-SelectOutputRoot', [StringComparison]::Ordinal) -and
        $batch.Contains('-OutputRoot "%~f1"', [StringComparison]::Ordinal)
    ) 'Common batch launcher must support folder selection and one explicit output parent.'
    Assert-Contract (
        $batch.Contains('if /I "%~1"=="--clean"', [StringComparison]::Ordinal) -and
        $batch.Contains('set "CLEAN_SWITCH=-CleanBuild"', [StringComparison]::Ordinal)
    ) 'Common batch launcher must expose complete clean build through --clean.'
    Assert-Contract (
        $x64Batch.Contains('-Runtime win-x64', [StringComparison]::Ordinal)
    ) 'x64 batch launcher must select win-x64.'
    Assert-Contract (
        $arm64Batch.Contains('-Runtime win-arm64', [StringComparison]::Ordinal)
    ) 'ARM64 batch launcher must select win-arm64.'
    Assert-Contract (
        -not [regex]::IsMatch($applicationBatch, '(?im)^\s*chcp\b') -and
        $applicationBatch.Contains('"%~dp0MediaNormalizer.exe" %*', [StringComparison]::Ordinal)
    ) 'Application launcher must preserve the console code page and quote its executable path.'
    Assert-Contract (
        $uiModule.Contains(
            'Export-ModuleMember -Function Initialize-UiState, New-MainForm, Set-ConsoleWindowHidden, Show-MainForm',
            [StringComparison]::Ordinal) -and
        -not $uiModule.Contains('Export-ModuleMember -Function *', [StringComparison]::Ordinal)
    ) 'UI module must export only the four supported GUI entrypoints.'

    $runtimeCheck = Get-Content `
        -LiteralPath (Join-Path $projectRoot 'diagnostics\runtime-check.ps1') `
        -Raw
    Assert-Contract (
        $runtimeCheck.Contains('[AllowEmptyCollection()]', [StringComparison]::Ordinal)
    ) 'Runtime diagnostics must accept the initially empty result collection.'
    foreach ($requiredEnvironment in @(
            '$env:PATH',
            '$env:PYTHONHOME',
            '$env:PYTHONPATH',
            '$env:FFMPEG_PATH')) {
        Assert-Contract (
            $runtimeCheck.Contains($requiredEnvironment, [StringComparison]::Ordinal)
        ) "Runtime diagnostics must initialize bundled environment: $requiredEnvironment"
    }
    foreach ($requiredEncoder in @(
            'aac',
            'flac',
            'libmp3lame',
            'libopus',
            'libvorbis',
            'libx264',
            'pcm_s24le')) {
        Assert-Contract (
            $runtimeCheck.Contains("'$requiredEncoder'", [StringComparison]::Ordinal)
        ) "Runtime diagnostics must require encoder: $requiredEncoder"
    }
    $runtimeEnvironment = Get-Content `
        -LiteralPath (Join-Path $projectRoot 'launcher-legacy\runtime-env.bat') `
        -Raw
    Assert-Contract (
        $runtimeEnvironment.Contains('portable-package.marker', [StringComparison]::Ordinal)
    ) 'A portable package with a missing runtime manifest must fail closed.'

    $rebuild = Get-Content `
        -LiteralPath (Join-Path $PSScriptRoot 'rebuild-media-normalizer.ps1') `
        -Raw
    Assert-Contract (
        $rebuild.Contains(
            "SourceRelativePath = 'scripts\package-templates\media-normalizer.bat'",
            [StringComparison]::Ordinal) -and
        $rebuild.Contains(
            "DestinationRelativePath = 'media-normalizer.bat'",
            [StringComparison]::Ordinal)
    ) 'The application launcher must be copied from the internal package template.'
    foreach ($requiredInput in @(
            'media-normalizer.ps1',
            'diagnostics\diagnose.bat',
            'diagnostics\diagnose.ps1',
            'launcher-legacy\runtime-env.bat',
            'diagnostics\runtime-check.bat',
            'diagnostics\runtime-check.ps1',
            'THIRD-PARTY-NOTICES.md',
            'README.md',
            'assets',
            'docs',
            'lib')) {
        Assert-Contract (
            $rebuild.Contains(
                "SourceRelativePath = '$requiredInput'",
                [StringComparison]::Ordinal)
        ) "Build input allowlist must contain: $requiredInput"
    }
    Assert-Contract (
        -not $rebuild.Contains(
            "SourceRelativePath = 'diagnose.log'",
            [StringComparison]::Ordinal)
    ) 'Generated diagnose.log must not be packaged.'
    Assert-Contract (
        -not $rebuild.Contains(
            "SourceRelativePath = 'tmp media test'",
            [StringComparison]::Ordinal)
    ) 'Temporary test media must not be packaged.'
    Assert-Contract (
        -not $rebuild.Contains('Remove-Item -LiteralPath $managedRoot', [StringComparison]::Ordinal)
    ) 'Rebuild must never remove the managed root.'
    Assert-Contract (
        -not $rebuild.Contains('Remove-Item -LiteralPath $resolvedOutputRoot', [StringComparison]::Ordinal)
    ) 'Rebuild must never remove the output parent.'
    Assert-Contract (
        $rebuild.Contains('[IO.Path]::GetTempPath()', [StringComparison]::Ordinal)
    ) 'Rebuild staging must use the OS temporary directory.'
    Assert-Contract (
        -not $rebuild.Contains('[Environment+SpecialFolder]::LocalApplicationData', [StringComparison]::Ordinal)
    ) 'Rollback backup must not write outside the selected output tree.'
    Assert-Contract (
        $rebuild.Contains('$backupName = ".rollback-media-normalizer-$Runtime"', [StringComparison]::Ordinal) -and
        $rebuild.Contains('-Path $managedRoot', [StringComparison]::Ordinal)
    ) 'Rollback backup must stay in the managed output root.'
    Assert-Contract (
        $rebuild.Contains('Sync-DirectoryContents', [StringComparison]::Ordinal)
    ) 'Promotion must synchronize the verified staging directory.'
    Assert-Contract (
        $rebuild.Contains('if ($backupPrepared)', [StringComparison]::Ordinal)
    ) 'Rollback must require a backup prepared by the current rebuild.'
    Assert-Contract (
        $rebuild.Contains('prepare-portable-runtime.ps1', [StringComparison]::Ordinal)
    ) 'Rebuild must prepare the locked portable runtime.'
    Assert-Contract (
        $rebuild.Contains('Using verified existing runtime:', [StringComparison]::Ordinal) -and
        $rebuild.Contains(
            '-LockedDependencyManifest $lockedDependencyManifest',
            [StringComparison]::Ordinal)
    ) 'Rebuild must reuse only an existing runtime that matches the dependency lock.'
    Assert-Contract (
        $rebuild.Contains('[switch]$CleanBuild', [StringComparison]::Ordinal) -and
        $rebuild.Contains(
            'if (-not $CleanBuild -and',
            [StringComparison]::Ordinal) -and
        $rebuild.Contains(
            "'.clean-dependency-cache'",
            [StringComparison]::Ordinal)
    ) 'CleanBuild must bypass runtime reuse and use an isolated dependency cache.'
    Assert-Contract (
        $rebuild.Contains(
            'CleanBuild cannot be combined with PreparedRuntimeRoot.',
            [StringComparison]::Ordinal) -and
        $rebuild.Contains(
            '-DownloadTimeoutSeconds $DownloadTimeoutSeconds',
            [StringComparison]::Ordinal) -and
        $rebuild.Contains(
            '-DownloadRetryCount $DownloadRetryCount',
            [StringComparison]::Ordinal)
    ) 'CleanBuild must reject prepared runtimes and configure bounded downloads.'
    Assert-Contract (
        $rebuild.Contains('portable-package.marker', [StringComparison]::Ordinal)
    ) 'Rebuild must mark output as a portable package.'
    Assert-Contract (
        $rebuild.Contains('Compress-Archive', [StringComparison]::Ordinal)
    ) 'Rebuild must emit a portable ZIP.'
    Assert-Contract (
        $rebuild.Contains('.zip.sha256', [StringComparison]::Ordinal)
    ) 'Rebuild must emit a ZIP checksum.'
    Assert-Contract (
        $rebuild.Contains('test-artifact-integrity.ps1', [StringComparison]::Ordinal) -and
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'test-artifact-integrity.ps1') -Raw).
            Contains('throw "成果物整合性検証に失敗しました', [StringComparison]::Ordinal)
    ) 'Rebuild must fail closed when the artifact integrity post-condition fails.'

    $installerBuilder = Get-Content `
        -LiteralPath (Join-Path $PSScriptRoot 'build-media-normalizer-installer-package.ps1') `
        -Raw
    Assert-Contract (
        -not $installerBuilder.Contains(
            '_internal\legacy-artifacts',
            [StringComparison]::OrdinalIgnoreCase) -and
        -not $installerBuilder.Contains(
            '-PreparedRuntimeRoot',
            [StringComparison]::Ordinal)
    ) 'Installer package rebuild must not depend on legacy-artifacts.'
    Assert-Contract (
        $installerBuilder.Contains(
            '-Runtime $rid -OutputRoot $project',
            [StringComparison]::Ordinal)
    ) 'Installer package rebuild must use the canonical portable rebuild contract.'

    $prepareRuntime = Get-Content `
        -LiteralPath (Join-Path $PSScriptRoot 'prepare-portable-runtime.ps1') `
        -Raw
    Assert-Contract (
        $prepareRuntime.Contains(
            'New-DependencyWebRequestParameters',
            [StringComparison]::Ordinal) -and
        $prepareRuntime.Contains(
            'Get-Command curl.exe -CommandType Application',
            [StringComparison]::Ordinal) -and
        $prepareRuntime.Contains(
            "'--progress-bar'",
            [StringComparison]::Ordinal) -and
        $prepareRuntime.Contains(
            "'--max-time'",
            [StringComparison]::Ordinal) -and
        $prepareRuntime.Contains(
            'OperationTimeoutSeconds',
            [StringComparison]::Ordinal) -and
        $prepareRuntime.Contains(
            'TimeoutSec',
            [StringComparison]::Ordinal)
    ) 'Dependency downloads must prefer bounded curl and retain a PowerShell 7 fallback.'
    Assert-Contract (
        $prepareRuntime.Contains(
            '$totalAttempts = $DownloadRetryCount + 1',
            [StringComparison]::Ordinal) -and
        $prepareRuntime.Contains(
            'Dependency download failed after $totalAttempts attempts:',
            [StringComparison]::Ordinal)
    ) 'Dependency downloads must retry a bounded number of times and fail clearly.'

    $dependencies = Get-Content `
        -LiteralPath (Join-Path $projectRoot 'portable-dependencies.json') `
        -Raw | ConvertFrom-Json
    Assert-Contract (
        [int]$dependencies.schemaVersion -eq 1
    ) 'Portable dependency manifest schema must be version 1.'
    Assert-Contract (
        [string]$dependencies.ffmpeg.version -eq '8.1.2-31-g8c9502e9b0'
    ) 'FFmpeg must remain pinned to the reviewed build.'
    Assert-Contract (
        [string]$dependencies.python.version -eq '3.13.14'
    ) 'Python must remain pinned to the reviewed embeddable release.'
    Assert-Contract (
        [string]$dependencies.pythonPackages[0].version -eq '1.41.1'
    ) 'ffmpeg-normalize must remain pinned to 1.41.1.'
    foreach ($runtimeName in @('win-x64', 'win-arm64')) {
        $ffmpegRuntime = $dependencies.ffmpeg.runtimes.PSObject.Properties[$runtimeName].Value
        $pythonRuntime = $dependencies.python.runtimes.PSObject.Properties[$runtimeName].Value
        Assert-Contract (
            [string]$ffmpegRuntime.sha256 -match '^[0-9a-f]{64}$'
        ) "FFmpeg $runtimeName SHA-256 must be locked."
        Assert-Contract (
            [string]$pythonRuntime.sha256 -match '^[0-9a-f]{64}$'
        ) "Python $runtimeName SHA-256 must be locked."
    }
}
finally {
    $safeTestRoot = [IO.Path]::GetFullPath($testRoot)
    $safeWorkspaceRoot = [IO.Path]::GetFullPath($workspaceRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar)
    if ($safeTestRoot.StartsWith(
            $safeWorkspaceRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $safeTestRoot) -like 'media-normalizer-build-contract-*' -and
        (Test-Path -LiteralPath $safeTestRoot)) {
        Remove-Item -LiteralPath $safeTestRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host 'Media Normalizer build contract checks passed.' -ForegroundColor Green
exit 0
