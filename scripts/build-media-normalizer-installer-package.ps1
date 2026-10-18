[CmdletBinding()]
param(
    [ValidateSet('win-x64','win-arm64')][string[]]$Runtime = @('win-x64','win-arm64'),
    [switch]$SkipPortableRebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'shared\secret-patterns.ps1')
. (Join-Path $PSScriptRoot 'shared/app-build-info.ps1')

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

if ($Runtime.Count -eq 0 -or @($Runtime | Select-Object -Unique).Count -ne $Runtime.Count) {
    throw 'Installer requires a nonempty set of distinct runtimes.'
}
$packages = [ordered]@{}
$productVersion = $null
$productName = $null
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
    & (Join-Path $PSScriptRoot 'test-artifact-integrity.ps1') -Runtime $rid -ArtifactsRoot (Join-Path $project 'artifacts') | Out-Null
    if (-not $?) { throw 'Installer portable package validation failed.' }
    $info = Assert-MediaNormalizerPackageBuildInfo -PackageRoot $package -Runtime $rid
    if ($productVersion -and ($productVersion -cne $info.productVersion -or $productName -cne $info.appName)) { throw 'BUILD_INFO_INSTALLER_PAYLOAD_MISMATCH' }
    $productVersion = $info.productVersion
    $productName = $info.appName
    $launcher = Join-Path $package 'MediaNormalizer.exe'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "Canonical portable package launcher was not found: $launcher"
    }

    $packages[$rid] = $package
}

# Prepare every archive and the manifest before changing any completed payload.
# Keep verified backups until the entire set has been applied successfully.
$transactionRoot = Join-Path $payloadRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $transactionRoot
$payloads = [ordered]@{}
$replacements = [Collections.Generic.List[object]]::new()
$applied = [Collections.Generic.List[object]]::new()
$cleanupTransaction = $true
try {
    foreach ($rid in $Runtime) {
        $package = $packages[$rid]
        $archiveName = "MediaNormalizer-$rid.zip"
        $stagingArchive = Join-Path $transactionRoot $archiveName
        Compress-Archive -Path (Join-Path $package '*') -DestinationPath $stagingArchive -CompressionLevel Optimal
        & $privacyScript -ZipPath $stagingArchive | Out-Null
        $managed = @(Get-ChildItem -LiteralPath $package -File -Recurse | Sort-Object FullName | ForEach-Object {
            [ordered]@{
                name = [IO.Path]::GetRelativePath($package, $_.FullName).Replace('\','/')
                bytes = $_.Length
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
        $exe = $managed | Where-Object name -eq 'MediaNormalizer.exe'
        $archiveHash = (Get-FileHash -LiteralPath $stagingArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        $payloads[$rid] = [ordered]@{
            archive = $archiveName
            bytes = (Get-Item -LiteralPath $stagingArchive).Length
            sha256 = $archiveHash
            peMachine = if ($rid -eq 'win-x64') { 34404 } else { 43620 }
            executableSha256 = $exe.sha256
            managedFiles = $managed
            userOwnedFiles = @()
        }
        $replacements.Add([pscustomobject]@{ Name=$archiveName; Staged=$stagingArchive; Hash=$archiveHash })
    }
    $stagedManifest = Join-Path $transactionRoot 'payload-manifest.json'
    [ordered]@{
        schemaVersion = 1
        productId = 'media-normalizer'
        productName = $productName
        productVersion = $productVersion
        createdAt = (Get-Date).ToUniversalTime().ToString('o')
        payloads = $payloads
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stagedManifest -Encoding utf8NoBOM
    $replacements.Add([pscustomobject]@{ Name='payload-manifest.json'; Staged=$stagedManifest;
        Hash=(Get-FileHash -LiteralPath $stagedManifest -Algorithm SHA256).Hash.ToLowerInvariant() })

    foreach ($replacement in $replacements) {
        $destination = Join-Path $payloadRoot $replacement.Name
        if (Test-Path -LiteralPath $destination -PathType Container) { throw 'Installer payload destination must be a file.' }
        $existed = Test-Path -LiteralPath $destination -PathType Leaf
        $backup = Join-Path $transactionRoot ('previous-' + $replacement.Name)
        $previousHash = $null
        if ($existed) {
            $previousHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
            Copy-Item -LiteralPath $destination -Destination $backup
            if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ne $previousHash) { throw 'Installer payload backup verification failed.' }
        }
        $replacement | Add-Member -NotePropertyMembers @{ Destination=$destination; Existed=$existed; Backup=$backup; PreviousHash=$previousHash }
    }
    foreach ($replacement in $replacements) {
        # Record the attempt before mutation so a post-replacement failure also rolls back.
        $applied.Add($replacement)
        if ($replacement.Existed) {
            [IO.File]::Replace($replacement.Staged, $replacement.Destination, ($replacement.Backup + '.replaced'), $true)
        } else {
            Move-Item -LiteralPath $replacement.Staged -Destination $replacement.Destination
        }
        if ((Get-FileHash -LiteralPath $replacement.Destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $replacement.Hash) {
            throw 'Installer payload replacement verification failed.'
        }
        if ($replacement.Name -like '*.zip') { & $privacyScript -ZipPath $replacement.Destination | Out-Null }
    }
} catch {
    $replacementError = $_
    $rollbackErrors = @()
    for ($i = $applied.Count - 1; $i -ge 0; $i--) {
        $replacement = $applied[$i]
        try {
            if ($replacement.Existed) {
                Copy-Item -LiteralPath $replacement.Backup -Destination $replacement.Destination -Force
                if ((Get-FileHash -LiteralPath $replacement.Destination -Algorithm SHA256).Hash -ne $replacement.PreviousHash) {
                    throw 'Installer payload rollback verification failed.'
                }
            } elseif (Test-Path -LiteralPath $replacement.Destination -PathType Leaf) {
                Remove-Item -LiteralPath $replacement.Destination -Force
            }
        } catch { $rollbackErrors += $_ }
    }
    if ($rollbackErrors.Count -gt 0) {
        $cleanupTransaction = $false
        throw "Installer payload rollback failed; recovery backups retained: $transactionRoot"
    }
    throw $replacementError
} finally {
    if ($cleanupTransaction -and (Test-Path -LiteralPath $transactionRoot -PathType Container)) {
        Remove-Item -LiteralPath $transactionRoot -Recurse -Force
    }
}
Write-Output $manifestPath
