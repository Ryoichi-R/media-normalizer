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
    $launcher = Join-Path $project "artifacts\launcher\$rid\MediaNormalizer.exe"
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
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "Launcher publish was not found: $launcher"
    }
    Copy-Item -LiteralPath $launcher -Destination (Join-Path $package 'MediaNormalizer.exe') -Force

    $archiveName = "MediaNormalizer-$rid.zip"
    $archive = Join-Path $payloadRoot $archiveName
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    Compress-Archive -Path (Join-Path $package '*') -DestinationPath $archive -CompressionLevel Optimal

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
