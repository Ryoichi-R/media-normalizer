#Requires -Modules Pester

Describe 'Media Normalizer rebuild integration' -Tag 'Integration' {
    BeforeAll {
        $script:projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\'))
        $script:workspaceRoot = [IO.Path]::GetFullPath((Join-Path $script:projectRoot '..\..\'))
        $script:rebuildScript = Join-Path $script:projectRoot `
            'scripts\rebuild-media-normalizer.ps1'
        $script:testRoot = Join-Path $script:workspaceRoot `
            ('TestResults\media-normalizer-rebuild-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:testRoot -Force | Out-Null

        function script:New-TestPeFile {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][UInt16]$Machine
            )

            $bytes = [byte[]]::new(512)
            $bytes[0] = 0x4D
            $bytes[1] = 0x5A
            [BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3c)
            $bytes[0x80] = 0x50
            $bytes[0x81] = 0x45
            [BitConverter]::GetBytes($Machine).CopyTo($bytes, 0x84)
            [IO.File]::WriteAllBytes($Path, $bytes)
        }

        $script:preparedRuntime = Join-Path $script:testRoot 'prepared-runtime'
        $ffmpegBin = Join-Path $script:preparedRuntime 'ffmpeg\bin'
        $pythonRoot = Join-Path $script:preparedRuntime 'python'
        New-Item -ItemType Directory -Path $ffmpegBin, $pythonRoot -Force | Out-Null
        New-TestPeFile -Path (Join-Path $ffmpegBin 'ffmpeg.exe') -Machine 0x8664
        New-TestPeFile -Path (Join-Path $ffmpegBin 'ffprobe.exe') -Machine 0x8664
        New-TestPeFile -Path (Join-Path $pythonRoot 'python.exe') -Machine 0x8664
        [IO.File]::WriteAllText((Join-Path $pythonRoot 'python313.dll'), 'fixture')

        $criticalFiles = foreach ($entry in @(
                @{ Name = 'FFmpeg'; Path = 'ffmpeg/bin/ffmpeg.exe' }
                @{ Name = 'ffprobe'; Path = 'ffmpeg/bin/ffprobe.exe' }
                @{ Name = 'Python'; Path = 'python/python.exe' }
                @{ Name = 'PythonRuntime'; Path = 'python/python313.dll' })) {
            $filePath = Join-Path $script:preparedRuntime $entry.Path
            [ordered]@{
                name = $entry.Name
                path = $entry.Path
                sha256 = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
            }
        }
        $lockedDependencies = Get-Content -LiteralPath (
            Join-Path $script:projectRoot 'portable-dependencies.json'
        ) -Raw | ConvertFrom-Json
        $lockedFfmpegRuntime = $lockedDependencies.ffmpeg.runtimes.PSObject.Properties[
            'win-x64'
        ].Value
        $lockedPythonRuntime = $lockedDependencies.python.runtimes.PSObject.Properties[
            'win-x64'
        ].Value
        $lockedNormalize = $lockedDependencies.pythonPackages |
            Where-Object name -eq 'ffmpeg-normalize' |
            Select-Object -First 1
        [ordered]@{
            schemaVersion = 1
            runtime = 'win-x64'
            ffmpeg = @{
                version = [string]$lockedDependencies.ffmpeg.version
                license = 'test'
                binarySha256 = [string]$lockedFfmpegRuntime.sha256
            }
            python = @{
                version = [string]$lockedDependencies.python.version
                license = 'test'
                binarySha256 = [string]$lockedPythonRuntime.sha256
            }
            ffmpegNormalize = @{
                version = [string]$lockedNormalize.version
                license = 'test'
            }
            pythonPackages = @($lockedDependencies.pythonPackages |
                    ForEach-Object {
                        [ordered]@{
                            name = [string]$_.name
                            version = [string]$_.version
                            license = [string]$_.license
                            sha256 = [string]$_.sha256
                        }
                    })
            criticalFiles = @($criticalFiles)
        } | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath (
                Join-Path $script:preparedRuntime 'dependency-manifest.json'
            ) -Encoding utf8
    }

    AfterAll {
        $safeTestRoot = [IO.Path]::GetFullPath($script:testRoot)
        $safeWorkspaceRoot = [IO.Path]::GetFullPath($script:workspaceRoot).TrimEnd(
            [IO.Path]::DirectorySeparatorChar)
        if ($safeTestRoot.StartsWith(
                $safeWorkspaceRoot + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $safeTestRoot) -like 'media-normalizer-rebuild-*' -and
            (Test-Path -LiteralPath $safeTestRoot)) {
            Remove-Item -LiteralPath $safeTestRoot -Recurse -Force
        }
    }

    It 'creates a verified runtime-specific folder, ZIP, and checksum' {
        & $script:rebuildScript `
            -Runtime win-x64 `
            -OutputRoot $script:testRoot `
            -PreparedRuntimeRoot $script:preparedRuntime

        $packageRoot = Join-Path $script:testRoot `
            'MediaNormalizerBuilds\media-normalizer-win-x64'
        $expectedSourceFiles = @(
            @{ Source = 'assets\presets.json'; Package = 'assets\presets.json' }
            @{ Source = 'diagnostics\diagnose.bat'; Package = 'diagnose.bat' }
            @{ Source = 'diagnostics\diagnose.ps1'; Package = 'diagnose.ps1' }
            @{ Source = 'lib\MediaNormalizer.Core.psm1'; Package = 'lib\MediaNormalizer.Core.psm1' }
            @{ Source = 'lib\MediaNormalizer.Probe.psm1'; Package = 'lib\MediaNormalizer.Probe.psm1' }
            @{ Source = 'lib\MediaNormalizer.Progress.psm1'; Package = 'lib\MediaNormalizer.Progress.psm1' }
            @{ Source = 'lib\MediaNormalizer.Ui.psm1'; Package = 'lib\MediaNormalizer.Ui.psm1' }
            @{ Source = 'scripts\package-templates\media-normalizer.bat'; Package = 'media-normalizer.bat' }
            @{ Source = 'media-normalizer.ps1'; Package = 'media-normalizer.ps1' }
            @{ Source = 'diagnostics\runtime-check.bat'; Package = 'runtime-check.bat' }
            @{ Source = 'diagnostics\runtime-check.ps1'; Package = 'runtime-check.ps1' }
            @{ Source = 'launcher-legacy\runtime-env.bat'; Package = 'runtime-env.bat' }
            @{ Source = 'THIRD-PARTY-NOTICES.md'; Package = 'THIRD-PARTY-NOTICES.md' }
            @{ Source = 'README.md'; Package = 'README.md' }
            @{ Source = 'docs\PORTABLE-DISTRIBUTION.md'; Package = 'docs\PORTABLE-DISTRIBUTION.md' }
        )

        foreach ($entry in $expectedSourceFiles) {
            $source = Join-Path $script:projectRoot $entry.Source
            $packaged = Join-Path $packageRoot $entry.Package
            Test-Path -LiteralPath $packaged -PathType Leaf | Should -BeTrue
            (Get-FileHash -LiteralPath $packaged -Algorithm SHA256).Hash |
                Should -Be (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        }
        foreach ($runtimeFile in @(
                'MediaNormalizer.exe',
                'portable-package.marker',
                'runtime\dependency-manifest.json',
                'runtime\ffmpeg\bin\ffmpeg.exe',
                'runtime\ffmpeg\bin\ffprobe.exe',
                'runtime\python\python.exe',
                'runtime\python\python313.dll')) {
            Test-Path -LiteralPath (Join-Path $packageRoot $runtimeFile) |
                Should -BeTrue
        }

        $zipPath = Join-Path $script:testRoot `
            'MediaNormalizerBuilds\media-normalizer-win-x64.zip'
        $checksumPath = "$zipPath.sha256"
        Test-Path -LiteralPath $zipPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $checksumPath -PathType Leaf | Should -BeTrue
        (Get-Content -LiteralPath $checksumPath -Raw) |
            Should -Match ([regex]::Escape(
                    (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()))
        Test-Path -LiteralPath (Join-Path $packageRoot 'diagnose.log') |
            Should -BeFalse
        Test-Path -LiteralPath (Join-Path $packageRoot 'tmp media test') |
            Should -BeFalse
    }

    It 'reuses a verified existing runtime when the download cache is empty' {
        $externalParent = Join-Path $script:testRoot 'existing-runtime-parent'
        $currentOutput = Join-Path $externalParent `
            'MediaNormalizerBuilds\media-normalizer-win-x64'
        New-Item -ItemType Directory -Path $currentOutput -Force | Out-Null
        Copy-Item `
            -LiteralPath $script:preparedRuntime `
            -Destination (Join-Path $currentOutput 'runtime') `
            -Recurse

        $output = & $script:rebuildScript `
            -Runtime win-x64 `
            -OutputRoot $externalParent 6>&1

        ($output | Out-String) | Should -Match 'Using verified existing runtime:'
        ($output | Out-String) | Should -Not -Match 'Downloading:'
        Test-Path -LiteralPath (
            Join-Path $currentOutput 'media-normalizer.bat'
        ) -PathType Leaf | Should -BeTrue
    }

    It 'rejects a prepared runtime in complete clean build mode' {
        {
            & $script:rebuildScript `
                -Runtime win-x64 `
                -OutputRoot $script:testRoot `
                -PreparedRuntimeRoot $script:preparedRuntime `
                -CleanBuild
        } | Should -Throw '*CleanBuild cannot be combined with PreparedRuntimeRoot*'
    }
}
