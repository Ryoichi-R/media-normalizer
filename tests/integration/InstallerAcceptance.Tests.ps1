#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:installerSource = Join-Path $script:projectRoot 'installer'
    $script:pwshPath = (Get-Process -Id $PID).Path

    function New-InstallerFixture {
        param(
            [Parameter(Mandatory)][string]$Root,
            [string]$Version = '1.0.0',
            [string]$Content = 'payload-v1'
        )

        $installer = Join-Path $Root 'installer'
        $payloadRoot = Join-Path $installer 'payload'
        $package = Join-Path $Root 'package'
        New-Item -Path $payloadRoot -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $package 'lib') -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:installerSource 'Install-MediaNormalizer.ps1') `
            -Destination $installer
        Copy-Item -LiteralPath (Join-Path $script:installerSource 'MediaNormalizer.Installer.Common.ps1') `
            -Destination $installer

        Set-Content -LiteralPath (Join-Path $package 'MediaNormalizer.exe') `
            -Value $Content -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $package 'lib\payload.txt') `
            -Value "$Content-lib" -Encoding utf8NoBOM

        $managed = @(Get-ChildItem -LiteralPath $package -File -Recurse | Sort-Object FullName | ForEach-Object {
                [ordered]@{
                    name = [IO.Path]::GetRelativePath($package, $_.FullName).Replace('\', '/')
                    bytes = $_.Length
                    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            })
        foreach ($rid in @('win-x64', 'win-arm64')) {
            $archiveName = "MediaNormalizer-$rid.zip"
            $archive = Join-Path $payloadRoot $archiveName
            Compress-Archive -Path (Join-Path $package '*') -DestinationPath $archive -Force
        }
        $payloads = [ordered]@{}
        foreach ($rid in @('win-x64', 'win-arm64')) {
            $archiveName = "MediaNormalizer-$rid.zip"
            $archive = Join-Path $payloadRoot $archiveName
            $payloads[$rid] = [ordered]@{
                archive = $archiveName
                bytes = (Get-Item -LiteralPath $archive).Length
                sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
                managedFiles = $managed
                userOwnedFiles = @()
            }
        }
        [ordered]@{
            schemaVersion = 1
            productId = 'media-normalizer'
            productName = 'Media Normalizer'
            productVersion = $Version
            payloads = $payloads
        } | ConvertTo-Json -Depth 8 | Set-Content `
            -LiteralPath (Join-Path $payloadRoot 'payload-manifest.json') `
            -Encoding utf8NoBOM

        return $installer
    }

    function Invoke-InstallerFixture {
        param(
            [Parameter(Mandatory)][string]$Installer,
            [Parameter(Mandatory)][string]$OutputParent,
            [Parameter(Mandatory)][string]$LocalAppData,
            [ValidateSet('AMD64', 'ARM64')][string]$Architecture = 'AMD64'
        )

        New-Item -Path $OutputParent -ItemType Directory -Force | Out-Null
        New-Item -Path $LocalAppData -ItemType Directory -Force | Out-Null
        $stdout = Join-Path $OutputParent 'installer.stdout.log'
        $stderr = Join-Path $OutputParent 'installer.stderr.log'
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:pwshPath
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        [void]$psi.ArgumentList.Add('-NoProfile')
        [void]$psi.ArgumentList.Add('-File')
        [void]$psi.ArgumentList.Add((Join-Path $Installer 'Install-MediaNormalizer.ps1'))
        [void]$psi.ArgumentList.Add('-OutputRootFromEnvironment')
        [void]$psi.ArgumentList.Add('-NoOpenFolder')
        $psi.Environment['MEDIA_NORMALIZER_OUTPUT_ROOT'] = $OutputParent
        $psi.Environment['LOCALAPPDATA'] = $LocalAppData
        $psi.Environment['PROCESSOR_ARCHITECTURE'] = $Architecture
        $psi.Environment.Remove('PROCESSOR_ARCHITEW6432')

        $process = [Diagnostics.Process]::Start($psi)
        $outText = $process.StandardOutput.ReadToEnd()
        $errText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        Set-Content -LiteralPath $stdout -Value $outText -Encoding utf8NoBOM
        Set-Content -LiteralPath $stderr -Value $errText -Encoding utf8NoBOM
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $outText
            StdErr = $errText
        }
    }

    function Enable-InstallerApplyFailureInjection {
        param([Parameter(Mandatory)][string]$Installer)

        $path = Join-Path $Installer 'Install-MediaNormalizer.ps1'
        $source = Get-Content -LiteralPath $path -Raw
        $needle = 'Copy-Item -LiteralPath $managed.Path -Destination $dst -Force;$applied+=$name'
        $replacement = $needle + ";throw 'Injected apply failure for rollback acceptance.'"
        $updated = $source.Replace($needle, $replacement)
        if ($updated -eq $source) {
            throw 'Installer apply seam for failure injection was not found.'
        }
        Set-Content -LiteralPath $path -Value $updated -Encoding utf8NoBOM
    }
}

Describe 'Media Normalizer installer isolated acceptance' -Tag 'Integration', 'WindowsOnly' -Skip:(-not $IsWindows) {
    It 'installs the current production payload for both architecture routes' -ForEach @(
        @{ Architecture = 'AMD64'; Runtime = 'win-x64'; ManagedCount = 275 },
        @{ Architecture = 'ARM64'; Runtime = 'win-arm64'; ManagedCount = 222 }
    ) {
        $root = Join-Path $TestDrive "production-$Architecture"
        $parent = Join-Path $root 'output'
        $result = Invoke-InstallerFixture -Installer $script:installerSource `
            -OutputParent $parent `
            -LocalAppData (Join-Path $root 'localappdata') `
            -Architecture $Architecture

        $result.ExitCode | Should -Be 0
        $install = Join-Path $parent 'Media Normalizer'
        $marker = Get-Content -LiteralPath (
            Join-Path $install '.media-normalizer-install.json') -Raw | ConvertFrom-Json
        $marker.runtime | Should -Be $Runtime
        @($marker.managedFiles).Count | Should -Be $ManagedCount
        (Get-FileHash -LiteralPath (Join-Path $install 'lib\MediaNormalizer.Core.psm1') `
                -Algorithm SHA256).Hash | Should -Be (
            Get-FileHash -LiteralPath (Join-Path $script:projectRoot 'lib\MediaNormalizer.Core.psm1') `
                -Algorithm SHA256).Hash
    }

    It 'installs a validated payload for both architecture routes' -ForEach @(
        @{ Architecture = 'AMD64'; Runtime = 'win-x64' },
        @{ Architecture = 'ARM64'; Runtime = 'win-arm64' }
    ) {
        $root = Join-Path $TestDrive "install-$Architecture"
        $installer = New-InstallerFixture -Root $root
        $parent = Join-Path $root 'output'
        $result = Invoke-InstallerFixture -Installer $installer -OutputParent $parent `
            -LocalAppData (Join-Path $root 'localappdata') -Architecture $Architecture

        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -Match 'MEDIA_NORMALIZER_INSTALLER:SUCCESS'
        $marker = Get-Content -LiteralPath (
            Join-Path $parent 'Media Normalizer\.media-normalizer-install.json') -Raw | ConvertFrom-Json
        $marker.runtime | Should -Be $Runtime
        Test-Path -LiteralPath (Join-Path $parent 'Media Normalizer\MediaNormalizer.exe') |
            Should -BeTrue
    }

    It 'updates managed files while retaining user-owned files' {
        $root = Join-Path $TestDrive 'update'
        $installer = New-InstallerFixture -Root $root -Version '1.0.0' -Content 'old'
        $parent = Join-Path $root 'output'
        $localAppData = Join-Path $root 'localappdata'
        (Invoke-InstallerFixture -Installer $installer -OutputParent $parent `
                -LocalAppData $localAppData).ExitCode | Should -Be 0
        $install = Join-Path $parent 'Media Normalizer'
        Set-Content -LiteralPath (Join-Path $install 'settings.json') -Value 'user-setting'

        $installer = New-InstallerFixture -Root $root -Version '1.0.1' -Content 'new'
        $result = Invoke-InstallerFixture -Installer $installer -OutputParent $parent `
            -LocalAppData $localAppData

        $result.ExitCode | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $install 'MediaNormalizer.exe') -Raw).Trim() |
            Should -Be 'new'
        (Get-Content -LiteralPath (Join-Path $install 'settings.json') -Raw).Trim() |
            Should -Be 'user-setting'
    }

    It 'rejects a tampered archive without creating an install' {
        $root = Join-Path $TestDrive 'tampered'
        $installer = New-InstallerFixture -Root $root
        $archive = Join-Path $installer 'payload\MediaNormalizer-win-x64.zip'
        [IO.File]::AppendAllText($archive, 'tampered')
        $parent = Join-Path $root 'output'

        $result = Invoke-InstallerFixture -Installer $installer -OutputParent $parent `
            -LocalAppData (Join-Path $root 'localappdata')

        $result.ExitCode | Should -Not -Be 0
        $result.StdOut | Should -Match 'PAYLOAD_ARCHIVE_TAMPERED'
        Test-Path -LiteralPath (Join-Path $parent 'Media Normalizer') | Should -BeFalse
    }

    It 'rejects an unmanaged existing folder without modifying it' {
        $root = Join-Path $TestDrive 'unmanaged'
        $installer = New-InstallerFixture -Root $root
        $parent = Join-Path $root 'output'
        $install = Join-Path $parent 'Media Normalizer'
        New-Item -Path $install -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $install 'user.txt') -Value 'keep'

        $result = Invoke-InstallerFixture -Installer $installer -OutputParent $parent `
            -LocalAppData (Join-Path $root 'localappdata')

        $result.ExitCode | Should -Not -Be 0
        $result.StdOut | Should -Match 'UNMANAGED_INSTALL'
        (Get-Content -LiteralPath (Join-Path $install 'user.txt') -Raw).Trim() | Should -Be 'keep'
    }

    It 'rejects an update while the running lock is held and keeps the marker unchanged' {
        $root = Join-Path $TestDrive 'running'
        $installer = New-InstallerFixture -Root $root
        $parent = Join-Path $root 'output'
        $localAppData = Join-Path $root 'localappdata'
        (Invoke-InstallerFixture -Installer $installer -OutputParent $parent `
                -LocalAppData $localAppData).ExitCode | Should -Be 0
        $install = Join-Path $parent 'Media Normalizer'
        $marker = Join-Path $install '.media-normalizer-install.json'
        $beforeHash = (Get-FileHash -LiteralPath $marker -Algorithm SHA256).Hash
        $lockPath = Join-Path $install '.media-normalizer-running.lock'
        $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            $result = Invoke-InstallerFixture -Installer $installer -OutputParent $parent `
                -LocalAppData $localAppData
        } finally {
            $lock.Dispose()
        }

        $result.ExitCode | Should -Not -Be 0
        $result.StdOut | Should -Match 'APP_RUNNING'
        (Get-FileHash -LiteralPath $marker -Algorithm SHA256).Hash | Should -Be $beforeHash
    }

    It 'restores the previous managed payload when apply fails' {
        $root = Join-Path $TestDrive 'rollback'
        $installer = New-InstallerFixture -Root $root -Content 'old'
        $parent = Join-Path $root 'output'
        $localAppData = Join-Path $root 'localappdata'
        (Invoke-InstallerFixture -Installer $installer -OutputParent $parent `
                -LocalAppData $localAppData).ExitCode | Should -Be 0
        $install = Join-Path $parent 'Media Normalizer'
        $marker = Join-Path $install '.media-normalizer-install.json'
        $beforeMarkerHash = (Get-FileHash -LiteralPath $marker -Algorithm SHA256).Hash
        $installer = New-InstallerFixture -Root $root -Version '1.0.1' -Content 'new'
        Enable-InstallerApplyFailureInjection -Installer $installer
        $lockedTarget = Join-Path $install 'lib\payload.txt'
        $result = Invoke-InstallerFixture -Installer $installer -OutputParent $parent `
            -LocalAppData $localAppData

        $result.ExitCode | Should -Not -Be 0
        $result.StdOut | Should -Match 'APPLY_FAILED_ROLLED_BACK'
        (Get-Content -LiteralPath (Join-Path $install 'MediaNormalizer.exe') -Raw).Trim() |
            Should -Be 'old'
        (Get-Content -LiteralPath $lockedTarget -Raw).Trim() | Should -Be 'old-lib'
        (Get-FileHash -LiteralPath $marker -Algorithm SHA256).Hash | Should -Be $beforeMarkerHash
    }
}
