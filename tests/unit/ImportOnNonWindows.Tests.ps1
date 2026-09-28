#Requires -Modules Pester

Set-StrictMode -Version Latest

Describe 'Media Normalizer non-Windows portable surface' {
    BeforeAll {
        $script:libRoot = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib')
    }

    It 'Core / Probe / Progress / Ui を Import-Module しても throw しない' {
        $coreModule = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Core.psm1')
        $probeModule = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Probe.psm1')
        $progressModule = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Progress.psm1')
        $uiModule = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Ui.psm1')
        $platformModule = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Platform.psm1')
        {
            Import-Module $coreModule -Force -ErrorAction Stop
            Import-Module $probeModule -Force -ErrorAction Stop
            Import-Module $progressModule -Force -ErrorAction Stop
            Import-Module $platformModule -Force -ErrorAction Stop
            Import-Module $uiModule -Force -ErrorAction Stop
        } | Should -Not -Throw
    }

    It 'Read-Settings は注入path/defaults経由でWindows固有APIを呼ばずに動作する' {
        $coreModule = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Core.psm1')
        $uiModule = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Ui.psm1')
        Import-Module $coreModule -Force
        Import-Module $uiModule -Force
        $tmpPath = Join-Path ([IO.Path]::GetTempPath()) ("mn-portable-" + [guid]::NewGuid().ToString('N') + '.json')
        $fakeDefaults = @{ InputDir = '/Users/test/in'; OutputDir = '/Users/test/out'; LastPreset = 'デフォルト'; LastMode = 'audio' }
        $result = InModuleScope MediaNormalizer.Ui -Parameters @{ p = $tmpPath; d = $fakeDefaults } {
            param($p, $d)
            Read-Settings -SettingsPath $p -Defaults $d
        }
        $result.Values.LastMode | Should -Be 'audio'
        $result.Values.InputDir | Should -Be '/Users/test/in'
    }

    It 'Save-Settings は注入path経由で非Windows上でも動作する' {
        $uiModule = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Ui.psm1')
        Import-Module $uiModule -Force
        $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("mn-portable-save-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $tmpPath = Join-Path $tmpDir 'settings.json'
            InModuleScope MediaNormalizer.Ui -Parameters @{ p = $tmpPath } {
                param($p)
                Save-Settings -SettingsPath $p -InputDir '/Users/test/in' -OutputDir '/Users/test/out' -LastPreset 'デフォルト' -LastMode 'audio'
            }
            Test-Path -LiteralPath $tmpPath | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Platform module resolves platform-specific bundled executable paths' {
        Import-Module (Join-Path $script:libRoot 'MediaNormalizer.Platform.psm1') -Force
        $root = '/portable/media-normalizer/runtime'
        (Get-MediaNormalizerRuntimeExecutablePath -RuntimeRoot $root -Name Python -Platform macOS) |
            Should -Be (Join-Path $root 'python/bin/python3')
        (Get-MediaNormalizerRuntimeExecutablePath -RuntimeRoot $root -Name FFmpeg -Platform Windows) |
            Should -Be (Join-Path $root 'ffmpeg/bin/ffmpeg.exe')
        (Get-MediaNormalizerRuntimeExecutablePath -RuntimeRoot $root -Name PowerShell -Platform macOS) |
            Should -Be (Join-Path $root 'powershell/pwsh')
    }

    It 'Platform module recognizes a thin arm64 Mach-O binary' {
        Import-Module (Join-Path $script:libRoot 'MediaNormalizer.Platform.psm1') -Force
        $path = Join-Path ([IO.Path]::GetTempPath()) ("mn-mach-o-" + [guid]::NewGuid().ToString('N'))
        try {
            $bytes = [byte[]]::new(8)
            $bytes[0] = 0xcf; $bytes[1] = 0xfa; $bytes[2] = 0xed; $bytes[3] = 0xfe
            $bytes[4] = 0x0c; $bytes[5] = 0x00; $bytes[6] = 0x00; $bytes[7] = 0x01
            [IO.File]::WriteAllBytes($path, $bytes)
            Get-MediaNormalizerBinaryArchitecture -Path $path | Should -Be 'arm64'
        } finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Platform module detects the current operating system' {
        Import-Module (Join-Path $script:libRoot 'MediaNormalizer.Platform.psm1') -Force
        Get-MediaNormalizerPlatform | Should -Be 'macOS'
    }
}
