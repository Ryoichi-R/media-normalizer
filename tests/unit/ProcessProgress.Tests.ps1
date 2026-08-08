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

Describe 'Wait-MediaNormalizerProcessWithProgress' {
    It 'HeartbeatLabel とログ増加量を出し分ける' {
        InModuleScope MediaNormalizer.Core {
            function New-TestFakeProcess {
                param([int]$ExitAfter = 2)
                $proc = [pscustomobject]@{ Checks = 0; ExitAfter = $ExitAfter; Id = 12345 }
                $proc | Add-Member -MemberType ScriptProperty -Name HasExited -Value {
                    $this.Checks++
                    return $this.Checks -ge $this.ExitAfter
                }
                return $proc
            }

            $stdout = [System.IO.Path]::GetTempFileName()
            $stderr = [System.IO.Path]::GetTempFileName()
            Set-Content -LiteralPath $stdout -Value 'abc' -Encoding UTF8
            Set-Content -LiteralPath $stderr -Value 'defg' -Encoding UTF8
            $logs = New-Object System.Collections.Generic.List[string]
            $state = New-MediaNormalizerState
            $start = [datetime]'2026-06-29T00:00:00'
            $ticks = New-Object System.Collections.Generic.Queue[datetime]
            $ticks.Enqueue($start)
            $ticks.Enqueue($start.AddSeconds(6))
            try {
                Wait-MediaNormalizerProcessWithProgress `
                    -ProcessLike (New-TestFakeProcess -ExitAfter 2) `
                    -StdoutPath $stdout `
                    -StderrPath $stderr `
                    -State $state `
                    -Logger { param($m) $logs.Add($m) | Out-Null } `
                    -HeartbeatLabel '速度変更中...' `
                    -UpdateElapsedFromProgress $false `
                    -SleepMilliseconds 0 `
                    -GetNow { $ticks.Dequeue() }

                ($logs -join "`n") | Should -Match '速度変更中\.\.\. 6s \(ログ増加 '
                $state.CurrentFileElapsedSec | Should -Be 0
            } finally {
                Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'UpdateElapsedFromProgress が true の場合だけ経過秒を反映する' {
        InModuleScope MediaNormalizer.Core {
            function New-TestFakeProcess {
                param([int]$ExitAfter = 2)
                $proc = [pscustomobject]@{ Checks = 0; ExitAfter = $ExitAfter; Id = 12345 }
                $proc | Add-Member -MemberType ScriptProperty -Name HasExited -Value {
                    $this.Checks++
                    return $this.Checks -ge $this.ExitAfter
                }
                return $proc
            }

            $stdout = [System.IO.Path]::GetTempFileName()
            $stderr = [System.IO.Path]::GetTempFileName()
            Set-Content -LiteralPath $stdout -Value '' -Encoding UTF8
            Set-Content -LiteralPath $stderr -Value 'frame=1 time=00:00:04.00 bitrate=1000k' -Encoding UTF8
            $state = New-MediaNormalizerState
            $start = [datetime]'2026-06-29T00:00:00'
            $ticks = New-Object System.Collections.Generic.Queue[datetime]
            $ticks.Enqueue($start)
            $ticks.Enqueue($start.AddSeconds(6))
            try {
                Wait-MediaNormalizerProcessWithProgress `
                    -ProcessLike (New-TestFakeProcess -ExitAfter 2) `
                    -StdoutPath $stdout `
                    -StderrPath $stderr `
                    -State $state `
                    -Logger { param($m) } `
                    -CurrentFileDurationSec 10 `
                    -UpdateElapsedFromProgress $true `
                    -ProgressSpeedFactor 1.5 `
                    -SleepMilliseconds 0 `
                    -GetNow { $ticks.Dequeue() }

                [math]::Abs($state.CurrentFileElapsedSec - 6.0) | Should -BeLessThan 0.01
            } finally {
                Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'ProgressBaseSec と ProgressScale でフェーズ内進捗を全体タイムラインへ写像する' {
        InModuleScope MediaNormalizer.Core {
            function New-TestFakeProcess {
                param([int]$ExitAfter = 2)
                $proc = [pscustomobject]@{ Checks = 0; ExitAfter = $ExitAfter; Id = 12345 }
                $proc | Add-Member -MemberType ScriptProperty -Name HasExited -Value {
                    $this.Checks++
                    return $this.Checks -ge $this.ExitAfter
                }
                return $proc
            }

            $stdout = [System.IO.Path]::GetTempFileName()
            $stderr = [System.IO.Path]::GetTempFileName()
            Set-Content -LiteralPath $stdout -Value '' -Encoding UTF8
            Set-Content -LiteralPath $stderr -Value 'frame=1 time=00:00:04.00 bitrate=1000k' -Encoding UTF8
            $state = New-MediaNormalizerState
            $start = [datetime]'2026-06-29T00:00:00'
            $ticks = New-Object System.Collections.Generic.Queue[datetime]
            $ticks.Enqueue($start)
            $ticks.Enqueue($start.AddSeconds(6))
            try {
                Wait-MediaNormalizerProcessWithProgress `
                    -ProcessLike (New-TestFakeProcess -ExitAfter 2) `
                    -StdoutPath $stdout `
                    -StderrPath $stderr `
                    -State $state `
                    -Logger { param($m) } `
                    -CurrentFileDurationSec 10 `
                    -UpdateElapsedFromProgress $true `
                    -ProgressBaseSec 5 `
                    -ProgressScale 0.5 `
                    -SleepMilliseconds 0 `
                    -GetNow { $ticks.Dequeue() }

                [math]::Abs($state.CurrentFileElapsedSec - 7.0) | Should -BeLessThan 0.01
            } finally {
                Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'キャンセル要求時の CancelAction は1回だけ呼ぶ' {
        InModuleScope MediaNormalizer.Core {
            function New-TestFakeProcess {
                param([int]$ExitAfter = 2)
                $proc = [pscustomobject]@{ Checks = 0; ExitAfter = $ExitAfter; Id = 12345 }
                $proc | Add-Member -MemberType ScriptProperty -Name HasExited -Value {
                    $this.Checks++
                    return $this.Checks -ge $this.ExitAfter
                }
                return $proc
            }

            $state = New-MediaNormalizerState
            $state.CancelRequested = $true
            $counter = [pscustomobject]@{ Count = 0 }
            $start = [datetime]'2026-06-29T00:00:00'
            $ticks = New-Object System.Collections.Generic.Queue[datetime]
            1..10 | ForEach-Object { $ticks.Enqueue($start.AddSeconds($_)) }

            Wait-MediaNormalizerProcessWithProgress `
                -ProcessLike (New-TestFakeProcess -ExitAfter 5) `
                -State $state `
                -Logger { param($m) } `
                -CancelAction { $counter.Count++ } `
                -UpdateElapsedFromProgress $false `
                -HeartbeatIntervalSeconds 100 `
                -SleepMilliseconds 0 `
                -GetNow { $ticks.Dequeue() }

            $counter.Count | Should -Be 1
        }
    }

    It 'PumpEvents は CliMode 以外で毎周期呼ばれ、CliMode では呼ばれない' {
        InModuleScope MediaNormalizer.Core {
            function New-TestFakeProcess {
                param([int]$ExitAfter = 2)
                $proc = [pscustomobject]@{ Checks = 0; ExitAfter = $ExitAfter; Id = 12345 }
                $proc | Add-Member -MemberType ScriptProperty -Name HasExited -Value {
                    $this.Checks++
                    return $this.Checks -ge $this.ExitAfter
                }
                return $proc
            }

            $state = New-MediaNormalizerState
            $pumpCount = [pscustomobject]@{ Count = 0 }
            $start = [datetime]'2026-06-29T00:00:00'
            $ticks = New-Object System.Collections.Generic.Queue[datetime]
            1..5 | ForEach-Object { $ticks.Enqueue($start.AddSeconds($_)) }

            Wait-MediaNormalizerProcessWithProgress `
                -ProcessLike (New-TestFakeProcess -ExitAfter 4) `
                -State $state `
                -Logger { param($m) } `
                -PumpEvents { $pumpCount.Count++ } `
                -TrackElapsedForEta $false `
                -SleepMilliseconds 0 `
                -GetNow { $ticks.Dequeue() }

            $pumpCount.Count | Should -Be 3

            $pumpCountCli = [pscustomobject]@{ Count = 0 }
            $ticksCli = New-Object System.Collections.Generic.Queue[datetime]
            1..5 | ForEach-Object { $ticksCli.Enqueue($start.AddSeconds($_)) }

            Wait-MediaNormalizerProcessWithProgress `
                -ProcessLike (New-TestFakeProcess -ExitAfter 4) `
                -State $state `
                -Logger { param($m) } `
                -PumpEvents { $pumpCountCli.Count++ } `
                -CliMode `
                -TrackElapsedForEta $false `
                -SleepMilliseconds 0 `
                -GetNow { $ticksCli.Dequeue() }

            $pumpCountCli.Count | Should -Be 0
        }
    }

    It 'TrackPhaseProgress は TrackElapsedForEta と独立して PhaseProgressPercent のみ更新する' {
        InModuleScope MediaNormalizer.Core {
            function New-TestFakeProcess {
                param([int]$ExitAfter = 2)
                $proc = [pscustomobject]@{ Checks = 0; ExitAfter = $ExitAfter; Id = 12345 }
                $proc | Add-Member -MemberType ScriptProperty -Name HasExited -Value {
                    $this.Checks++
                    return $this.Checks -ge $this.ExitAfter
                }
                return $proc
            }

            $stdout = [System.IO.Path]::GetTempFileName()
            $stderr = [System.IO.Path]::GetTempFileName()
            Set-Content -LiteralPath $stdout -Value 'out_time_us=4000000' -Encoding UTF8
            Set-Content -LiteralPath $stderr -Value '' -Encoding UTF8
            $state = New-MediaNormalizerState
            $start = [datetime]'2026-06-29T00:00:00'
            $ticks = New-Object System.Collections.Generic.Queue[datetime]
            $ticks.Enqueue($start)
            $ticks.Enqueue($start.AddSeconds(1))
            try {
                Wait-MediaNormalizerProcessWithProgress `
                    -ProcessLike (New-TestFakeProcess -ExitAfter 2) `
                    -StdoutPath $stdout `
                    -StderrPath $stderr `
                    -State $state `
                    -Logger { param($m) } `
                    -CurrentFileDurationSec 10 `
                    -TrackElapsedForEta $false `
                    -TrackPhaseProgress $true `
                    -SleepMilliseconds 0 `
                    -GetNow { $ticks.Dequeue() }

                $state.CurrentFileElapsedSec | Should -Be 0
                $state.PhaseProgressPercent | Should -Be 40
            } finally {
                Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'PhaseProgressBasePercent と PhaseProgressScale で複数ストリームの合成進捗を算出する' {
        InModuleScope MediaNormalizer.Core {
            function New-TestFakeProcess {
                param([int]$ExitAfter = 2)
                $proc = [pscustomobject]@{ Checks = 0; ExitAfter = $ExitAfter; Id = 12345 }
                $proc | Add-Member -MemberType ScriptProperty -Name HasExited -Value {
                    $this.Checks++
                    return $this.Checks -ge $this.ExitAfter
                }
                return $proc
            }

            $stdout = [System.IO.Path]::GetTempFileName()
            $stderr = [System.IO.Path]::GetTempFileName()
            Set-Content -LiteralPath $stdout -Value 'out_time_us=5000000' -Encoding UTF8
            Set-Content -LiteralPath $stderr -Value '' -Encoding UTF8
            $state = New-MediaNormalizerState
            $start = [datetime]'2026-06-29T00:00:00'
            $ticks = New-Object System.Collections.Generic.Queue[datetime]
            $ticks.Enqueue($start)
            $ticks.Enqueue($start.AddSeconds(1))
            try {
                # audioIndex=1 / audioCount=2 相当: base=50, scale=0.5
                Wait-MediaNormalizerProcessWithProgress `
                    -ProcessLike (New-TestFakeProcess -ExitAfter 2) `
                    -StdoutPath $stdout `
                    -StderrPath $stderr `
                    -State $state `
                    -Logger { param($m) } `
                    -CurrentFileDurationSec 10 `
                    -TrackElapsedForEta $false `
                    -TrackPhaseProgress $true `
                    -PhaseProgressBasePercent 50 `
                    -PhaseProgressScale 0.5 `
                    -SleepMilliseconds 0 `
                    -GetNow { $ticks.Dequeue() }

                # streamPercent = 5/10*100=50 -> 50 + 50*0.5 = 75
                $state.PhaseProgressPercent | Should -Be 75
            } finally {
                Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'UiUpdateIntervalSeconds は HeartbeatIntervalSeconds と独立に Progress を呼ぶ' {
        InModuleScope MediaNormalizer.Core {
            function New-TestFakeProcess {
                param([int]$ExitAfter = 2)
                $proc = [pscustomobject]@{ Checks = 0; ExitAfter = $ExitAfter; Id = 12345 }
                $proc | Add-Member -MemberType ScriptProperty -Name HasExited -Value {
                    $this.Checks++
                    return $this.Checks -ge $this.ExitAfter
                }
                return $proc
            }

            $state = New-MediaNormalizerState
            $progressCount = [pscustomobject]@{ Count = 0 }
            $heartbeatLogged = [pscustomobject]@{ Count = 0 }
            $start = [datetime]'2026-06-29T00:00:00'
            $ticks = New-Object System.Collections.Generic.Queue[datetime]
            $ticks.Enqueue($start)
            $ticks.Enqueue($start.AddSeconds(1))

            Wait-MediaNormalizerProcessWithProgress `
                -ProcessLike (New-TestFakeProcess -ExitAfter 2) `
                -State $state `
                -Logger { param($m) $heartbeatLogged.Count++ } `
                -Progress { param($c, $t) $progressCount.Count++ } `
                -TrackElapsedForEta $false `
                -HeartbeatIntervalSeconds 100 `
                -UiUpdateIntervalSeconds 0.25 `
                -SleepMilliseconds 0 `
                -GetNow { $ticks.Dequeue() }

            $progressCount.Count | Should -Be 1
            $heartbeatLogged.Count | Should -Be 0
        }
    }
}
