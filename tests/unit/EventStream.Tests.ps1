#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.Core.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.WorkerProtocol.psm1') -Force
}

Describe 'Media Normalizer structured event sink' {
    It 'emits run, file, progress, and log events without changing existing logger output' {
        InModuleScope MediaNormalizer.Core {
            Mock -ModuleName MediaNormalizer.Platform Get-Command {
                param($Name)
                [pscustomobject]@{ Source = $Name }
            }

            $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('mn-event-stream-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($tempRoot)
            try {
                $inputPath = Join-Path $tempRoot 'sample.mp3'
                $reportPath = Join-Path $tempRoot 'report.json'
                [IO.File]::WriteAllText($inputPath, 'fixture')
                $analyzer = {
                    param($path, $target, $truePeak)
                    [pscustomobject]@{
                        Streams = @([pscustomobject]@{
                            AudioStreamIndex = 0
                            IntegratedLufs = -16.0
                            TruePeakDbtp = -1.0
                        })
                    }
                }
                $baseParameters = @{
                    Mode = 'audio'
                    InputDir = $tempRoot
                    OutputDir = $tempRoot
                    Target = -16.0
                    TruePeak = -1.0
                    Bitrate = '192k'
                    SampleRate = '48000'
                    CollisionPolicy = 'rename'
                    TargetFiles = [IO.FileInfo]::new($inputPath)
                    Analyzer = $analyzer
                    AnalyzeOnly = $true
                    ReportPath = $reportPath
                }

                $baselineLogs = [Collections.Generic.List[string]]::new()
                $baselineResult = Invoke-Normalize @baseParameters `
                    -State (New-MediaNormalizerState) `
                    -Logger { param($message) [void]$baselineLogs.Add([string]$message) }

                $eventLogs = [Collections.Generic.List[string]]::new()
                $events = [Collections.Generic.List[object]]::new()
                $eventSink = { param($item) [void]$events.Add($item) }.GetNewClosure()
                $eventResult = Invoke-Normalize @baseParameters `
                    -State (New-MediaNormalizerState) `
                    -Logger { param($message) [void]$eventLogs.Add([string]$message) } `
                    -EventSink $eventSink `
                    -RunId '6f55000c-709c-40f0-9f76-ececf7a5e3ca'

                ($eventLogs -join "`n") | Should -Be ($baselineLogs -join "`n")
                $eventResult.Analyzed | Should -Be $baselineResult.Analyzed
                $eventResult.ReportSucceeded | Should -BeTrue
                foreach ($event in $events) {
                    $validation = Test-MediaNormalizerWorkerEvent -Message $event
                    $validation.IsValid | Should -BeTrue -Because ($event.type + ': ' + ($validation.Errors -join '; '))
                }
                $events[0].type | Should -Be 'run-start'
                $events[-1].type | Should -Be 'run-done'
                @($events | Where-Object type -eq 'file-start').Count | Should -Be 1
                @($events | Where-Object type -eq 'file-done').Count | Should -Be 1
                @($events | Where-Object type -eq 'progress').Count | Should -BeGreaterThan 0
                @($events | Where-Object type -eq 'log').Count | Should -BeGreaterThan 0
                $fileDone = $events | Where-Object type -eq 'file-done' | Select-Object -First 1
                $fileDone.status | Should -Be 'analyzed'
                $fileDone.inputPath | Should -Be ([IO.Path]::GetFullPath($inputPath))
                $runDone = $events[-1]
                $runDone.runId | Should -Be '6f55000c-709c-40f0-9f76-ececf7a5e3ca'
                $runDone.analyzed | Should -Be 1
                $runDone.fail | Should -Be 0
            } finally {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }


    It 'maps legacy logger prefixes to protocol log levels' {
        InModuleScope MediaNormalizer.Core {
            $events = [Collections.Generic.List[object]]::new()
            $sink = { param($item) [void]$events.Add($item) }.GetNewClosure()
            $logs = [Collections.Generic.List[string]]::new()
            $logger = { param($message) [void]$logs.Add([string]$message) }.GetNewClosure()
            $callbacks = New-MediaNormalizerEventCallbacks -EventSink $sink -Logger $logger `
                -State (New-MediaNormalizerState) -RunId '6f55000c-709c-40f0-9f76-ececf7a5e3ca' `
                -FileContext ([pscustomobject]@{ InputPath = $null })

            foreach ($line in @('[INFO ] normal', '[WARN ] careful', '[DEBUG] detail', '[ERROR] failed')) {
                & $callbacks.Logger $line
            }

            ($events | ForEach-Object level) | Should -Be @('info', 'warning', 'debug', 'error')
            ($logs -join '|') | Should -Be '[INFO ] normal|[WARN ] careful|[DEBUG] detail|[ERROR] failed'
        }
    }

    It 'emits a structured error and terminal event for preflight rejection' {
        InModuleScope MediaNormalizer.Core {
            Mock -ModuleName MediaNormalizer.Platform Get-Command {
                param($Name)
                $null
            }
            $events = [Collections.Generic.List[object]]::new()
            $eventSink = { param($item) [void]$events.Add($item) }.GetNewClosure()
            $result = Invoke-Normalize `
                -State (New-MediaNormalizerState) `
                -Mode audio `
                -InputDir '/missing/input' `
                -OutputDir '/tmp/output' `
                -Target -16.0 `
                -TruePeak -1.0 `
                -Bitrate '192k' `
                -SampleRate '48000' `
                -CollisionPolicy rename `
                -EventSink $eventSink `
                -Logger { param($message) }
            $result.Fail | Should -Be 1
            @($events | Where-Object type -eq 'error').Count | Should -Be 1
            foreach ($event in $events) { (Test-MediaNormalizerWorkerEvent -Message $event).IsValid | Should -BeTrue }
            $events[-1].type | Should -Be 'run-done'
            $events[-1].fail | Should -Be 1
        }
    }
}
