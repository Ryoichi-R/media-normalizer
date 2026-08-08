#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:libRoot = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib')
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Progress.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Core.psm1')) -Force
}

AfterAll {
    Remove-Module MediaNormalizer.Core -Force -ErrorAction SilentlyContinue
    Remove-Module MediaNormalizer.Progress -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-ProcessArgumentList Windows quoting' {
    It '空白を含む引数を引用する' {
        InModuleScope MediaNormalizer.Core {
            @(ConvertTo-ProcessArgumentList -Arguments @('C:\media files\sample.mp4'))[0] |
                Should -Be '"C:\media files\sample.mp4"'
        }
    }

    It '末尾backslashを含む引用対象を二重化する' {
        InModuleScope MediaNormalizer.Core {
            @(ConvertTo-ProcessArgumentList -Arguments @('C:\media files\'))[0] |
                Should -Be '"C:\media files\\"'
        }
    }

    It '埋め込み引用符をエスケープする' {
        InModuleScope MediaNormalizer.Core {
            @(ConvertTo-ProcessArgumentList -Arguments @('value "quoted"'))[0] |
                Should -Be '"value \"quoted\""'
        }
    }
}

Describe 'Get-MediaInventory / Get-MediaLoudnessAnalysis から Invoke-MediaNormalizerProcess への伝播' {
    <#
        Invoke-MediaNormalizerProcess を Mock し、上位関数が PhaseLabel / CliMode / PumpEvents /
        TrackPhaseProgress 等を正しく渡すことのみを検証する。実際にプロセスが起動され最後まで
        走ることの検証ではない(それは tests/integration/LoudnessAnalysis.Tests.ps1 が担う)。
    #>

    BeforeEach {
        $script:probeTempFile = [IO.Path]::GetTempFileName()
    }

    AfterEach {
        Remove-Item -LiteralPath $script:probeTempFile -Force -ErrorAction SilentlyContinue
    }

    It 'Get-MediaInventory は PhaseLabel=情報取得中・TrackPhaseProgress=false で runner を呼ぶ' {
        Mock -CommandName Invoke-MediaNormalizerProcess -ModuleName MediaNormalizer.Core -MockWith {
            [pscustomobject]@{ ExitCode = 0; StdoutText = '{"streams":[],"format":{}}'; StderrText = '' }
        }

        $state = New-MediaNormalizerState
        $pumpCalls = 0
        Get-MediaInventory -FilePath $script:probeTempFile -State $state -PumpEvents { $pumpCalls++ } | Out-Null

        Should -Invoke Invoke-MediaNormalizerProcess -ModuleName MediaNormalizer.Core -Times 1 -ParameterFilter {
            $FilePath -eq 'ffprobe' -and
            $PhaseLabel -eq '情報取得中' -and
            $TrackPhaseProgress -eq $false -and
            $TrackElapsedForEta -eq $false
        }
    }

    It 'Get-MediaInventory は CliMode を runner へ伝播する' {
        Mock -CommandName Invoke-MediaNormalizerProcess -ModuleName MediaNormalizer.Core -MockWith {
            [pscustomobject]@{ ExitCode = 0; StdoutText = '{"streams":[],"format":{}}'; StderrText = '' }
        }

        Get-MediaInventory -FilePath $script:probeTempFile -CliMode | Out-Null

        Should -Invoke Invoke-MediaNormalizerProcess -ModuleName MediaNormalizer.Core -Times 1 -ParameterFilter {
            $CliMode -eq $true
        }
    }

    It 'Get-MediaLoudnessAnalysis は音声ストリームごとに PhaseProgressBasePercent/Scale を合成して runner を呼ぶ' {
        Mock -CommandName Invoke-MediaNormalizerProcess -ModuleName MediaNormalizer.Core -MockWith {
            param(
                $FilePath, $Arguments, $State, $PhaseLabel, $Logger, $Progress, $PumpEvents, $CliMode,
                $CurrentFileDurationSec, $TrackElapsedForEta, $TrackPhaseProgress,
                $PhaseProgressBasePercent, $PhaseProgressScale, $ProgressSpeedFactor, $ProgressScale,
                $ProgressBaseSec, $LongRunningMessage, $SlowWarnSeconds, $UiUpdateIntervalSeconds,
                $WriteProgressFile
            )
            if ($FilePath -eq 'ffprobe') {
                return [pscustomobject]@{
                    ExitCode   = 0
                    StdoutText = '{"streams":[{"index":0,"codec_type":"audio"},{"index":1,"codec_type":"audio"}],"format":{}}'
                    StderrText = ''
                }
            }
            return [pscustomobject]@{
                ExitCode   = 0
                StdoutText = ''
                StderrText = '{"input_i":"-20.0","input_tp":"-3.0","input_lra":"5.0","input_thresh":"-30.0","target_offset":"0.5"}'
            }
        }

        $state = New-MediaNormalizerState
        $analysis = Get-MediaLoudnessAnalysis -FilePath $script:probeTempFile -Target -16.0 -TruePeak -1.0 `
            -State $state -CurrentFileDurationSec 20.0 -PhaseLabel '解析中'

        $analysis.Streams.Count | Should -Be 2

        Should -Invoke Invoke-MediaNormalizerProcess -ModuleName MediaNormalizer.Core -Times 1 -ParameterFilter {
            $FilePath -eq 'ffmpeg' -and
            $PhaseLabel -eq '解析中' -and
            $TrackElapsedForEta -eq $false -and
            $TrackPhaseProgress -eq $true -and
            $PhaseProgressBasePercent -eq 0.0 -and
            [math]::Abs($PhaseProgressScale - 0.5) -lt 0.0001 -and
            $WriteProgressFile -eq $true
        }
        Should -Invoke Invoke-MediaNormalizerProcess -ModuleName MediaNormalizer.Core -Times 1 -ParameterFilter {
            $FilePath -eq 'ffmpeg' -and
            [math]::Abs($PhaseProgressBasePercent - 50.0) -lt 0.0001 -and
            [math]::Abs($PhaseProgressScale - 0.5) -lt 0.0001
        }
    }

    It 'Get-MediaLoudnessAnalysis はキャンセル済み State では後続ストリームを開始しない' {
        Mock -CommandName Invoke-MediaNormalizerProcess -ModuleName MediaNormalizer.Core -MockWith {
            param($FilePath)
            if ($FilePath -eq 'ffprobe') {
                return [pscustomobject]@{
                    ExitCode   = 0
                    StdoutText = '{"streams":[{"index":0,"codec_type":"audio"},{"index":1,"codec_type":"audio"}],"format":{}}'
                    StderrText = ''
                }
            }
            # 1本目のffmpeg呼び出し完了直後にキャンセルが立ったことを模擬する。
            $script:cancelState.CancelRequested = $true
            return [pscustomobject]@{
                ExitCode   = 0
                StdoutText = ''
                StderrText = '{"input_i":"-20.0","input_tp":"-3.0","input_lra":"5.0","input_thresh":"-30.0","target_offset":"0.5"}'
            }
        }

        $script:cancelState = New-MediaNormalizerState
        { Get-MediaLoudnessAnalysis -FilePath $script:probeTempFile -Target -16.0 -TruePeak -1.0 -State $script:cancelState } |
            Should -Throw '*キャンセル*'

        # ffprobe(情報取得) 1回 + ffmpeg(1本目) 1回 = 2回で止まり、2本目のffmpegは呼ばれない。
        Should -Invoke Invoke-MediaNormalizerProcess -ModuleName MediaNormalizer.Core -Times 2
    }
}

Describe 'Invoke-MediaNormalizerProcess 本体' -Tag 'WindowsOnly' {
    It '正常終了時に RunningProcess / CurrentPhase / PhaseProgressPercent を解除する' {
        InModuleScope MediaNormalizer.Core {
            $state = New-MediaNormalizerState
            $result = Invoke-MediaNormalizerProcess `
                -FilePath 'cmd.exe' `
                -Arguments @('/c', 'exit 0') `
                -State $state `
                -PhaseLabel 'テスト中' `
                -CliMode `
                -SleepMilliseconds 0

            $result.ExitCode | Should -Be 0
            $state.RunningProcess | Should -BeNullOrEmpty
            $state.CurrentPhase | Should -BeNullOrEmpty
            $state.PhaseProgressPercent | Should -Be (-1.0)
        }
    }

    It '起動自体が失敗した場合も例外を再送出しつつ State を解除する' {
        InModuleScope MediaNormalizer.Core {
            $state = New-MediaNormalizerState
            { Invoke-MediaNormalizerProcess `
                -FilePath 'media-normalizer-does-not-exist.exe' `
                -Arguments @('--bogus') `
                -State $state `
                -PhaseLabel 'テスト中' `
                -CliMode `
                -SleepMilliseconds 0 } | Should -Throw

            $state.RunningProcess | Should -BeNullOrEmpty
            $state.CurrentPhase | Should -BeNullOrEmpty
            $state.PhaseProgressPercent | Should -Be (-1.0)
        }
    }

    It '実行後に一時ファイル(stdout/stderr)が残らない' {
        InModuleScope MediaNormalizer.Core {
            $tempDir = [IO.Path]::GetTempPath()
            $before = @(Get-ChildItem -Path $tempDir -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            $state = New-MediaNormalizerState
            $null = Invoke-MediaNormalizerProcess `
                -FilePath 'cmd.exe' `
                -Arguments @('/c', 'exit 0') `
                -State $state `
                -PhaseLabel 'テスト中' `
                -CliMode `
                -SleepMilliseconds 0
            $after = @(Get-ChildItem -Path $tempDir -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            $leaked = @(Compare-Object -ReferenceObject $before -DifferenceObject $after -ErrorAction SilentlyContinue |
                Where-Object { $_.SideIndicator -eq '=>' })
            $leaked | Should -BeNullOrEmpty
        }
    }

    It 'GUI コンテキストで PumpEvents 未指定なら警告ログを出す' {
        InModuleScope MediaNormalizer.Core {
            $state = New-MediaNormalizerState
            $logs = New-Object System.Collections.Generic.List[string]
            $null = Invoke-MediaNormalizerProcess `
                -FilePath 'cmd.exe' `
                -Arguments @('/c', 'exit 0') `
                -State $state `
                -PhaseLabel 'テスト中' `
                -Logger { param($m) $logs.Add($m) } `
                -SleepMilliseconds 0

            ($logs -join "`n") | Should -Match 'PumpEvents 未指定'
        }
    }

    It 'CliMode では PumpEvents 未指定でも警告ログを出さない' {
        InModuleScope MediaNormalizer.Core {
            $state = New-MediaNormalizerState
            $logs = New-Object System.Collections.Generic.List[string]
            $null = Invoke-MediaNormalizerProcess `
                -FilePath 'cmd.exe' `
                -Arguments @('/c', 'exit 0') `
                -State $state `
                -PhaseLabel 'テスト中' `
                -Logger { param($m) $logs.Add($m) } `
                -CliMode `
                -SleepMilliseconds 0

            ($logs -join "`n") | Should -Not -Match 'PumpEvents 未指定'
        }
    }
}
