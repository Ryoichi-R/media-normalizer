#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:libRoot = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib')
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Core.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Probe.psm1')) -Force
    $script:oldFfmpegOverride = [Environment]::GetEnvironmentVariable('FFMPEG_PATH')
    $script:oldFfprobeOverride = [Environment]::GetEnvironmentVariable('FFPROBE_PATH')
    $script:useFakeMediaTools = [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT
    if ($script:useFakeMediaTools) {
        # Analyze-only orchestration uses mocked analyzers; /bin/true satisfies tool preflight without media work.
        $env:FFMPEG_PATH = '/usr/bin/true'
        $env:FFPROBE_PATH = '/usr/bin/true'
    }
}

AfterAll {
    if ($script:useFakeMediaTools) {
        if ($null -eq $script:oldFfmpegOverride) { Remove-Item Env:FFMPEG_PATH -ErrorAction SilentlyContinue }
        else { $env:FFMPEG_PATH = $script:oldFfmpegOverride }
        if ($null -eq $script:oldFfprobeOverride) { Remove-Item Env:FFPROBE_PATH -ErrorAction SilentlyContinue }
        else { $env:FFPROBE_PATH = $script:oldFfprobeOverride }
    }
}

Describe 'MediaNormalizer.Core coverage contracts' {
    It 'retries temporary-file cleanup after a transient remove failure' {
        InModuleScope MediaNormalizer.Core {
            $script:removeAttempts = 0
            Mock Remove-Item {
                $script:removeAttempts++
                if ($script:removeAttempts -lt 3) { throw 'transient lock' }
            }
            Mock Test-Path { $script:removeAttempts -lt 3 }
            Mock Start-Sleep {}

            Remove-MediaNormalizerTemporaryFile `
                -LiteralPath 'C:\temp\media-normalizer-speed-test.mp4' `
                -RetryCount 3 | Should -BeTrue
            $script:removeAttempts | Should -Be 3
        }
    }

    It 'covers ffmpeg-normalize probe failure and CLI validation failures' {
        InModuleScope MediaNormalizer.Core {
            Test-FfmpegNormalizePython -Command 'command-that-does-not-exist' | Should -BeFalse
            Test-FfmpegNormalizePython -Command 'pwsh' | Should -BeFalse

            $global:LASTEXITCODE = 0
            Invoke-NormalizeCli -OutputDir ([IO.Path]::GetTempPath()) -Preset '存在しないプリセット' -ErrorAction SilentlyContinue
            $global:LASTEXITCODE | Should -Be 2
        }
    }

    It 'resolves output hierarchy and input roots safely' {
        InModuleScope MediaNormalizer.Core {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-core-path-' + [guid]::NewGuid().ToString('N'))
            $nested = Join-Path $tmp 'nested'
            New-Item -ItemType Directory -Path $nested -Force | Out-Null
            try {
                $inputFile = Join-Path $nested 'voice.mp3'
                Set-Content -LiteralPath $inputFile -Value 'fixture' -Encoding UTF8
                (Resolve-MediaOutputDirectory -InputRoot $tmp -InputFilePath $inputFile -OutputRoot (Join-Path $tmp 'out') -PreserveHierarchy:$true) |
                    Should -Be (Join-Path (Join-Path $tmp 'out') 'nested')
                (Resolve-MediaOutputDirectory -InputRoot $inputFile -InputFilePath $inputFile -OutputRoot (Join-Path $tmp 'out') -PreserveHierarchy:$true) |
                    Should -Be (Join-Path $tmp 'out')
                (Resolve-MediaOutputDirectory -InputRoot $tmp -InputFilePath $inputFile -OutputRoot (Join-Path $tmp 'flat') -PreserveHierarchy:$false) |
                    Should -Be ([IO.Path]::GetFullPath((Join-Path $tmp 'flat')))

                (Get-MediaInputRoot -InputPath @($inputFile, $nested)) | Should -Be $nested
                { Get-MediaInputRoot -InputPath @() } | Should -Throw
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'enumerates files without duplicates and rejects missing paths' {
        InModuleScope MediaNormalizer.Core {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-core-files-' + [guid]::NewGuid().ToString('N'))
            $nested = Join-Path $tmp 'nested'
            New-Item -ItemType Directory -Path $nested -Force | Out-Null
            try {
                $rootFile = Join-Path $tmp 'root.mp3'
                $nestedFile = Join-Path $nested 'nested.wav'
                Set-Content -LiteralPath $rootFile -Value 'fixture' -Encoding UTF8
                Set-Content -LiteralPath $nestedFile -Value 'fixture' -Encoding UTF8
                $files = Get-MediaInputFiles -InputPath @($tmp, $rootFile) -Recurse
                $files.Count | Should -Be 2
                { Get-MediaInputFiles -InputPath @(Join-Path $tmp 'missing') } | Should -Throw
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'completes safe output replacement for new and existing files' {
        InModuleScope MediaNormalizer.Core {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-core-output-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            try {
                $final = Join-Path $tmp 'result.mp3'
                $temporary = Join-Path $tmp '.result.media-normalizer-temp.mp3'
                Set-Content -LiteralPath $temporary -Value 'new' -Encoding UTF8
                Complete-SafeOutput -TemporaryPath $temporary -FinalPath $final
                (Get-Content -LiteralPath $final -Raw) | Should -Match 'new'

                $temporary2 = Join-Path $tmp '.result.media-normalizer-temp2.mp3'
                Set-Content -LiteralPath $temporary2 -Value 'replacement' -Encoding UTF8
                Complete-SafeOutput -TemporaryPath $temporary2 -FinalPath $final
                (Get-Content -LiteralPath $final -Raw) | Should -Match 'replacement'
                { Complete-SafeOutput -TemporaryPath (Join-Path $tmp 'missing.tmp') -FinalPath $final } | Should -Throw
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'runs analyze-only through the full normalize orchestration without external encoders' {
        InModuleScope MediaNormalizer.Core {
            Mock -ModuleName MediaNormalizer.Platform Get-Command { param($Name) [pscustomobject]@{ Source = $Name } }
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-core-analyze-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            try {
                $input = Join-Path $tmp 'voice.mp3'
                $report = Join-Path $tmp 'report.json'
                Set-Content -LiteralPath $input -Value 'fixture' -Encoding UTF8
                $state = New-MediaNormalizerState
                $messages = [Collections.Generic.List[string]]::new()
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
                $result = Invoke-Normalize `
                    -State $state `
                    -Mode audio `
                    -InputDir $tmp `
                    -OutputDir $tmp `
                    -Target -16.0 `
                    -TruePeak -1.0 `
                    -Bitrate '192k' `
                    -SampleRate '48000' `
                    -CollisionPolicy rename `
                    -TargetFiles ([IO.FileInfo]$input) `
                    -Logger { param($message) [void]$messages.Add([string]$message) } `
                    -Progress { param($current, $total) } `
                    -PumpEvents { } `
                    -Analyzer $analyzer `
                    -AnalyzeOnly `
                    -ReportPath $report
                $result.Success | Should -Be 0
                $result.Fail | Should -Be 0
                $result.Analyzed | Should -Be 1
                $result.ReportSucceeded | Should -BeTrue
                Test-Path -LiteralPath $report | Should -BeTrue
                (Get-Content -LiteralPath $report -Raw) | Should -Match 'analyzed'
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'covers normalize preflight failures and empty-input paths' {
        InModuleScope MediaNormalizer.Core {
            Mock -ModuleName MediaNormalizer.Platform Get-Command { param($Name) [pscustomobject]@{ Source = $Name } }
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-core-preflight-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            $testFfmpegPath = $env:FFMPEG_PATH
            $testFfprobePath = $env:FFPROBE_PATH
            try {
                $base = @{
                    State = (New-MediaNormalizerState)
                    Mode = 'audio'
                    InputDir = $tmp
                    OutputDir = $tmp
                    Target = -16.0
                    TruePeak = -1.0
                    Bitrate = '192k'
                    SampleRate = '48000'
                    CollisionPolicy = 'rename'
                    AnalyzeOnly = $true
                    Logger = { param($message) }
                }

                $missingInput = Invoke-Normalize @base -InputDir (Join-Path $tmp 'missing')
                $missingInput.Fail | Should -Be 1

                $noFiles = Invoke-Normalize @base
                $noFiles.Success | Should -Be 0
                $noFiles.Fail | Should -Be 0

                Mock Find-FfmpegNormalize { $null }
                $missingNormalize = Invoke-Normalize @base -AnalyzeOnly:$false
                $missingNormalize.Fail | Should -Be 1

                Mock Find-FfmpegNormalize { 'ffmpeg-normalize' }
                $env:FFMPEG_PATH = Join-Path $tmp 'missing-ffmpeg'
                Mock -ModuleName MediaNormalizer.Platform Get-Command {
                    param($Name)
                    if ($Name -eq 'ffmpeg') { return $null }
                    [pscustomobject]@{ Source = $Name }
                }
                $missingFfmpeg = Invoke-Normalize @base -AnalyzeOnly:$false
                $missingFfmpeg.Fail | Should -Be 1

                $env:FFMPEG_PATH = $testFfmpegPath
                $env:FFPROBE_PATH = Join-Path $tmp 'missing-ffprobe'
                Mock -ModuleName MediaNormalizer.Platform Get-Command {
                    param($Name)
                    if ($Name -eq 'ffprobe') { return $null }
                    [pscustomobject]@{ Source = $Name }
                }
                $missingFfprobe = Invoke-Normalize @base -AnalyzeOnly:$false
                $missingFfprobe.Fail | Should -Be 1
            } finally {
                $env:FFMPEG_PATH = $testFfmpegPath
                $env:FFPROBE_PATH = $testFfprobePath
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'covers normalize input/output validation and filtered target branches' {
        InModuleScope MediaNormalizer.Core {
            Mock -ModuleName MediaNormalizer.Platform Get-Command { param($Name) [pscustomobject]@{ Source = $Name } }
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-core-input-branches-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            try {
                $logs = [Collections.Generic.List[string]]::new()
                $common = @{
                    State = (New-MediaNormalizerState)
                    Mode = 'audio'
                    Target = -16.0
                    TruePeak = -1.0
                    Bitrate = '192k'
                    SampleRate = '48000'
                    CollisionPolicy = 'rename'
                    AnalyzeOnly = $true
                    Logger = { param($message) [void]$logs.Add([string]$message) }
                }
                (Invoke-Normalize @common -InputDir ' ' -OutputDir $tmp).Fail | Should -Be 1
                (Invoke-Normalize @common -InputDir (Join-Path $tmp 'missing') -OutputDir $tmp).Fail | Should -Be 1
                (Invoke-Normalize @common -InputDir $tmp -OutputDir ' ').Fail | Should -Be 1

                $textPath = Join-Path $tmp 'notes.txt'
                Set-Content -LiteralPath $textPath -Value 'fixture' -Encoding UTF8
                (Invoke-Normalize @common -InputDir $tmp -OutputDir $tmp).Success | Should -Be 0
                $common.Mode = 'video'
                (Invoke-Normalize @common -InputDir $tmp -OutputDir $tmp).Success | Should -Be 0

                $mediaPath = Join-Path $tmp 'voice.mp3'
                Set-Content -LiteralPath $mediaPath -Value 'fixture' -Encoding UTF8
                $common.Mode = 'audio'
                Mock Get-MediaDuration { 2.0 }
                $analyzer = {
                    param($path, $target, $truePeak)
                    [pscustomobject]@{ Streams = @([pscustomobject]@{ AudioStreamIndex = 0; IntegratedLufs = -16.0; TruePeakDbtp = -1.0 }) }
                }
                $result = Invoke-Normalize @common `
                    -InputDir $tmp `
                    -OutputDir (Join-Path $tmp 'created-output') `
                    -Analyzer $analyzer `
                    -SpeedPercentByPath @{ $mediaPath = 150 }
                $result.Analyzed | Should -Be 1
                $logs -join "`n" | Should -Match 'ファイル別指定あり'
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'covers cancellation, collision skip, copy, and normalize failure paths' {
        InModuleScope MediaNormalizer.Core {
            Mock -ModuleName MediaNormalizer.Platform Get-Command { param($Name) [pscustomobject]@{ Source = $Name } }
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-core-branches-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            try {
                $input = Join-Path $tmp 'voice.mp3'
                Set-Content -LiteralPath $input -Value 'fixture' -Encoding UTF8
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
                $inventory = [pscustomobject]@{
                    StreamCounts = [pscustomobject]@{ audio = 1; video = 0; subtitle = 0; data = 0; attachment = 0 }
                    ChapterCount = 0
                }
                $integrity = [pscustomobject]@{ IsValid = $true; Warnings = @(); Errors = @(); DroppedAudioStreams = 0 }
                Mock Find-FfmpegNormalize { [pscustomobject]@{ Cmd = 'ffmpeg-normalize'; Args = @() } }
                Mock -ModuleName MediaNormalizer.Platform Get-Command {
                    param($Name)
                    [pscustomobject]@{ Source = $Name }
                }
                Mock Get-MediaInventory { $inventory }
                Mock Compare-MediaInventory { $integrity }

                $cancelState = New-MediaNormalizerState
                $cancelState.CancelRequested = $true
                $cancelResult = Invoke-Normalize `
                    -State $cancelState -Mode audio -InputDir $tmp -OutputDir (Join-Path $tmp 'cancel-out') `
                    -Target -16.0 -TruePeak -1.0 -Bitrate '192k' -SampleRate '48000' `
                    -CollisionPolicy rename -TargetFiles ([IO.FileInfo]$input) -Analyzer $analyzer `
                    -AnalyzeOnly -ReportPath (Join-Path $tmp 'cancel.json') -Logger { param($message) }
                $cancelResult.Cancelled | Should -Be 1

                $collisionOut = Join-Path $tmp 'collision-out'
                New-Item -ItemType Directory -Path $collisionOut -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $collisionOut 'voice.mp3') -Value 'existing' -Encoding UTF8
                $skipState = New-MediaNormalizerState
                $skipResult = Invoke-Normalize `
                    -State $skipState -Mode audio -InputDir $tmp -OutputDir $collisionOut `
                    -Target -16.0 -TruePeak -1.0 -Bitrate '192k' -SampleRate '48000' `
                    -CollisionPolicy skip -TargetFiles ([IO.FileInfo]$input) -Analyzer $analyzer `
                    -ReportPath (Join-Path $tmp 'skip.json') -Logger { param($message) }
                $skipResult.Skipped | Should -Be 1

                Mock Test-NormalizationNeeded { [pscustomobject]@{ Needed = $false } }
                $copyOut = Join-Path $tmp 'copy-out'
                $copyState = New-MediaNormalizerState
                $copyResult = Invoke-Normalize `
                    -State $copyState -Mode audio -InputDir $tmp -OutputDir $copyOut `
                    -Target -16.0 -TruePeak -1.0 -Bitrate '192k' -SampleRate '48000' `
                    -CollisionPolicy rename -TargetFiles ([IO.FileInfo]$input) -Analyzer $analyzer `
                    -ReportPath (Join-Path $tmp 'copy.json') -Logger { param($message) }
                $copyResult.Skipped | Should -Be 1
                Test-Path -LiteralPath (Join-Path $copyOut 'voice.mp3') | Should -BeTrue

                Mock Test-NormalizationNeeded { [pscustomobject]@{ Needed = $true } }
                Mock Invoke-MediaNormalizerProcess {
                    [pscustomobject]@{ ExitCode = 1; StdoutText = ''; StderrText = 'mock failure' }
                }
                $failState = New-MediaNormalizerState
                $failResult = Invoke-Normalize `
                    -State $failState -Mode audio -InputDir $tmp -OutputDir (Join-Path $tmp 'fail-out') `
                    -Target -16.0 -TruePeak -1.0 -Bitrate '192k' -SampleRate '48000' `
                    -CollisionPolicy rename -TargetFiles ([IO.FileInfo]$input) -Analyzer $analyzer `
                    -ReportPath (Join-Path $tmp 'fail.json') -Logger { param($message) }
                $failResult.Fail | Should -Be 1
                $failState.ReportRecords[0].action | Should -Be 'failed'
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'runs the CLI orchestration successfully for an empty analyze-only folder' {
        InModuleScope MediaNormalizer.Core {
            Mock -ModuleName MediaNormalizer.Platform Get-Command { param($Name) [pscustomobject]@{ Source = $Name } }
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-core-cli-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            try {
                $report = Join-Path $tmp 'cli-report.json'
                $global:LASTEXITCODE = 99
                Invoke-NormalizeCli `
                    -InputDir $tmp `
                    -OutputDir $tmp `
                    -Preset 'デフォルト' `
                    -Mode audio `
                    -AnalyzeOnly `
                    -ReportPath $report
                $global:LASTEXITCODE | Should -Be 0
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'covers CLI audio/video orchestration and fail-closed report status' {
        InModuleScope MediaNormalizer.Core {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-core-cli-both-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            try {
                Set-Content -LiteralPath (Join-Path $tmp 'voice.mp3') -Value 'fixture' -Encoding UTF8
                Set-Content -LiteralPath (Join-Path $tmp 'clip.mp4') -Value 'fixture' -Encoding UTF8
                Mock Get-MediaDuration { 1.0 }
                Mock Invoke-Normalize {
                    param($Mode)
                    if ($Mode -eq 'audio') {
                        return @{ Success = 0; Fail = 0; Cancelled = 0; ReportSucceeded = $false }
                    }
                    return @{ Success = 0; Fail = 0; Cancelled = 0 }
                }

                $global:LASTEXITCODE = 99
                Invoke-NormalizeCli -InputDir $tmp -OutputDir $tmp -Preset 'デフォルト' -Mode both -SpeedPercent 150
                $global:LASTEXITCODE | Should -Be 1
                Should -Invoke Invoke-Normalize -Times 2 -Exactly

                $global:LASTEXITCODE = 99
                Invoke-NormalizeCli -OutputDir $tmp -Preset 'デフォルト' -Mode audio -ErrorAction SilentlyContinue
                $global:LASTEXITCODE | Should -Be 2

                $global:LASTEXITCODE = 99
                Invoke-NormalizeCli -InputDir (Join-Path $tmp 'missing') -OutputDir $tmp -Preset 'デフォルト' -Mode audio -ErrorAction SilentlyContinue
                $global:LASTEXITCODE | Should -Be 2
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'includes dot-prefixed POSIX staging files in media inventory' -Tag 'PosixOnly' -Skip:$IsWindows {
        InModuleScope MediaNormalizer.Core {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-core-hidden-stage-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            try {
                $mediaPath = Join-Path $tmp '.normalized-stage.mkv'
                Set-Content -LiteralPath $mediaPath -Value 'fixture' -Encoding UTF8
                Mock Invoke-MediaNormalizerProcess {
                    [pscustomobject]@{
                        ExitCode = 0
                        StdoutText = '{"format":{"duration":"1.25"},"streams":[{"index":0,"codec_type":"audio","codec_name":"aac","channels":2}],"chapters":[]}'
                        StderrText = ''
                    }
                }

                $inventory = Get-MediaInventory -FilePath $mediaPath
                $inventory.Length | Should -Be ([IO.FileInfo]::new($mediaPath).Length)
                $inventory.DurationSec | Should -Be 1.25
                $inventory.StreamCounts.audio | Should -Be 1
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'covers inventory, loudness parser, and metadata validation failures' {
        InModuleScope MediaNormalizer.Core {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-core-validation-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            try {
                $mediaPath = Join-Path $tmp 'voice.mp3'
                Set-Content -LiteralPath $mediaPath -Value 'fixture' -Encoding UTF8
                Mock Invoke-MediaNormalizerProcess { [pscustomobject]@{ ExitCode = 1; StdoutText = ''; StderrText = '' } }
                { Get-MediaInventory -FilePath $mediaPath } | Should -Throw '*ffprobe による検証に失敗しました*'

                Mock Invoke-MediaNormalizerProcess { [pscustomobject]@{ ExitCode = 0; StdoutText = '{'; StderrText = '' } }
                { Get-MediaInventory -FilePath $mediaPath } | Should -Throw '*検証結果を解析できません*'

                $inventory = [pscustomobject]@{
                    StreamCounts = [pscustomobject]@{ audio = 0; video = 0; subtitle = 0; data = 0; attachment = 0 }
                    ChapterCount = 0
                }
                Mock Get-MediaInventory { $inventory }
                { Get-MediaLoudnessAnalysis -FilePath $mediaPath -Target -16.0 -TruePeak -1.0 } |
                    Should -Throw '*音声トラックが見つかりません*'

                $inventory.StreamCounts.audio = 1
                Mock Invoke-MediaNormalizerProcess {
                    [pscustomobject]@{ ExitCode = 0; StdoutText = ''; StderrText = '' }
                }
                { Get-MediaLoudnessAnalysis -FilePath $mediaPath -Target -16.0 -TruePeak -1.0 } |
                    Should -Throw '*解析結果を取得できません*'

                Mock Invoke-MediaNormalizerProcess {
                    [pscustomobject]@{
                        ExitCode = 0
                        StdoutText = ''
                        StderrText = '{"input_i":"bad","input_tp":"-1","input_lra":"1"}'
                    }
                }
                { Get-MediaLoudnessAnalysis -FilePath $mediaPath -Target -16.0 -TruePeak -1.0 } |
                    Should -Throw '*Integrated Loudness が不正です*'

                Mock Invoke-MediaNormalizerProcess {
                    [pscustomobject]@{ ExitCode = 1; StdoutText = ''; StderrText = '' }
                }
                { Get-MediaLoudnessAnalysis -FilePath $mediaPath -Target -16.0 -TruePeak -1.0 } |
                    Should -Throw '*ラウドネス解析に失敗しました*'

                Mock Invoke-MediaNormalizerProcess {
                    [pscustomobject]@{ ExitCode = 0; StdoutText = '{"input_i":"-16","input_tp":}' ; StderrText = '' }
                }
                { Get-MediaLoudnessAnalysis -FilePath $mediaPath -Target -16.0 -TruePeak -1.0 } |
                    Should -Throw '*解析結果を解析できません*'

                Mock Invoke-MediaNormalizerProcess {
                    [pscustomobject]@{
                        ExitCode = 0
                        StdoutText = ''
                        StderrText = '{"input_i":"-16","input_tp":"bad","input_lra":"1"}'
                    }
                }
                { Get-MediaLoudnessAnalysis -FilePath $mediaPath -Target -16.0 -TruePeak -1.0 } |
                    Should -Throw '*True Peak が不正です*'

                $counts = @{ audio = 1; video = 1; subtitle = 1; data = 1; attachment = 1 }
                $inputInventory = [pscustomobject]@{
                    Length = 100; DurationSec = 10; StreamCounts = $counts; ChapterCount = 1
                    FormatTags = [pscustomobject]@{ title = 'source' }
                    StreamTags = @([pscustomobject]@{ Type = 'video'; Tags = [pscustomobject]@{ language = 'ja' } })
                }
                $outputInventory = [pscustomobject]@{
                    Length = 0; DurationSec = 0; StreamCounts = @{ audio = 0; video = 0; subtitle = 0; data = 0; attachment = 0 }; ChapterCount = 0
                    FormatTags = [pscustomobject]@{ title = 'changed' }
                    StreamTags = @()
                }
                $comparison = Compare-MediaInventory -InputInventory $inputInventory -OutputInventory $outputInventory -Mode video
                $comparison.IsValid | Should -BeFalse
                $comparison.Errors.Count | Should -BeGreaterThan 3
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'covers remaining output safety and runtime preflight guards' {
        InModuleScope MediaNormalizer.Core {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-core-safety-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            try {
                $mediaPath = Join-Path $tmp 'voice.mp3'
                Set-Content -LiteralPath $mediaPath -Value 'fixture' -Encoding UTF8
                (Get-RelativeMediaPath -BasePath $tmp -Path (Join-Path ([IO.Path]::GetTempPath()) 'outside.mp3')) |
                    Should -Be 'outside.mp3'
                (ConvertTo-DisplayCommandArguments -Arguments @('hello world', 'a"b')) |
                    Should -Match '"hello world"'

                $other = Join-Path $tmp 'other'
                New-Item -ItemType Directory -Path $other -Force | Out-Null
                $temporary = Join-Path $other '.result.media-normalizer-temp.mp3'
                Set-Content -LiteralPath $temporary -Value 'fixture' -Encoding UTF8
                { Complete-SafeOutput -TemporaryPath $temporary -FinalPath (Join-Path $tmp 'result.mp3') } |
                    Should -Throw '*同じディレクトリ*'

                $videoInventory = [pscustomobject]@{
                    StreamCounts = @{ audio = 1; video = 0; subtitle = 0; data = 0; attachment = 0 }
                    ChapterCount = 0
                    StreamTags = @()
                }
                (Get-SpeedIntermediateProfile -Mode video -InputExtension '.avi' -Inventory $videoInventory).ProfileId |
                    Should -Be 'video-flac-mkv'

                $state = New-MediaNormalizerState
                (Resolve-UniqueOutputPath -State $state -Directory $tmp -BaseName 'voice' -Extension 'mp3' -Policy overwrite) |
                    Should -Be (Join-Path $tmp 'voice.mp3')

                $common = @{
                    State = (New-MediaNormalizerState); Mode = 'audio'; InputDir = $tmp; OutputDir = $tmp
                    Target = -16.0; TruePeak = -1.0; Bitrate = '192k'; SampleRate = '48000'
                    CollisionPolicy = 'rename'; TargetFiles = ([IO.FileInfo]$mediaPath); AnalyzeOnly = $false
                    Logger = { param($message) }
                }
                $oldRuntimeRoot = $env:MEDIA_NORMALIZER_RUNTIME_ROOT
                $oldFfmpegPath = $env:FFMPEG_PATH
                $oldFfprobePath = $env:FFPROBE_PATH
                try {
                    Remove-Item Env:FFMPEG_PATH,Env:FFPROBE_PATH -ErrorAction SilentlyContinue
                    $env:MEDIA_NORMALIZER_RUNTIME_ROOT = Join-Path $tmp 'runtime'
                    Mock Find-FfmpegNormalize { $null }
                    (Invoke-Normalize @common).Fail | Should -Be 1

                    Mock Find-FfmpegNormalize { 'ffmpeg-normalize' }
                    Mock Get-Command { $null }
                    (Invoke-Normalize @common).Fail | Should -Be 1

                    Mock Get-Command {
                        param($Name)
                        if ($Name -eq 'ffprobe') { return $null }
                        [pscustomobject]@{ Name = $Name }
                    }
                    (Invoke-Normalize @common).Fail | Should -Be 1
                } finally {
                    if ($null -eq $oldRuntimeRoot) { Remove-Item Env:MEDIA_NORMALIZER_RUNTIME_ROOT -ErrorAction SilentlyContinue }
                    else { $env:MEDIA_NORMALIZER_RUNTIME_ROOT = $oldRuntimeRoot }
                    if ($null -eq $oldFfmpegPath) { Remove-Item Env:FFMPEG_PATH -ErrorAction SilentlyContinue }
                    else { $env:FFMPEG_PATH = $oldFfmpegPath }
                    if ($null -eq $oldFfprobePath) { Remove-Item Env:FFPROBE_PATH -ErrorAction SilentlyContinue }
                    else { $env:FFPROBE_PATH = $oldFfprobePath }
                }

                $blockedParent = Join-Path $tmp 'blocked-parent'
                Set-Content -LiteralPath $blockedParent -Value 'not a directory' -Encoding UTF8
                Mock -ModuleName MediaNormalizer.Platform Get-Command { [pscustomobject]@{ Source = 'available' } }
                $createResult = Invoke-Normalize @common -OutputDir (Join-Path $blockedParent 'child')
                $createResult.Fail | Should -Be 1
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
