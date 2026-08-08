#Requires -Modules Pester

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\lib\MediaNormalizer.Probe.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\..\lib\MediaNormalizer.Progress.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\..\lib\MediaNormalizer.Core.psm1') -Force
    . (Join-Path $PSScriptRoot '..\support\fixtures\media-normalizer\New-TestMedia.ps1')
}

$ffmpegAvailable = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)

# ffmpeg-normalize の判定は「ネイティブ launcher が PATH にある」または
# 「py / python から ffmpeg_normalize モジュールが import 可能」のいずれかを満たす場合のみ true。
# py.exe 自体は PATH 上に存在しても、`pip install ffmpeg-normalize` が未実行だと
# `py -m ffmpeg_normalize` が "No module named ffmpeg_normalize" で失敗するため、
# Get-Command の存在チェックだけでは false skip にならず統合テストが実行されてしまう。
function script:Test-FfmpegNormalizeRunnable {
    foreach ($name in 'ffmpeg-normalize', 'ffmpeg-normalize.exe', 'ffmpeg-normalize.cmd', 'ffmpeg-normalize.bat') {
        if (Get-Command $name -ErrorAction SilentlyContinue) { return $true }
    }
    foreach ($interp in 'py', 'python') {
        $cmd = Get-Command $interp -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        $null = & $cmd.Source -c 'import ffmpeg_normalize' 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    return $false
}
$ffnormAvailable = script:Test-FfmpegNormalizeRunnable

Describe 'Invoke-Normalize integration' -Tag 'Integration' -Skip:(-not ($ffmpegAvailable -and $ffnormAvailable)) {
    BeforeEach {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("mn-it-" + [guid]::NewGuid().ToString('N'))
        $script:inDir = Join-Path $script:tmpRoot 'in'
        $script:outDir = Join-Path $script:tmpRoot 'out'
        New-Item -ItemType Directory -Path $script:inDir, $script:outDir -Force | Out-Null
        $script:inFile = Join-Path $script:inDir 'sample.mp4'
        New-TestMedia -OutputPath $script:inFile | Out-Null
        $script:state = New-MediaNormalizerState
        $script:state.DurationMap[$script:inFile] = Get-MediaDuration -State $script:state -FilePath $script:inFile
    }

    AfterEach {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'audioモードでmp3を生成できる' {
        $logs = New-Object System.Collections.Generic.List[string]
        $result = Invoke-Normalize `
            -State $script:state `
            -Mode audio `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -16.0 `
            -TruePeak -1.0 `
            -Bitrate '192k' `
            -SampleRate '48000' `
            -CollisionPolicy rename `
            -TargetFiles @((Get-Item -LiteralPath $script:inFile)) `
            -Logger { param($m) $logs.Add($m) | Out-Null }

        $result.Fail | Should -Be 0
        $result.Success | Should -Be 1
        (Get-ChildItem -LiteralPath $script:outDir -File -Filter *.mp3).Count | Should -Be 1
    }

    It 'audioモードで速度指定付きmp3を生成できる' {
        $logs = New-Object System.Collections.Generic.List[string]
        $result = Invoke-Normalize `
            -State $script:state `
            -Mode audio `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -16.0 `
            -TruePeak -1.0 `
            -Bitrate '192k' `
            -SampleRate '48000' `
            -CollisionPolicy rename `
            -TargetFiles @((Get-Item -LiteralPath $script:inFile)) `
            -SpeedPercent 150 `
            -Logger { param($m) $logs.Add($m) | Out-Null }

        $result.Fail | Should -Be 0
        $result.Success | Should -Be 1
        (Get-ChildItem -LiteralPath $script:outDir -File -Filter *.mp3).Count | Should -Be 1
        ($logs -join "`n") | Should -Match 'atempo=1\.5'
    }

    It '音声ファイルを直接入力してFLACを生成できる' {
        $audioPath = Join-Path $script:inDir 'direct.wav'
        New-TestAudio -OutputPath $audioPath | Out-Null
        $script:state.DurationMap[$audioPath] = Get-MediaDuration `
            -State $script:state `
            -FilePath $audioPath

        $result = Invoke-Normalize `
            -State $script:state `
            -Mode audio `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -16 `
            -TruePeak -1 `
            -Bitrate 192k `
            -SampleRate 48000 `
            -CollisionPolicy rename `
            -AudioOutputFormat flac `
            -TargetFiles @((Get-Item -LiteralPath $audioPath)) `
            -Logger { param($m) }

        $result.Fail | Should -Be 0
        $result.Success | Should -Be 1
        (Get-ChildItem -LiteralPath $script:outDir -Filter *.flac).Count |
            Should -Be 1
    }

    It '解析のみではメディアを出力せずJSONレポートを作成する' {
        $result = Invoke-Normalize `
            -State $script:state `
            -Mode audio `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -16 `
            -TruePeak -1 `
            -Bitrate 192k `
            -SampleRate 48000 `
            -CollisionPolicy rename `
            -AnalyzeOnly `
            -TargetFiles @((Get-Item -LiteralPath $script:inFile)) `
            -Logger { param($m) }

        $result.Fail | Should -Be 0
        $result.Analyzed | Should -Be 1
        (Get-ChildItem -LiteralPath $script:outDir -Filter *.mp3).Count |
            Should -Be 0
        Test-Path -LiteralPath $result.ReportPath | Should -BeTrue
        $report = Get-Content -LiteralPath $result.ReportPath -Raw |
            ConvertFrom-Json
        $report.summary.analyzed | Should -Be 1
        $report.files[0].before.streams[0].integratedLufs |
            Should -BeLessThan 0
    }

    It '既に目標内の同一形式音声は再圧縮せず同じバイト列で出力する' {
        $audioPath = Join-Path $script:inDir 'already-normal.wav'
        New-TestAudio -OutputPath $audioPath | Out-Null
        $analysis = Get-MediaLoudnessAnalysis `
            -FilePath $audioPath `
            -Target -16 `
            -TruePeak 0
        $measuredTarget = [double]$analysis.Streams[0].IntegratedLufs

        $result = Invoke-Normalize `
            -State $script:state `
            -Mode audio `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target $measuredTarget `
            -TruePeak 0 `
            -Bitrate 192k `
            -SampleRate 48000 `
            -CollisionPolicy rename `
            -AudioOutputFormat wav `
            -NormalizationTolerance 0.1 `
            -TargetFiles @((Get-Item -LiteralPath $audioPath)) `
            -Logger { param($m) }

        $result.Fail | Should -Be 0
        $result.Skipped | Should -Be 1
        $output = Get-ChildItem -LiteralPath $script:outDir -Filter *.wav |
            Select-Object -First 1
        $output | Should -Not -BeNullOrEmpty
        (Get-FileHash -LiteralPath $output.FullName -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -LiteralPath $audioPath -Algorithm SHA256).Hash
    }

    It '再帰入力の相対階層を出力先に維持する' {
        $nestedDir = Join-Path (Join-Path $script:inDir 'album') 'disc-1'
        New-Item -ItemType Directory -Path $nestedDir -Force | Out-Null
        $audioPath = Join-Path $nestedDir 'nested.wav'
        New-TestAudio -OutputPath $audioPath | Out-Null

        $result = Invoke-Normalize `
            -State $script:state `
            -Mode audio `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -16 `
            -TruePeak -1 `
            -Bitrate 192k `
            -SampleRate 48000 `
            -CollisionPolicy rename `
            -AudioOutputFormat flac `
            -TargetFiles @((Get-Item -LiteralPath $audioPath)) `
            -PreserveHierarchy:$true `
            -Logger { param($m) }

        $result.Fail | Should -Be 0
        Test-Path -LiteralPath (
            Join-Path (Join-Path (Join-Path $script:outDir 'album') 'disc-1') 'nested.flac') |
            Should -BeTrue
    }

    It '動画の複数音声・字幕・チャプター・メタデータを保持する' {
        $richPath = Join-Path $script:inDir 'rich.mp4'
        New-TestRichMedia -OutputPath $richPath | Out-Null
        $inputInventory = Get-MediaInventory -FilePath $richPath

        $result = Invoke-Normalize `
            -State $script:state `
            -Mode video `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -16 `
            -TruePeak -1 `
            -Bitrate 192k `
            -SampleRate 48000 `
            -CollisionPolicy rename `
            -TargetFiles @((Get-Item -LiteralPath $richPath)) `
            -Logger { param($m) }

        $result.Fail | Should -Be 0
        $output = Get-ChildItem -LiteralPath $script:outDir -Filter rich.mp4 |
            Select-Object -First 1
        $output | Should -Not -BeNullOrEmpty
        $outputInventory = Get-MediaInventory -FilePath $output.FullName
        $outputInventory.StreamCounts.audio |
            Should -Be $inputInventory.StreamCounts.audio
        $outputInventory.StreamCounts.subtitle |
            Should -Be $inputInventory.StreamCounts.subtitle
        $outputInventory.ChapterCount |
            Should -Be $inputInventory.ChapterCount
        $outputInventory.FormatTags.title |
            Should -Be $inputInventory.FormatTags.title
    }

    It '音声モードで保持されなかった音声トラックを警告とレポートへ残す' {
        $richPath = Join-Path $script:inDir 'rich-audio.mp4'
        New-TestRichMedia -OutputPath $richPath | Out-Null
        $logs = [Collections.Generic.List[string]]::new()

        $result = Invoke-Normalize `
            -State $script:state `
            -Mode audio `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -16 `
            -TruePeak -1 `
            -Bitrate 192k `
            -SampleRate 48000 `
            -CollisionPolicy rename `
            -AudioOutputFormat mp3 `
            -TargetFiles @((Get-Item -LiteralPath $richPath)) `
            -Logger { param($m) $logs.Add($m) | Out-Null }

        $result.Fail | Should -Be 0
        $result.Success | Should -Be 1
        $report = Get-Content -LiteralPath $result.ReportPath -Raw |
            ConvertFrom-Json
        $report.files[0].droppedAudioStreams | Should -Be 1
        $report.files[0].validation.droppedAudioStreams | Should -Be 1
        ($report.files[0].validation.warnings -join "`n") |
            Should -Match '音声トラック'
        ($logs -join "`n") | Should -Match '処理後の検証結果'
        ($logs -join "`n") | Should -Match '保持されませんでした'
    }

    It '字幕またはチャプター付き動画の速度変更は時刻ずれを避けて安全に停止する' {
        $richPath = Join-Path $script:inDir 'rich-speed.mp4'
        New-TestRichMedia -OutputPath $richPath | Out-Null
        $logs = [Collections.Generic.List[string]]::new()

        $result = Invoke-Normalize `
            -State $script:state `
            -Mode video `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -16 `
            -TruePeak -1 `
            -Bitrate 192k `
            -SampleRate 48000 `
            -CollisionPolicy rename `
            -SpeedPercent 150 `
            -TargetFiles @((Get-Item -LiteralPath $richPath)) `
            -Logger { param($m) $logs.Add($m) | Out-Null }

        $result.Fail | Should -Be 1
        $result.Success | Should -Be 0
        ($logs -join "`n") | Should -Match '再生速度100%'
        (Get-ChildItem -LiteralPath $script:outDir -Filter rich-speed.mp4).Count |
            Should -Be 0
    }

    It '速度変更付き動画を<SpeedPercent>%で正規化できる（AC-7）' -Tag 'Slow' -ForEach @(
        @{ SpeedPercent = 50 },
        @{ SpeedPercent = 150 },
        @{ SpeedPercent = 200 }
    ) {
        $speedPath = Join-Path $script:inDir "speedable-$SpeedPercent.mp4"
        New-TestSpeedableMedia -OutputPath $speedPath -DurationSec 5 | Out-Null
        $inputInventory = Get-MediaInventory -FilePath $speedPath
        $logs = [Collections.Generic.List[string]]::new()

        $result = Invoke-Normalize `
            -State $script:state `
            -Mode video `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -16.0 `
            -TruePeak -1.0 `
            -Bitrate '192k' `
            -SampleRate '48000' `
            -CollisionPolicy rename `
            -SpeedPercent $SpeedPercent `
            -TargetFiles @((Get-Item -LiteralPath $speedPath)) `
            -Logger { param($m) $logs.Add($m) | Out-Null }

        $result.Fail | Should -Be 0
        $result.Success | Should -Be 1

        $output = Get-ChildItem -LiteralPath $script:outDir -Filter "speedable-$SpeedPercent.mp4" |
            Select-Object -First 1
        $output | Should -Not -BeNullOrEmpty

        $outputInventory = Get-MediaInventory -FilePath $output.FullName
        $expectedDuration = $inputInventory.DurationSec / ($SpeedPercent / 100.0)
        [math]::Abs($outputInventory.DurationSec - $expectedDuration) |
            Should -BeLessOrEqual 0.5

        $report = Get-Content -LiteralPath $result.ReportPath -Raw | ConvertFrom-Json
        $record = @($report.files | Where-Object { $_.inputPath -like "*speedable-$SpeedPercent.mp4" }) |
            Select-Object -First 1
        $record | Should -Not -BeNullOrEmpty
        [math]::Abs([double]$record.after.streams[0].integratedLufs - (-16.0)) |
            Should -BeLessOrEqual 1.0
        [double]$record.after.streams[0].truePeakDbtp | Should -BeLessOrEqual (-1.0 + 0.4)
        $record.validation.IsValid | Should -BeTrue

        ($logs -join "`n") | Should -Match '\-t\s+-16\.0'
        ($logs -join "`n") | Should -Match '\-tp\s+-1\.0'

        $outputInventory.StreamCounts.audio | Should -Be $inputInventory.StreamCounts.audio
        $outputInventory.StreamCounts.video | Should -Be $inputInventory.StreamCounts.video
        $outputInventory.FormatTags.title | Should -Be $inputInventory.FormatTags.title
    }

    It '速度変更付き動画の音声が二重にAACエンコードされない' -Tag 'Slow' {
        $speedPath = Join-Path $script:inDir 'no-double-aac.mp4'
        New-TestSpeedableMedia -OutputPath $speedPath -DurationSec 5 | Out-Null
        $logs = [Collections.Generic.List[string]]::new()

        $result = Invoke-Normalize `
            -State $script:state `
            -Mode video `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -16.0 `
            -TruePeak -1.0 `
            -Bitrate '192k' `
            -SampleRate '48000' `
            -CollisionPolicy rename `
            -SpeedPercent 150 `
            -TargetFiles @((Get-Item -LiteralPath $speedPath)) `
            -Logger { param($m) $logs.Add($m) | Out-Null }

        $result.Fail | Should -Be 0

        $cmdLines = @($logs | Where-Object { $_ -match '^\s*\[CMD\]' })
        $speedCmdLine = @($cmdLines | Where-Object { $_ -match 'setpts=' }) | Select-Object -First 1
        $speedCmdLine | Should -Not -BeNullOrEmpty
        $speedCmdLine | Should -Not -Match '\-c:a aac'
        $speedCmdLine | Should -Match '\-c:a (alac|flac|pcm_\w+)'

        $allCmdText = ($cmdLines -join "`n")
        ($allCmdText | Select-String -Pattern '\-c:a aac' -AllMatches).Matches.Count |
            Should -Be 1
    }

    It '速度変更中のキャンセル後に最終出力と中間ファイルが残らない' -Tag 'Slow' {
        # 速度変更プロセス実行中に確実にキャンセルを間に合わせるため、5秒ではなく60秒素材を使う
        # (実測: 5秒素材は速度変更が100ms未満で完了しPumpEventsのポーリングに間に合わないことがある。
        #  60秒素材なら速度変更処理は約0.8秒かかり、100ms間隔ポーリングで確実に捕捉できる)。
        $speedPath = Join-Path $script:inDir 'cancel-speed.mp4'
        New-TestSpeedableMedia -OutputPath $speedPath -DurationSec 60 | Out-Null
        $logs = [Collections.Generic.List[string]]::new()
        $script:speedCommandSeen = $false
        $script:cancelSet = $false

        $result = Invoke-Normalize `
            -State $script:state `
            -Mode video `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -16.0 `
            -TruePeak -1.0 `
            -Bitrate '192k' `
            -SampleRate '48000' `
            -CollisionPolicy rename `
            -SpeedPercent 150 `
            -TargetFiles @((Get-Item -LiteralPath $speedPath)) `
            -Logger {
                param($m)
                $logs.Add($m) | Out-Null
                if ($m -match '\[CMD\].*setpts=') { $script:speedCommandSeen = $true }
            } `
            -PumpEvents {
                if ($script:speedCommandSeen -and -not $script:cancelSet) {
                    $script:state.CancelRequested = $true
                    $script:cancelSet = $true
                }
            }

        $result.Cancelled | Should -Be 1

        $cmdLine = @($logs | Where-Object { $_ -match '\[CMD\].*setpts=' }) | Select-Object -First 1
        $cmdLine | Should -Not -BeNullOrEmpty
        ($cmdLine -match '(media-normalizer-speed-[0-9a-fA-F]+\.\w+)') | Should -BeTrue
        $tempFileName = $Matches[1]
        $tempPath = Join-Path ([IO.Path]::GetTempPath()) $tempFileName
        Test-Path -LiteralPath $tempPath | Should -BeFalse

        (Get-ChildItem -LiteralPath $script:outDir -Filter 'cancel-speed.mp4' -ErrorAction SilentlyContinue).Count |
            Should -Be 0
        (Get-ChildItem -LiteralPath $script:outDir -Filter '.cancel-speed.*' -Force -ErrorAction SilentlyContinue).Count |
            Should -Be 0
    }

    It '正規化中のキャンセル後に最終出力と中間ファイルが残らない' -Tag 'Slow' {
        $speedPath = Join-Path $script:inDir 'cancel-normalize.mp4'
        New-TestSpeedableMedia -OutputPath $speedPath -DurationSec 5 | Out-Null
        $logs = [Collections.Generic.List[string]]::new()
        $script:speedTempPath = $null
        $script:normalizeCommandSeen = $false
        $script:cancelSet = $false

        $result = Invoke-Normalize `
            -State $script:state `
            -Mode video `
            -InputDir $script:inDir `
            -OutputDir $script:outDir `
            -Target -16.0 `
            -TruePeak -1.0 `
            -Bitrate '192k' `
            -SampleRate '48000' `
            -CollisionPolicy rename `
            -SpeedPercent 150 `
            -TargetFiles @((Get-Item -LiteralPath $speedPath)) `
            -Logger {
                param($m)
                $logs.Add($m) | Out-Null
                if ($m -match '\[CMD\].*setpts=' -and $m -match '(media-normalizer-speed-[0-9a-fA-F]+\.\w+)') {
                    $script:speedTempPath = Join-Path ([IO.Path]::GetTempPath()) $Matches[1]
                }
                if ($m -match '^\s*\[CMD\]' -and $m -notmatch 'setpts=') {
                    $script:normalizeCommandSeen = $true
                }
            } `
            -PumpEvents {
                if ($script:normalizeCommandSeen -and -not $script:cancelSet) {
                    $script:state.CancelRequested = $true
                    $script:cancelSet = $true
                }
            }

        $result.Cancelled | Should -Be 1
        $script:speedTempPath | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $script:speedTempPath | Should -BeFalse
        (Get-ChildItem -LiteralPath $script:outDir -Filter 'cancel-normalize.mp4' -ErrorAction SilentlyContinue).Count |
            Should -Be 0
        (Get-ChildItem -LiteralPath $script:outDir -Filter '.cancel-normalize.*' -Force -ErrorAction SilentlyContinue).Count |
            Should -Be 0
    }
}
