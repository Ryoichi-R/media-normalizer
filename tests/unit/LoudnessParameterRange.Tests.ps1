#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:libRoot = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib')
    $script:projectRoot = [IO.Path]::Combine($PSScriptRoot, '..', '..')
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Probe.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Progress.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Core.psm1')) -Force
}

AfterAll {
    Remove-Module MediaNormalizer.Core -Force -ErrorAction SilentlyContinue
    Remove-Module MediaNormalizer.Progress -Force -ErrorAction SilentlyContinue
    Remove-Module MediaNormalizer.Probe -Force -ErrorAction SilentlyContinue
}

Describe 'Get-LoudnessParameterRange' {
    It 'Target の範囲は [-70.0, -5.0] を返す' {
        $range = Get-LoudnessParameterRange -Name 'Target'
        $range.Min | Should -Be ([double]-70.0)
        $range.Max | Should -Be ([double]-5.0)
    }

    It 'TruePeak の範囲は [-9.0, 0.0] を返す' {
        $range = Get-LoudnessParameterRange -Name 'TruePeak'
        $range.Min | Should -Be ([double]-9.0)
        $range.Max | Should -Be ([double]0.0)
    }
}

Describe 'Test-LoudnessParameter 境界値 (AC-1 相当のロジック検証)' {
    It '境界値 -70.0 / -5.0 / -9.0 / 0.0 は有効' {
        (Test-LoudnessParameter -Target -70.0 -TruePeak -9.0).IsValid | Should -BeTrue
        (Test-LoudnessParameter -Target -5.0 -TruePeak 0.0).IsValid | Should -BeTrue
    }

    It '境界外側 -70.1 / -4.9 / -9.1 / 0.1 は無効' {
        (Test-LoudnessParameter -Target -70.1 -TruePeak -1.0).IsValid | Should -BeFalse
        (Test-LoudnessParameter -Target -4.9 -TruePeak -1.0).IsValid | Should -BeFalse
        (Test-LoudnessParameter -Target -16.0 -TruePeak -9.1).IsValid | Should -BeFalse
        (Test-LoudnessParameter -Target -16.0 -TruePeak 0.1).IsValid | Should -BeFalse
    }

    It '範囲外Targetのエラーメッセージは範囲を明示する' {
        $result = Test-LoudnessParameter -Target -3.0 -TruePeak -1.0
        $result.IsValid | Should -BeFalse
        ($result.Errors -join "`n") | Should -Match '-70'
        ($result.Errors -join "`n") | Should -Match '-5'
    }

    It 'NaN / +Infinity / -Infinity は無効' {
        (Test-LoudnessParameter -Target ([double]::NaN) -TruePeak -1.0).IsValid | Should -BeFalse
        (Test-LoudnessParameter -Target ([double]::PositiveInfinity) -TruePeak -1.0).IsValid | Should -BeFalse
        (Test-LoudnessParameter -Target ([double]::NegativeInfinity) -TruePeak -1.0).IsValid | Should -BeFalse
        (Test-LoudnessParameter -Target -16.0 -TruePeak ([double]::NaN)).IsValid | Should -BeFalse
        (Test-LoudnessParameter -Target -16.0 -TruePeak ([double]::PositiveInfinity)).IsValid | Should -BeFalse
        (Test-LoudnessParameter -Target -16.0 -TruePeak ([double]::NegativeInfinity)).IsValid | Should -BeFalse
    }

    It '両方とも範囲内なら有効' {
        (Test-LoudnessParameter -Target -16.0 -TruePeak -1.0).IsValid | Should -BeTrue
    }
}

Describe 'Get-MediaLoudnessAnalysis の loudnorm フィルタ (AC-5 / 事実 3)' {
    BeforeEach {
        Mock -ModuleName MediaNormalizer.Core Resolve-MediaNormalizerExecutable { param($Name) $Name.ToLowerInvariant() }
        $script:probeTempFile = [IO.Path]::GetTempFileName()
    }

    AfterEach {
        Remove-Item -LiteralPath $script:probeTempFile -Force -ErrorAction SilentlyContinue
    }

    It '組み立てフィルタに I= / TP= / LRA= を含まない' {
        Mock -ModuleName MediaNormalizer.Core Invoke-MediaNormalizerProcess {
            param($FilePath, $Arguments)
            if ($FilePath -eq 'ffprobe') {
                return [pscustomobject]@{
                    ExitCode   = 0
                    StdoutText = '{"streams":[{"index":0,"codec_type":"audio"}],"format":{}}'
                    StderrText = ''
                }
            }
            $script:capturedArgs = $Arguments
            return [pscustomobject]@{
                ExitCode   = 0
                StdoutText = ''
                StderrText = '{"input_i":"-20.0","input_tp":"-3.0","input_lra":"5.0","input_thresh":"-30.0"}'
            }
        }

        $state = New-MediaNormalizerState
        # 範囲外の値を渡しても、解析自体はI/TPを使わないため成功する（AC-5）。
        $analysis = Get-MediaLoudnessAnalysis -FilePath $script:probeTempFile -Target -3.0 -TruePeak 5.0 -State $state

        $analysis.Streams.Count | Should -Be 1
        $filterArg = $script:capturedArgs[($script:capturedArgs.IndexOf('-af')) + 1]
        $filterArg | Should -Be 'loudnorm=print_format=json'
        $filterArg | Should -Not -Match 'I='
        $filterArg | Should -Not -Match 'TP='
        $filterArg | Should -Not -Match 'LRA='
    }

    It '返却オブジェクトに TargetOffset を含まない（設計判断4）' {
        Mock -ModuleName MediaNormalizer.Core Invoke-MediaNormalizerProcess {
            param($FilePath)
            if ($FilePath -eq 'ffprobe') {
                return [pscustomobject]@{
                    ExitCode   = 0
                    StdoutText = '{"streams":[{"index":0,"codec_type":"audio"}],"format":{}}'
                    StderrText = ''
                }
            }
            return [pscustomobject]@{
                ExitCode   = 0
                StdoutText = ''
                StderrText = '{"input_i":"-20.0","input_tp":"-3.0","input_lra":"5.0","input_thresh":"-30.0","target_offset":"4.0"}'
            }
        }

        $state = New-MediaNormalizerState
        $analysis = Get-MediaLoudnessAnalysis -FilePath $script:probeTempFile -Target -16.0 -TruePeak -1.0 -State $state

        $analysis.Streams[0].PSObject.Properties['TargetOffset'] | Should -BeNullOrEmpty
        $analysis.Streams[0].Threshold | Should -Be '-30.0'
    }

    It '複数音声ストリームでも全ストリーム分が I=/TP=/LRA= 無しのフィルタで解析される（事実3）' {
        $capturedFilters = [Collections.Generic.List[string]]::new()
        Mock -ModuleName MediaNormalizer.Core Invoke-MediaNormalizerProcess {
            param($FilePath, $Arguments)
            if ($FilePath -eq 'ffprobe') {
                return [pscustomobject]@{
                    ExitCode   = 0
                    StdoutText = '{"streams":[{"index":0,"codec_type":"audio"},{"index":1,"codec_type":"audio"},{"index":2,"codec_type":"audio"}],"format":{}}'
                    StderrText = ''
                }
            }
            $filterArg = $Arguments[($Arguments.IndexOf('-af')) + 1]
            $script:capturedFilters.Add($filterArg)
            return [pscustomobject]@{
                ExitCode   = 0
                StdoutText = ''
                StderrText = '{"input_i":"-20.0","input_tp":"-3.0","input_lra":"5.0","input_thresh":"-30.0"}'
            }
        }
        $script:capturedFilters = $capturedFilters

        $state = New-MediaNormalizerState
        $analysis = Get-MediaLoudnessAnalysis -FilePath $script:probeTempFile -Target -16.0 -TruePeak -1.0 -State $state

        $analysis.Streams.Count | Should -Be 3
        $capturedFilters.Count | Should -Be 3
        foreach ($filterArg in $capturedFilters) {
            $filterArg | Should -Be 'loudnorm=print_format=json'
        }
    }
}

Describe 'Invoke-Normalize 範囲外ラウドネスパラメータの入口拒否 (AC-4)' {
    BeforeEach {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mn-range-' + [guid]::NewGuid().ToString('N'))
        $script:inDir = Join-Path $script:tmpRoot 'in'
        $script:outDir = Join-Path $script:tmpRoot 'out'
        New-Item -ItemType Directory -Path $script:inDir, $script:outDir -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '範囲外Targetでは外部プロセスを1つも起動せずFail=1を返す' {
        Mock -ModuleName MediaNormalizer.Core Find-FfmpegNormalize { }
        Mock -ModuleName MediaNormalizer.Core Invoke-MediaNormalizerProcess { }
        Mock -ModuleName MediaNormalizer.Core Get-Command { $null }

        $state = New-MediaNormalizerState
        $logs = [Collections.Generic.List[string]]::new()
        $result = Invoke-Normalize `
            -State $state `
            -Mode audio `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -3.0 `
            -TruePeak -1.0 `
            -Bitrate '192k' `
            -SampleRate '48000' `
            -CollisionPolicy rename `
            -Logger { param($m) $logs.Add($m) | Out-Null }

        $result.Fail | Should -Be 1
        $result.Success | Should -Be 0
        ($logs -join "`n") | Should -Match '\-70'
        ($logs -join "`n") | Should -Match '\-5'
        Should -Invoke Find-FfmpegNormalize -ModuleName MediaNormalizer.Core -Times 0
        Should -Invoke Invoke-MediaNormalizerProcess -ModuleName MediaNormalizer.Core -Times 0
    }

    It '範囲外TruePeakでも同様に外部プロセスを起動せずFail=1を返す' {
        Mock -ModuleName MediaNormalizer.Core Find-FfmpegNormalize { }
        Mock -ModuleName MediaNormalizer.Core Invoke-MediaNormalizerProcess { }

        $state = New-MediaNormalizerState
        $result = Invoke-Normalize `
            -State $state `
            -Mode audio `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -16.0 `
            -TruePeak 5.0 `
            -Bitrate '192k' `
            -SampleRate '48000' `
            -CollisionPolicy rename `
            -Logger { param($m) }

        $result.Fail | Should -Be 1
        Should -Invoke Find-FfmpegNormalize -ModuleName MediaNormalizer.Core -Times 0
        Should -Invoke Invoke-MediaNormalizerProcess -ModuleName MediaNormalizer.Core -Times 0
    }

    It '-AnalyzeOnly でも範囲外値は拒否される (AC-4 は AnalyzeOnly も対象)' {
        Mock -ModuleName MediaNormalizer.Core Invoke-MediaNormalizerProcess { }

        $state = New-MediaNormalizerState
        $result = Invoke-Normalize `
            -State $state `
            -Mode audio `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -3.0 `
            -TruePeak -1.0 `
            -Bitrate '192k' `
            -SampleRate '48000' `
            -CollisionPolicy rename `
            -AnalyzeOnly `
            -Logger { param($m) }

        $result.Fail | Should -Be 1
        Should -Invoke Invoke-MediaNormalizerProcess -ModuleName MediaNormalizer.Core -Times 0
    }

    It '範囲内なら入口検証を通過する（外部プロセスはMockで模擬）' {
        Mock -ModuleName MediaNormalizer.Core Find-FfmpegNormalize { [pscustomobject]@{ Cmd = 'ffmpeg-normalize'; Args = @() } }
        Mock -ModuleName MediaNormalizer.Core Get-Command { [pscustomobject]@{ Source = 'fake' } }
        Mock -ModuleName MediaNormalizer.Platform Get-Command {
            param($Name)
            [pscustomobject]@{ Source = $Name }
        }
        Mock -ModuleName MediaNormalizer.Core Invoke-MediaNormalizerProcess {
            param($FilePath)
            if ($FilePath -eq 'ffprobe') {
                return [pscustomobject]@{
                    ExitCode   = 0
                    StdoutText = '{"streams":[{"index":0,"codec_type":"audio"}],"format":{}}'
                    StderrText = ''
                }
            }
            return [pscustomobject]@{ ExitCode = 0; StdoutText = ''; StderrText = '{"input_i":"-16.0","input_tp":"-1.0","input_lra":"5.0","input_thresh":"-30.0"}' }
        }

        $dummyFile = Join-Path $script:inDir 'sample.wav'
        Set-Content -LiteralPath $dummyFile -Value 'fixture'

        $state = New-MediaNormalizerState
        $result = Invoke-Normalize `
            -State $state `
            -Mode audio `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -16.0 `
            -TruePeak -1.0 `
            -Bitrate '192k' `
            -SampleRate '48000' `
            -CollisionPolicy rename `
            -TargetFiles @((Get-Item -LiteralPath $dummyFile)) `
            -AnalyzeOnly `
            -Logger { param($m) }

        Should -Invoke Invoke-MediaNormalizerProcess -ModuleName MediaNormalizer.Core -Times 1
    }
}

Describe 'Invoke-Normalize -AnalyzeOnly と Get-MediaLoudnessAnalysis 直接呼出しの違い (AC-5)' {
    BeforeEach {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mn-range-direct-' + [guid]::NewGuid().ToString('N'))
        $script:inDir = Join-Path $script:tmpRoot 'in'
        $script:outDir = Join-Path $script:tmpRoot 'out'
        New-Item -ItemType Directory -Path $script:inDir, $script:outDir -Force | Out-Null
        $script:probeTempFile = [IO.Path]::GetTempFileName()
    }

    AfterEach {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:probeTempFile -Force -ErrorAction SilentlyContinue
    }

    It 'Invoke-Normalize -AnalyzeOnly は範囲外値を拒否するが、Get-MediaLoudnessAnalysis の直接呼出しは同じ値でも解析できる' {
        Mock -ModuleName MediaNormalizer.Core Resolve-MediaNormalizerExecutable { param($Name) $Name.ToLowerInvariant() }
        Mock -ModuleName MediaNormalizer.Core Invoke-MediaNormalizerProcess {
            param($FilePath)
            if ($FilePath -eq 'ffprobe') {
                return [pscustomobject]@{
                    ExitCode   = 0
                    StdoutText = '{"streams":[{"index":0,"codec_type":"audio"}],"format":{}}'
                    StderrText = ''
                }
            }
            return [pscustomobject]@{ ExitCode = 0; StdoutText = ''; StderrText = '{"input_i":"-20.0","input_tp":"-3.0","input_lra":"5.0","input_thresh":"-30.0"}' }
        }

        $state1 = New-MediaNormalizerState
        $viaInvokeNormalize = Invoke-Normalize `
            -State $state1 `
            -Mode audio `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -3.0 `
            -TruePeak -1.0 `
            -Bitrate '192k' `
            -SampleRate '48000' `
            -CollisionPolicy rename `
            -AnalyzeOnly `
            -Logger { param($m) }
        $viaInvokeNormalize.Fail | Should -Be 1

        $state2 = New-MediaNormalizerState
        $direct = Get-MediaLoudnessAnalysis -FilePath $script:probeTempFile -Target -3.0 -TruePeak -1.0 -State $state2
        $direct.Streams.Count | Should -Be 1
    }
}

Describe 'ConvertTo-PresetMap 範囲外プリセットの除外と後方互換 (AC-2 / 設計判断3)' {
    BeforeAll {
        Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Ui.psm1')) -Force
    }

    AfterAll {
        Remove-Module MediaNormalizer.Ui -Force -ErrorAction SilentlyContinue
    }

    It '範囲外プリセットは除外され、[ref]Warningsへ理由が積まれる' {
        InModuleScope MediaNormalizer.Ui {
            $warnings = [Collections.Generic.List[string]]::new()
            $presets = @(
                [pscustomobject]@{ name = 'OK'; target = -16.0; truePeak = -1.0; bitrate = '192k'; sampleRate = 48000 },
                [pscustomobject]@{ name = 'NG'; target = -3.0; truePeak = -1.0; bitrate = '192k'; sampleRate = 48000 }
            )
            $map = ConvertTo-PresetMap -PresetList $presets -Warnings ([ref]$warnings)

            $map.ContainsKey('OK') | Should -BeTrue
            $map.ContainsKey('NG') | Should -BeFalse
            $warnings.Count | Should -Be 1
            $warnings[0] | Should -Match 'NG'
        }
    }

    It '非数値・欠落プリセットは除外され、[ref]Warningsへ理由が積まれる' {
        InModuleScope MediaNormalizer.Ui {
            $warnings = [Collections.Generic.List[string]]::new()
            $presets = @(
                [pscustomobject]@{ name = 'Bad'; target = 'not-a-number'; truePeak = -1.0; bitrate = '192k'; sampleRate = 48000 },
                [pscustomobject]@{ name = 'OK'; target = -16.0; truePeak = -1.0; bitrate = '192k'; sampleRate = 48000 }
            )
            $map = ConvertTo-PresetMap -PresetList $presets -Warnings ([ref]$warnings)

            $map.Count | Should -Be 1
            $map.ContainsKey('OK') | Should -BeTrue
            $warnings.Count | Should -Be 1
            $warnings[0] | Should -Match 'Bad'
        }
    }

    It 'NaN/Infinity相当の数値プリセットも除外される' {
        InModuleScope MediaNormalizer.Ui {
            $warnings = [Collections.Generic.List[string]]::new()
            $presets = @(
                [pscustomobject]@{ name = 'Inf'; target = [double]::PositiveInfinity; truePeak = -1.0; bitrate = '192k'; sampleRate = 48000 }
            )
            $map = ConvertTo-PresetMap -PresetList $presets -Warnings ([ref]$warnings)

            $map.Count | Should -Be 0
            $warnings.Count | Should -Be 1
        }
    }

    It '-Warnings を渡さない従来の呼び出しは従来と同じ hashtable を返す（後方互換の固定）' {
        InModuleScope MediaNormalizer.Ui {
            $presets = @(
                [pscustomobject]@{ name = 'A'; target = -16.0; truePeak = -1.0; bitrate = '192k'; sampleRate = 48000 }
            )
            $map = ConvertTo-PresetMap -PresetList $presets
            $map.GetType().Name | Should -Be 'Hashtable'
            $map.ContainsKey('A') | Should -BeTrue
            [double]$map['A'].Target | Should -Be ([double]-16.0)
        }
    }

}

Describe 'Import-Presets の警告伝播 (AC-2)' {
    BeforeAll {
        Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Ui.psm1')) -Force
    }

    AfterAll {
        Remove-Module MediaNormalizer.Ui -Force -ErrorAction SilentlyContinue
    }

    It 'map.Count が 0 になるフォールバック経路で理由を警告へ追記する' {
        InModuleScope MediaNormalizer.UiLogic {
            Mock ConvertTo-PresetMap { @{} }
            $warnings = [Collections.Generic.List[string]]::new()

            $map = Import-Presets -Warnings ([ref]$warnings)

            $map.Count | Should -Be 1
            $map.ContainsKey('デフォルト') | Should -BeTrue
            ($warnings -join "`n") | Should -Match 'フォールバック'
        }
    }

    It '-Warnings を省略しても従来どおり動作する（後方互換）' {
        InModuleScope MediaNormalizer.UiLogic {
            Mock ConvertTo-PresetMap { @{} }
            { Import-Presets } | Should -Not -Throw
            (Import-Presets).Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'New-MainForm のラウドネス範囲 GUI 反映 (AC-1 / AC-2 手動確認の自動代替)' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
    BeforeAll {
        Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Ui.psm1')) -Force
    }

    AfterAll {
        Remove-Module MediaNormalizer.Ui -Force -ErrorAction SilentlyContinue
    }

    It 'NumTarget/NumTP の Minimum/Maximum が Get-LoudnessParameterRange と一致する' {
        InModuleScope MediaNormalizer.Ui {
            $state = New-MediaNormalizerState
            $state = Initialize-UiState -State $state
            $form = $null
            try {
                $form = New-MainForm -State $state

                $targetRange = MediaNormalizer.Core\Get-LoudnessParameterRange -Name 'Target'
                $truePeakRange = MediaNormalizer.Core\Get-LoudnessParameterRange -Name 'TruePeak'

                $state.Controls.NumTarget.Minimum | Should -Be ([decimal]$targetRange.Min)
                $state.Controls.NumTarget.Maximum | Should -Be ([decimal]$targetRange.Max)
                $state.Controls.NumTP.Minimum | Should -Be ([decimal]$truePeakRange.Min)
                $state.Controls.NumTP.Maximum | Should -Be ([decimal]$truePeakRange.Max)

                # 既定値がクランプされていないことも併せて確認する。
                $state.Controls.NumTarget.Value | Should -Be ([decimal]-16.0)
                $state.Controls.NumTP.Value | Should -Be ([decimal]-1.0)
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

    It '範囲外プリセットは例外を投げずに選択肢から除外され、警告ログに残る（設計判断3）' {
        InModuleScope MediaNormalizer.Ui {
            Mock Import-Presets {
                param([ref]$Warnings)
                if ($null -ne $Warnings) {
                    $Warnings.Value.Add("プリセット 'NG' は範囲外のため除外しました。")
                }
                return @{ 'デフォルト' = @{ Target = -16.0; TruePeak = -1.0; Bitrate = '192k'; SampleRate = '48000'; OutputFormat = 'mp3'; Purpose = 'p'; Basis = 'b'; Warning = 'w' } }
            }

            $state = New-MediaNormalizerState
            $state = Initialize-UiState -State $state
            $form = $null
            try {
                { $form = New-MainForm -State $state } | Should -Not -Throw

                $state.Presets.ContainsKey('NG') | Should -BeFalse
                $state.Controls.CmbPreset.Items | Should -Not -Contain 'NG'
                $state.LogBuffer.ToString() | Should -Match 'NG'
                $state.LogBuffer.ToString() | Should -Match '範囲外'
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
}

Describe 'media-normalizer.ps1 -Cli 範囲外プリセットの実プロセス終了コード (AC-3)' -Tag 'Slow' {
    BeforeAll {
        $script:entryPoint = [IO.Path]::Combine($script:projectRoot, 'media-normalizer.ps1')
        $script:presetsPath = [IO.Path]::Combine($script:projectRoot, 'assets', 'presets.json')
        $script:originalPresetsBytes = [IO.File]::ReadAllBytes($script:presetsPath)
    }

    AfterAll {
        [IO.File]::WriteAllBytes($script:presetsPath, $script:originalPresetsBytes)
    }

    It '範囲外presetを選択すると実プロセスの終了コードが厳密に2になり、cleanupで上書きされない' {
        $outOfRangePresets = [ordered]@{
            presets = @(
                [ordered]@{
                    name = 'RangeTestOutOfRange'
                    target = -3.0
                    truePeak = -1.0
                    bitrate = '192k'
                    sampleRate = 48000
                    outputFormat = 'mp3'
                })
        }
        ($outOfRangePresets | ConvertTo-Json -Depth 5) |
            Set-Content -LiteralPath $script:presetsPath -Encoding UTF8

        $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mn-cli-range-' + [guid]::NewGuid().ToString('N'))
        $inDir = Join-Path $tmpRoot 'in'
        $outDir = Join-Path $tmpRoot 'out'
        New-Item -ItemType Directory -Path $inDir, $outDir -Force | Out-Null
        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = (Get-Process -Id $PID).Path
            if (-not $psi.FileName -or $psi.FileName -notmatch 'pwsh') {
                $psi.FileName = 'pwsh'
            }
            $psi.ArgumentList.Add('-NoProfile')
            $psi.ArgumentList.Add('-File')
            $psi.ArgumentList.Add($script:entryPoint)
            $psi.ArgumentList.Add('-Cli')
            $psi.ArgumentList.Add('-InputDir')
            $psi.ArgumentList.Add($inDir)
            $psi.ArgumentList.Add('-OutputDir')
            $psi.ArgumentList.Add($outDir)
            $psi.ArgumentList.Add('-Preset')
            $psi.ArgumentList.Add('RangeTestOutOfRange')
            $psi.RedirectStandardError = $true
            $psi.RedirectStandardOutput = $true
            $psi.UseShellExecute = $false

            $proc = [System.Diagnostics.Process]::Start($psi)
            $stderr = $proc.StandardError.ReadToEnd()
            $proc.StandardOutput.ReadToEnd() | Out-Null
            $proc.WaitForExit()

            $proc.ExitCode | Should -Be 2
            $stderr | Should -Match '範囲外|プリセット'
        } finally {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
