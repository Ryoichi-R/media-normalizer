#Requires -Modules Pester

Set-StrictMode -Version Latest

# Linux runner（および macOS）でも MediaNormalizer.Ui の純粋ロジック関数が
# 触れること、特に Read-Settings が -SettingsPath / -Defaults 注入経路で
# プラットフォーム依存 API（[Environment]::GetFolderPath('MyVideos') 等）
# を一切呼ばずに動作することを契約テストとして固定する。
#
# 背景: review-gate-ci #172 で Read-Settings 内の Get-DefaultInputDir 直接
# 呼び出しが Linux runner で throw し、unit-tests (ubuntu-latest) が exit 1
# になった。本テストは同種の不完全リファクタが再発したら即座に検出する。
#
# 注: WindowsOnly タグは付けない（むしろ非 Windows でも通る前提を担保する）。
Describe 'MediaNormalizer.Ui (Linux portable surface)' {
    BeforeAll {
        $script:libRoot = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib')
    }

    It 'Core / Probe / Progress / Ui を Import-Module しても throw しない' {
        $coreModule  = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Core.psm1')
        $probeModule = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Probe.psm1')
        $progressModule = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Progress.psm1')
        $uiModule    = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Ui.psm1')
        {
            Import-Module $coreModule  -Force -ErrorAction Stop
            Import-Module $probeModule -Force -ErrorAction Stop
            Import-Module $progressModule -Force -ErrorAction Stop
            Import-Module $uiModule    -Force -ErrorAction Stop
        } | Should -Not -Throw
    }

    It 'Read-Settings は -SettingsPath / -Defaults 注入で Linux 上でも throw しない' {
        $coreModule  = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Core.psm1')
        $probeModule = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Probe.psm1')
        $progressModule = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Progress.psm1')
        $uiModule    = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Ui.psm1')
        Import-Module $coreModule  -Force
        Import-Module $probeModule -Force
        Import-Module $progressModule -Force
        Import-Module $uiModule    -Force

        $tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) ("mn-portable-" + [guid]::NewGuid().ToString('N') + '.json')
        $fakeDefaults = @{
            InputDir   = '/tmp/in'
            OutputDir  = '/tmp/out'
            LastPreset = 'デフォルト'
            LastMode   = 'audio'
        }

        # Should -Not -Throw はサブスコープで scriptblock を評価するため、
        # 戻り値は親スコープに代入できない。throw チェックと結果検証は別物として実行する。
        {
            InModuleScope MediaNormalizer.Ui -Parameters @{ p = $tmpPath; d = $fakeDefaults } {
                param($p, $d)
                $null = Read-Settings -SettingsPath $p -Defaults $d
            }
        } | Should -Not -Throw

        $result = InModuleScope MediaNormalizer.Ui -Parameters @{ p = $tmpPath; d = $fakeDefaults } {
            param($p, $d)
            Read-Settings -SettingsPath $p -Defaults $d
        }
        $result.Values.LastMode | Should -Be 'audio'
        $result.Values.InputDir | Should -Be '/tmp/in'
    }

    It 'Save-Settings は -SettingsPath 注入で Linux 上でも throw しない' {
        $uiModule = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Ui.psm1')
        Import-Module $uiModule -Force

        $tmpDir  = Join-Path ([System.IO.Path]::GetTempPath()) ("mn-portable-save-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $tmpPath = Join-Path $tmpDir 'settings.json'
            {
                InModuleScope MediaNormalizer.Ui -Parameters @{ p = $tmpPath } {
                    param($p)
                    Save-Settings -SettingsPath $p -InputDir '/tmp/in' -OutputDir '/tmp/out' -LastPreset 'デフォルト' -LastMode 'audio'
                }
            } | Should -Not -Throw
            Test-Path -LiteralPath $tmpPath | Should -BeTrue
        } finally {
            if (Test-Path -LiteralPath $tmpDir) {
                Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
