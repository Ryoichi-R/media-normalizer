#Requires -Modules Pester

BeforeAll {
    $script:projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    function New-PackageBuildFixture {
        param([string]$Mode='success', [switch]$Fresh)
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $scripts=Join-Path $root 'scripts'
        $payload=Join-Path $root 'installer/payload'
        $null=New-Item -ItemType Directory -Path (Join-Path $scripts 'shared'),$payload -Force
        Copy-Item (Join-Path $script:projectRoot 'scripts/build-media-normalizer-installer-package.ps1') $scripts
        # Replace native PE/privacy boundaries only; exercise the actual packaging script and ZIP I/O.
        [IO.File]::WriteAllText((Join-Path $scripts 'shared/secret-patterns.ps1'), 'function Test-SecretFilePath { param($FilePath); return $false }')
        [IO.File]::WriteAllText((Join-Path $scripts 'shared/app-build-info.ps1'), @'
function Assert-MediaNormalizerPackageBuildInfo {
    param($PackageRoot,$Runtime)
    Get-Content (Join-Path $PackageRoot 'build-info.json') -Raw | ConvertFrom-Json
}
$hashState=@{ManifestReads=0}
function Get-FileHash {
    [CmdletBinding()]
    param([string]$LiteralPath,[string]$Algorithm='SHA256')
    $root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $mode=Get-Content (Join-Path $root 'fixture-mode.txt') -Raw
    if($mode.Trim() -eq 'manifest-verify' -and $LiteralPath -eq (Join-Path $root 'installer/payload/payload-manifest.json')) {
        $hashState.ManifestReads++
        if($hashState.ManifestReads -eq 2){throw 'fixture manifest verification failure'}
    }
    Microsoft.PowerShell.Utility\Get-FileHash @PSBoundParameters
}
'@)
        [IO.File]::WriteAllText((Join-Path $scripts 'test-artifact-integrity.ps1'), @'
param($Runtime,$ArtifactsRoot)
$root=Split-Path $PSScriptRoot -Parent
$mode=(Get-Content (Join-Path $root 'fixture-mode.txt') -Raw).Trim()
if($mode -eq 'gate-failure' -and $Runtime -eq 'win-arm64'){throw 'fixture artifact rejection'}
'@)
        [IO.File]::WriteAllText((Join-Path $scripts 'test-zip-privacy.ps1'), @'
param($ZipPath)
$root=Split-Path $PSScriptRoot -Parent
$mode=(Get-Content (Join-Path $root 'fixture-mode.txt') -Raw).Trim()
$staged=$ZipPath -match '[/\\]\.staging-'
if($ZipPath.EndsWith('win-arm64.zip') -and (($mode -eq 'stage-failure' -and $staged) -or ($mode -eq 'apply-failure' -and -not $staged))) {
    throw 'fixture privacy failure'
}
'@)
        Set-Content (Join-Path $root 'fixture-mode.txt') $Mode
        foreach($rid in @('win-x64','win-arm64')) {
            $package=Join-Path $root "artifacts/media-normalizer-$rid"
            $null=New-Item -ItemType Directory -Path $package -Force
            [IO.File]::WriteAllText((Join-Path $package 'MediaNormalizer.exe'),"synthetic exe $rid")
            @{appName='Media Normalizer';productVersion=$(if($Mode -eq 'mixed-version' -and $rid -eq 'win-arm64'){'1.0.0'}else{'1.1.0'})} |
                ConvertTo-Json | Set-Content (Join-Path $package 'build-info.json')
            if(-not $Fresh) {
                # Valid old ZIP bytes; the old manifest refers to these exact bytes.
                Compress-Archive -Path (Join-Path $package '*') -DestinationPath (Join-Path $payload "MediaNormalizer-$rid.zip")
            }
        }
        if(-not $Fresh) {
            $old=@{}
            Get-ChildItem $payload -File | ForEach-Object { $old[$_.Name]=(Microsoft.PowerShell.Utility\Get-FileHash $_.FullName).Hash }
            $old | ConvertTo-Json | Set-Content (Join-Path $payload 'payload-manifest.json')
        }
        return $root
    }
    function Get-FixtureHashes {
        param([string]$Root)
        return @(Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName | ForEach-Object {
            [IO.Path]::GetRelativePath($Root,$_.FullName)+':'+(Microsoft.PowerShell.Utility\Get-FileHash $_.FullName).Hash
        }) -join "`n"
    }
}

Describe 'Installer package set transaction' {
    It 'keeps every previous payload and canonical package unchanged on <Mode>' -ForEach @(
        @{Mode='mixed-version';ExpectedError='*BUILD_INFO_INSTALLER_PAYLOAD_MISMATCH*'},
        @{Mode='gate-failure';ExpectedError='*fixture artifact rejection*'},
        @{Mode='stage-failure';ExpectedError='*fixture privacy failure*'},
        @{Mode='apply-failure';ExpectedError='*fixture privacy failure*'},
        @{Mode='manifest-verify';ExpectedError='*fixture manifest verification failure*'}) {
        $root=New-PackageBuildFixture -Mode $Mode
        $payload=Join-Path $root 'installer/payload'
        $before=Get-FixtureHashes $payload
        $canonical=Get-FixtureHashes (Join-Path $root 'artifacts')
        { & (Join-Path $root 'scripts/build-media-normalizer-installer-package.ps1') -SkipPortableRebuild } | Should -Throw $ExpectedError
        Get-FixtureHashes $payload | Should -BeExactly $before
        Get-FixtureHashes (Join-Path $root 'artifacts') | Should -BeExactly $canonical
        @(Get-ChildItem $payload -Directory -Force).Count | Should -Be 0
    }
    It 'removes newly applied outputs when a fresh package apply fails' {
        $root=New-PackageBuildFixture -Mode apply-failure -Fresh
        { & (Join-Path $root 'scripts/build-media-normalizer-installer-package.ps1') -SkipPortableRebuild } | Should -Throw '*fixture privacy failure*'
        @(Get-ChildItem (Join-Path $root 'installer/payload') -Force).Count | Should -Be 0
    }
    It 'publishes a consistent set without modifying the canonical packages' {
        $root=New-PackageBuildFixture
        $before=Get-FixtureHashes (Join-Path $root 'artifacts')
        $manifestPath=& (Join-Path $root 'scripts/build-media-normalizer-installer-package.ps1') -SkipPortableRebuild
        $manifest=Get-Content $manifestPath -Raw | ConvertFrom-Json
        $manifest.productVersion | Should -Be '1.1.0'
        foreach($rid in @('win-x64','win-arm64')) {
            $info=$manifest.payloads.$rid
            $archive=Join-Path (Split-Path $manifestPath) $info.archive
            (Get-FileHash $archive).Hash.ToLowerInvariant() | Should -BeExactly $info.sha256
            (Get-Item $archive).Length | Should -Be $info.bytes
            $expanded=Join-Path $root $rid
            Expand-Archive $archive $expanded
            foreach($file in $info.managedFiles) {
                (Get-FileHash (Join-Path $expanded $file.name)).Hash.ToLowerInvariant() | Should -BeExactly $file.sha256
            }
        }
        Get-FixtureHashes (Join-Path $root 'artifacts') | Should -BeExactly $before
        @(Get-ChildItem (Split-Path $manifestPath) -Directory -Force).Count | Should -Be 0
    }
}
