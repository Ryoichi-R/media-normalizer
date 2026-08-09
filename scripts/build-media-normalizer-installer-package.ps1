[CmdletBinding()]
param(
    [ValidateSet('win-x64','win-arm64')][string[]]$Runtime = @('win-x64','win-arm64'),
    [switch]$SkipPortableRebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'shared\secret-patterns.ps1')

$project = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$payloadRoot = Join-Path $project 'installer\payload'
$manifestPath = Join-Path $payloadRoot 'payload-manifest.json'
$privacyScript = Join-Path $PSScriptRoot 'test-zip-privacy.ps1'
foreach ($path in @($project, $payloadRoot, $manifestPath)) {
    if (Test-SecretFilePath -FilePath $path) {
        throw "MEDIA_NORMALIZER_SECRET_PATH_REJECTED: $path"
    }
}
New-Item -Path $payloadRoot -ItemType Directory -Force | Out-Null

$payloads = [ordered]@{}
foreach ($rid in $Runtime) {
    if (-not $SkipPortableRebuild) {
        & (Join-Path $PSScriptRoot 'rebuild-media-normalizer.ps1') `
            -Runtime $rid -OutputRoot $project
        if (-not $?) { throw "Portable rebuild failed: $rid" }
    }

    $package = Join-Path $project "artifacts\media-normalizer-$rid"
    if (-not (Test-Path -LiteralPath $package -PathType Container)) {
        throw "Canonical portable package was not found: $package"
    }
    Copy-Item -LiteralPath (Join-Path $project 'media-normalizer.ps1') `
        -Destination (Join-Path $package 'media-normalizer.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $project 'scripts\package-templates\media-normalizer.bat') `
        -Destination (Join-Path $package 'media-normalizer.bat') -Force
    Copy-Item -Path (Join-Path $project 'lib\*') `
        -Destination (Join-Path $package 'lib') -Recurse -Force
    Copy-Item -Path (Join-Path $project 'assets\*') `
        -Destination (Join-Path $package 'assets') -Recurse -Force
    $launcher = Join-Path $package 'MediaNormalizer.exe'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "Canonical portable package launcher was not found: $launcher"
    }

    $archiveName = "MediaNormalizer-$rid.zip"
    $archive = Join-Path $payloadRoot $archiveName
    $replacementId = [Guid]::NewGuid().ToString('N')
    $stagingArchive = Join-Path $payloadRoot ".staging-$replacementId-$archiveName"
    $replacementBackup = Join-Path $payloadRoot ".rollback-$replacementId-$archiveName"
    $archiveExisted = Test-Path -LiteralPath $archive -PathType Leaf
    $replacementSucceeded = $false
    try {
        Compress-Archive `
            -Path (Join-Path $package '*') `
            -DestinationPath $stagingArchive `
            -CompressionLevel Optimal
        & $privacyScript -ZipPath $stagingArchive | Out-Null
        $stagingHash = (Get-FileHash -LiteralPath $stagingArchive -Algorithm SHA256).Hash

        if ($archiveExisted) {
            [IO.File]::Replace($stagingArchive, $archive, $replacementBackup, $true)
        }
        else {
            Move-Item -LiteralPath $stagingArchive -Destination $archive
        }
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $stagingHash) {
            throw "Installer payload ZIP replacement verification failed: $archiveName"
        }
        & $privacyScript -ZipPath $archive | Out-Null
        $replacementSucceeded = $true
    }
    catch {
        $replacementError = $_
        if (Test-Path -LiteralPath $replacementBackup -PathType Leaf) {
            Copy-Item -LiteralPath $replacementBackup -Destination $archive -Force
            if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $replacementBackup -Algorithm SHA256).Hash) {
                throw "Installer payload rollback verification failed: $archiveName"
            }
        }
        elseif (-not $archiveExisted -and
            (Test-Path -LiteralPath $archive -PathType Leaf)) {
            Remove-Item -LiteralPath $archive -Force
        }
        throw $replacementError
    }
    finally {
        if (Test-Path -LiteralPath $stagingArchive -PathType Leaf) {
            Remove-Item -LiteralPath $stagingArchive -Force
        }
        if ($replacementSucceeded -and
            (Test-Path -LiteralPath $replacementBackup -PathType Leaf)) {
            Remove-Item -LiteralPath $replacementBackup -Force
        }
    }

    $managed = @(Get-ChildItem -LiteralPath $package -File -Recurse | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            name = [IO.Path]::GetRelativePath($package, $_.FullName).Replace('\','/')
            bytes = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $exe = $managed | Where-Object name -eq 'MediaNormalizer.exe'
    $payloads[$rid] = [ordered]@{
        archive = $archiveName
        bytes = (Get-Item -LiteralPath $archive).Length
        sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        peMachine = if ($rid -eq 'win-x64') { 34404 } else { 43620 }
        executableSha256 = $exe.sha256
        managedFiles = $managed
        userOwnedFiles = @()
    }
}

[ordered]@{
    schemaVersion = 1
    productId = 'media-normalizer'
    productName = 'Media Normalizer'
    productVersion = '1.0.0'
    createdAt = (Get-Date).ToUniversalTime().ToString('o')
    payloads = $payloads
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM

Write-Output $manifestPath
