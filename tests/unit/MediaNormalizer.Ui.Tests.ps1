#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    # MediaNormalizer.Ui の内部関数（Export-ModuleMember で公開していない関数）を
    # テストするため、InModuleScope を必須化する。Core モジュールも先にロードしないと
    # Ui.psm1 が NestedModules で参照する Get-AudioInputExtensions 等が解決できない。
    # Linux runner でも動かすため、パス区切りは [IO.Path]::Combine で正規化する。
    $script:libRoot = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib')
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Core.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Probe.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Ui.psm1')) -Force
}

Describe 'Join-Presets' {
    It 'BasePresets のみの場合は base をそのまま返す' {
        InModuleScope MediaNormalizer.Ui {
            $base = @(
                [pscustomobject]@{ name = 'A'; target = -16.0 },
                [pscustomobject]@{ name = 'B'; target = -23.0 }
            )
            $result = Join-Presets -BasePresets $base -UserPresets @()
            $result.Count | Should -Be 2
            $result[0].name | Should -Be 'A'
            $result[1].name | Should -Be 'B'
        }
    }

    It 'ユーザープリセットの新規追加が末尾に並ぶ' {
        InModuleScope MediaNormalizer.Ui {
            $base = @([pscustomobject]@{ name = 'A'; target = -16.0 })
            $user = @([pscustomobject]@{ name = 'C'; target = -14.0 })
            $result = Join-Presets -BasePresets $base -UserPresets $user
            $result.Count | Should -Be 2
            $result[0].name | Should -Be 'A'
            $result[1].name | Should -Be 'C'
        }
    }

    It '同名ユーザープリセットは base を上書きする' {
        InModuleScope MediaNormalizer.Ui {
            $base = @([pscustomobject]@{ name = 'A'; target = -16.0 })
            $user = @([pscustomobject]@{ name = 'A'; target = -10.0 })
            $result = Join-Presets -BasePresets $base -UserPresets $user
            $result.Count | Should -Be 1
            [double]$result[0].target | Should -Be ([double]-10.0)
        }
    }

    It '空白名のユーザープリセットはスキップする' {
        InModuleScope MediaNormalizer.Ui {
            $base = @([pscustomobject]@{ name = 'A'; target = -16.0 })
            $user = @(
                [pscustomobject]@{ name = '   '; target = -10.0 },
                [pscustomobject]@{ name = 'B'; target = -23.0 }
            )
            $result = Join-Presets -BasePresets $base -UserPresets $user
            $result.Count | Should -Be 2
            $result[1].name | Should -Be 'B'
        }
    }
}

Describe 'ConvertTo-PresetMap' {
    It 'name でキー化される' {
        InModuleScope MediaNormalizer.Ui {
            $presets = @(
                [pscustomobject]@{ name = 'A'; target = -16.0; truePeak = -1.0; bitrate = '192k'; sampleRate = 48000 }
            )
            $map = ConvertTo-PresetMap -PresetList $presets
            $map.ContainsKey('A') | Should -BeTrue
            [double]$map['A'].Target | Should -Be ([double]-16.0)
            $map['A'].Bitrate | Should -Be '192k'
        }
    }

    It '空白を含む name は Trim される' {
        InModuleScope MediaNormalizer.Ui {
            $presets = @(
                [pscustomobject]@{ name = '  X  '; target = -16.0; truePeak = -1.0; bitrate = '128k'; sampleRate = 44100 }
            )
            $map = ConvertTo-PresetMap -PresetList $presets
            $map.ContainsKey('X') | Should -BeTrue
            $map.ContainsKey('  X  ') | Should -BeFalse
        }
    }

    It '空白のみの name はスキップされる' {
        InModuleScope MediaNormalizer.Ui {
            $presets = @(
                [pscustomobject]@{ name = '   '; target = -16.0; truePeak = -1.0; bitrate = '192k'; sampleRate = 48000 },
                [pscustomobject]@{ name = 'OK';  target = -23.0; truePeak = -2.0; bitrate = '256k'; sampleRate = 48000 }
            )
            $map = ConvertTo-PresetMap -PresetList $presets
            $map.Count | Should -Be 1
            $map.ContainsKey('OK') | Should -BeTrue
        }
    }

    It '$null エントリはスキップされる' {
        InModuleScope MediaNormalizer.Ui {
            $presets = @(
                $null,
                [pscustomobject]@{ name = 'OK'; target = -16.0; truePeak = -1.0; bitrate = '192k'; sampleRate = 48000 }
            )
            $map = ConvertTo-PresetMap -PresetList $presets
            $map.Count | Should -Be 1
        }
    }
}

Describe 'Get-FileClassification' {
    BeforeAll {
        $script:classifyTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mn-classify-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:classifyTmpDir -Force | Out-Null
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:classifyTmpDir) {
            Remove-Item -LiteralPath $script:classifyTmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '.mp4 は Audio/Video 両方に含まれる場合 both' {
        $p = Join-Path $script:classifyTmpDir 'a.mp4'
        New-Item -ItemType File -Path $p -Force | Out-Null
        $file = [System.IO.FileInfo]::new($p)
        InModuleScope MediaNormalizer.Ui -Parameters @{ file = $file } {
            param($file)
            $extMap = @{ Audio = @('.mp4', '.mov'); Video = @('.mp4') }
            Get-FileClassification -File $file -ExtMap $extMap | Should -Be 'both'
        }
    }

    It '.mp4 は Audio のみ指定なら audio' {
        $p = Join-Path $script:classifyTmpDir 'b.mp4'
        New-Item -ItemType File -Path $p -Force | Out-Null
        $file = [System.IO.FileInfo]::new($p)
        InModuleScope MediaNormalizer.Ui -Parameters @{ file = $file } {
            param($file)
            $extMap = @{ Audio = @('.mp4', '.mov'); Video = @() }
            Get-FileClassification -File $file -ExtMap $extMap | Should -Be 'audio'
        }
    }

    It '.mov は Audio に含まれる場合 audio' {
        $p = Join-Path $script:classifyTmpDir 'c.mov'
        New-Item -ItemType File -Path $p -Force | Out-Null
        $file = [System.IO.FileInfo]::new($p)
        InModuleScope MediaNormalizer.Ui -Parameters @{ file = $file } {
            param($file)
            $extMap = @{ Audio = @('.mp4', '.mov'); Video = @('.mp4') }
            Get-FileClassification -File $file -ExtMap $extMap | Should -Be 'audio'
        }
    }

    It '対象外拡張子は none' {
        $p = Join-Path $script:classifyTmpDir 'd.zip'
        New-Item -ItemType File -Path $p -Force | Out-Null
        $file = [System.IO.FileInfo]::new($p)
        InModuleScope MediaNormalizer.Ui -Parameters @{ file = $file } {
            param($file)
            $extMap = @{ Audio = @('.mp4', '.mov'); Video = @('.mp4') }
            Get-FileClassification -File $file -ExtMap $extMap | Should -Be 'none'
        }
    }
}

Describe 'Read-Settings' {
    # テストは -SettingsPath / -Defaults を明示注入する。これにより Linux runner
    # でも Get-SettingsPath / Get-LegacyAutoInputDir / Get-LegacyAutoOutputDir
    # が評価されず、プラットフォーム前提から独立したロジック検証になる。
    BeforeEach {
        $script:settingsDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mn-settings-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:settingsDir -Force | Out-Null
        $script:settingsPath = Join-Path $script:settingsDir 'settings.json'
        $script:fakeDefaults = @{
            InputDir   = 'C:\test\default-in'
            OutputDir  = 'C:\test\default-out'
            LastPreset = 'デフォルト'
            LastMode   = 'audio'
        }
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:settingsDir) {
            Remove-Item -LiteralPath $script:settingsDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'settings.json が無い初回起動は入力・出力フォルダを未指定にする' {
        InModuleScope MediaNormalizer.Ui -Parameters @{ p = $script:settingsPath } {
            param($p)
            $r = Read-Settings -SettingsPath $p
            $r.Values.InputDir | Should -Be ''
            $r.Values.OutputDir | Should -Be ''
            $r.Values.LastMode | Should -Be 'audio'
            $r.Warnings | Should -BeNullOrEmpty
        }
    }

    It 'settings.json が無い場合は明示注入された既定値を返す' {
        InModuleScope MediaNormalizer.Ui -Parameters @{ p = $script:settingsPath; d = $script:fakeDefaults } {
            param($p, $d)
            $r = Read-Settings -SettingsPath $p -Defaults $d
            $r.Values.LastMode | Should -Be 'audio'
            $r.Values.InputDir | Should -Be 'C:\test\default-in'
            $r.Warnings | Should -BeNullOrEmpty
        }
    }

    It '不正な JSON は既定値 + warning' {
        InModuleScope MediaNormalizer.Ui -Parameters @{ p = $script:settingsPath; d = $script:fakeDefaults } {
            param($p, $d)
            Set-Content -LiteralPath $p -Value '{not-json' -Encoding UTF8
            $r = Read-Settings -SettingsPath $p -Defaults $d
            $r.Values.LastMode | Should -Be 'audio'
            ($r.Warnings -join "`n") | Should -Match 'settings\.json の解析に失敗'
        }
    }

    It 'version 欠落は既定値 + warning' {
        InModuleScope MediaNormalizer.Ui -Parameters @{ p = $script:settingsPath; d = $script:fakeDefaults } {
            param($p, $d)
            '{"inputDir":"C:\\foo"}' | Set-Content -LiteralPath $p -Encoding UTF8
            $r = Read-Settings -SettingsPath $p -Defaults $d
            $r.Values.InputDir | Should -Not -Be 'C:\foo'
            $r.Values.InputDir | Should -Be 'C:\test\default-in'
            ($r.Warnings -join "`n") | Should -Match 'version が無い'
        }
    }

    It '未知の version は既定値 + warning' {
        InModuleScope MediaNormalizer.Ui -Parameters @{ p = $script:settingsPath; d = $script:fakeDefaults } {
            param($p, $d)
            '{"version":99,"inputDir":"C:\\foo","lastMode":"video"}' | Set-Content -LiteralPath $p -Encoding UTF8
            $r = Read-Settings -SettingsPath $p -Defaults $d
            $r.Values.LastMode | Should -Be 'audio'
            ($r.Warnings -join "`n") | Should -Match 'version=99'
        }
    }

    It '正常な v1 のユーザー指定値は後方互換で反映する' {
        InModuleScope MediaNormalizer.Ui -Parameters @{ p = $script:settingsPath; d = $script:fakeDefaults } {
            param($p, $d)
            $payload = @{
                version    = 1
                inputDir   = 'C:\videos\in'
                outputDir  = 'C:\videos\out'
                lastPreset = 'YouTube向け'
                lastMode   = 'both'
            } | ConvertTo-Json
            Set-Content -LiteralPath $p -Value $payload -Encoding UTF8
            $r = Read-Settings -SettingsPath $p -Defaults $d
            $r.Values.InputDir   | Should -Be 'C:\videos\in'
            $r.Values.OutputDir  | Should -Be 'C:\videos\out'
            $r.Values.LastPreset | Should -Be 'YouTube向け'
            $r.Values.LastMode   | Should -Be 'both'
            $r.Warnings | Should -BeNullOrEmpty
        }
    }

    It 'v1 が自動保存した旧既定フォルダは未指定へ移行する' {
        InModuleScope MediaNormalizer.Ui -Parameters @{
            p = $script:settingsPath
            legacy = @{
                InputDir  = 'C:\Users\test\Videos\pre-normalization data'
                OutputDir = 'C:\Users\test\Videos\normalization data'
            }
        } {
            param($p, $legacy)
            $payload = @{
                version    = 1
                inputDir   = $legacy.InputDir
                outputDir  = $legacy.OutputDir
                lastPreset = 'ポッドキャスト'
                lastMode   = 'both'
            } | ConvertTo-Json
            Set-Content -LiteralPath $p -Value $payload -Encoding UTF8

            $r = Read-Settings -SettingsPath $p -LegacyAutoDefaults $legacy

            $r.Values.InputDir   | Should -Be ''
            $r.Values.OutputDir  | Should -Be ''
            $r.Values.LastPreset | Should -Be 'ポッドキャスト'
            $r.Values.LastMode   | Should -Be 'both'
        }
    }
}

Describe 'Save-Settings' {
    BeforeEach {
        $script:saveDir  = Join-Path ([System.IO.Path]::GetTempPath()) ("mn-save-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:saveDir -Force | Out-Null
        $script:savePath = Join-Path $script:saveDir 'settings.json'
    }
    AfterEach {
        if ($script:saveDir -and (Test-Path -LiteralPath $script:saveDir)) {
            Remove-Item -LiteralPath $script:saveDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '既存ディレクトリに JSON を書き込む' {
        InModuleScope MediaNormalizer.Ui -Parameters @{ p = $script:savePath } {
            param($p)
            Save-Settings -SettingsPath $p -InputDir 'C:\in' -OutputDir 'C:\out' -LastPreset 'デフォルト' -LastMode 'audio'
            Test-Path -LiteralPath $p | Should -BeTrue
            $json = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.version    | Should -Be 2
            $json.inputDir   | Should -Be 'C:\in'
            $json.outputDir  | Should -Be 'C:\out'
            $json.lastMode   | Should -Be 'audio'

            $loaded = Read-Settings -SettingsPath $p
            $loaded.Values.InputDir  | Should -Be 'C:\in'
            $loaded.Values.OutputDir | Should -Be 'C:\out'
        }
    }

    It '親ディレクトリが無い場合は自動作成して書き込む' {
        $nestedDir  = Join-Path $script:saveDir 'sub'
        $nestedPath = Join-Path $nestedDir 'settings.json'
        InModuleScope MediaNormalizer.Ui -Parameters @{ p = $nestedPath; d = $nestedDir } {
            param($p, $d)
            Save-Settings -SettingsPath $p -InputDir 'C:\in' -OutputDir 'C:\out' -LastPreset 'X' -LastMode 'video'
            Test-Path -LiteralPath $d | Should -BeTrue
            Test-Path -LiteralPath $p | Should -BeTrue
        }
    }

    It '書き込み失敗時に State.LogBuffer に [WARN ] を残す' {
        InModuleScope MediaNormalizer.Ui -Parameters @{ p = $script:savePath } {
            param($p)
            Mock -CommandName Set-Content -ModuleName MediaNormalizer.UiLogic -MockWith { throw 'simulated write failure' }

            $state = [pscustomobject]@{
                LogBuffer = New-Object System.Text.StringBuilder
                Controls  = @{ TxtLog = $null }
            }
            Save-Settings -SettingsPath $p -InputDir 'C:\in' -OutputDir 'C:\out' -LastPreset 'x' -LastMode 'audio' -State $state
            $state.LogBuffer.ToString() | Should -Match '\[WARN \] settings\.json 保存失敗'
        }
    }

    It 'State 未指定なら例外を投げず黙ってスキップ（後方互換）' {
        InModuleScope MediaNormalizer.Ui -Parameters @{ p = $script:savePath } {
            param($p)
            Mock -CommandName Set-Content -ModuleName MediaNormalizer.UiLogic -MockWith { throw 'simulated write failure' }

            { Save-Settings -SettingsPath $p -InputDir 'C:\in' -OutputDir 'C:\out' -LastPreset 'x' -LastMode 'audio' } |
                Should -Not -Throw
        }
    }
}

Describe 'Get-ConstrainedFormBounds' {
    It '小さい副画面の作業領域内へ収めて中央配置する' {
        $desired = [pscustomobject]@{ Width = 1067; Height = 1415 }
        $area = [pscustomobject]@{ Left = 1920; Top = 80; Width = 800; Height = 600 }

        $result = InModuleScope MediaNormalizer.Ui -Parameters @{ d = $desired; a = $area } {
            param($d, $a)
            Get-ConstrainedFormBounds -DesiredSize $d -WorkingArea $a
        }

        $result.Width | Should -Be 776
        $result.Height | Should -Be 576
        $result.X | Should -Be 1932
        $result.Y | Should -Be 92
        ($result.X + $result.Width) | Should -BeLessOrEqual ($area.Left + $area.Width)
        ($result.Y + $result.Height) | Should -BeLessOrEqual ($area.Top + $area.Height)
    }

    It '320px未満の作業領域でも固定下限を適用せず領域内に収める' {
        $desired = [pscustomobject]@{ Width = 620; Height = 836 }
        $area = [pscustomobject]@{ Left = -200; Top = 0; Width = 200; Height = 180 }

        $result = InModuleScope MediaNormalizer.Ui -Parameters @{ d = $desired; a = $area } {
            param($d, $a)
            Get-ConstrainedFormBounds -DesiredSize $d -WorkingArea $a
        }

        $result.Width | Should -Be 176
        $result.Height | Should -Be 156
        $result.Width | Should -BeLessOrEqual $area.Width
        $result.Height | Should -BeLessOrEqual $area.Height
    }
}

Describe 'New-MainForm DPI scaling' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
    It 'DPIに合わせて固定座標を拡大し、画面内でスクロール可能にする' {
        $state = New-MediaNormalizerState
        $state = Initialize-UiState -State $state
        $form = $null
        try {
            $form = New-MainForm -State $state

            $form.AutoScaleMode.ToString() | Should -Be 'Dpi'
            $form.AutoScroll | Should -BeTrue

            $inputLabel = $form.Controls |
                Where-Object {
                    $_ -is [System.Windows.Forms.Label] -and
                    $_.Text -like '入力ファイル / フォルダ*'
                } |
                Select-Object -First 1
            $inputLabel | Should -Not -BeNullOrEmpty

            $dpiScale = [double]$form.DeviceDpi / 96.0
            $expectedLeft = [math]::Round(12 * $dpiScale)
            $expectedWidth = 400 * $dpiScale
            $widthTolerance = [math]::Ceiling(4 * $dpiScale)
            $state.Controls.TxtInput.Left | Should -Be $expectedLeft
            [math]::Abs($state.Controls.TxtInput.Width - $expectedWidth) |
                Should -BeLessOrEqual $widthTolerance
            $inputLabel.Bottom | Should -BeLessOrEqual ($state.Controls.TxtInput.Top + 1)

            # DataGridViewColumn.Width はフォームのAutoScale対象外なので、固定列は
            # DeviceDpiに合わせて明示的に拡大し、ファイル名列で残り幅を埋める。
            $grid = $state.Controls.Dgv
            $grid.Columns['FileName'].AutoSizeMode.ToString() | Should -Be 'Fill'
            $grid.Columns['FileName'].MinimumWidth | Should -Be ([math]::Round(190 * $dpiScale))
            [math]::Abs($grid.Columns['Audio'].Width - [math]::Round(42 * $dpiScale)) |
                Should -BeLessOrEqual 1
            [math]::Abs($grid.Columns['Size'].Width - [math]::Round(70 * $dpiScale)) |
                Should -BeLessOrEqual 1

            $visibleWidth = ($grid.Columns |
                Where-Object Visible |
                Measure-Object -Property Width -Sum).Sum
            $visibleWidth | Should -BeGreaterOrEqual ($grid.ClientSize.Width - [math]::Ceiling(4 * $dpiScale))

            $targetScreen = [System.Windows.Forms.Screen]::FromRectangle($form.Bounds)
            $workingArea = $targetScreen.WorkingArea
            $form.Width | Should -BeLessOrEqual $workingArea.Width
            $form.Height | Should -BeLessOrEqual $workingArea.Height

            # クランプで高さが縮んだ場合でも、AutoScroll の表示領域が末尾のログ欄まで
            # 拡張され、すべてのコントロールへ到達できることを確認する。
            $form.Size = [System.Drawing.Size]::new(
                [math]::Min($form.Width, 500),
                [math]::Min($form.Height, 500))
            $null = $form.Handle
            $form.PerformLayout()
            $form.DisplayRectangle.Height | Should -BeGreaterThan $form.ClientSize.Height
            $state.Controls.TxtLog.Bottom | Should -BeLessOrEqual $form.DisplayRectangle.Height
        } finally {
            if ($state.LogTimer) {
                $state.LogTimer.Stop()
                $state.LogTimer.Dispose()
                $state.LogTimer = $null
            }
            if ($null -ne $form) { $form.Dispose() }
        }
    }

    It '指定DPIで固定列を拡大し、ファイル名列を残り幅へ割り当てる' {
        $state = New-MediaNormalizerState
        $state = Initialize-UiState -State $state
        $form = $null
        try {
            $form = New-MainForm -State $state

            InModuleScope MediaNormalizer.Ui -Parameters @{ grid = $state.Controls.Dgv } {
                param($grid)
                Set-FileGridColumnLayout -DataGridView $grid -Dpi 144
            }

            $state.Controls.Dgv.Columns['Audio'].Width | Should -Be 63
            $state.Controls.Dgv.Columns['Video'].Width | Should -Be 63
            $state.Controls.Dgv.Columns['Ext'].Width | Should -Be 82
            $state.Controls.Dgv.Columns['Size'].Width | Should -Be 105
            $state.Controls.Dgv.Columns['Duration'].Width | Should -Be 93
            $state.Controls.Dgv.Columns['SpeedPercent'].Width | Should -Be 105
            $state.Controls.Dgv.Columns['FileName'].MinimumWidth | Should -Be 285
            $state.Controls.Dgv.Columns['FileName'].AutoSizeMode.ToString() | Should -Be 'Fill'
        } finally {
            if ($state.LogTimer) {
                $state.LogTimer.Stop()
                $state.LogTimer.Dispose()
                $state.LogTimer = $null
            }
            if ($null -ne $form) { $form.Dispose() }
        }
    }
}
