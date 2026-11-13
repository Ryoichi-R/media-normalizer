#Requires -Modules Pester

Set-StrictMode -Version Latest

# Mac output-selection path (1.2.0): scan classification, planned destinations,
# input protection, revalidation, analysis-only, and scan cancellation/timeout,
# exercised through scripts/mn-worker.ps1 with real ffmpeg/ffprobe/ffmpeg-normalize.

BeforeAll {
    $script:repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:workerPath = Join-Path $script:repoRoot 'scripts/mn-worker.ps1'
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.WorkerProtocol.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'tests/support/WorkerProtocolDriver.psm1') -Force

    function New-PlannedMedia {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Arguments)
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
        & ffmpeg -hide_banner -loglevel error -y @Arguments $Path
        if ($LASTEXITCODE -ne 0) { throw "test media generation failed: $Path" }
        return $Path
    }

    $script:video = @('-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=25:duration=4')
    $script:tone = @('-f', 'lavfi', '-i', 'sine=frequency=440:duration=4')
    $script:h264 = @('-c:v', 'libx264', '-pix_fmt', 'yuv420p')

    function New-AvMedia([string]$Path) { New-PlannedMedia $Path ($script:video + $script:tone + $script:h264 + @('-c:a', 'aac', '-shortest')) }
    function New-ToneMedia([string]$Path, [int]$Frequency = 440) {
        New-PlannedMedia $Path @('-f', 'lavfi', '-i', "sine=frequency=$($Frequency):duration=4")
    }

    function Invoke-PlannedWorker {
        param([Collections.IDictionary]$Command, [scriptblock]$OnEvent, [int]$TimeoutSeconds = 180)
        $result = Invoke-WorkerProtocolCommand -WorkerPath $script:workerPath -StorageRoot (Join-Path $TestDrive 'state') `
            -Command $Command -OnEvent $OnEvent -TimeoutSeconds $TimeoutSeconds
        $invalid = @($result.Events | Where-Object { -not (Test-MediaNormalizerWorkerEvent -Message $_).IsValid })
        $invalid | Should -BeNullOrEmpty -Because 'every worker event must satisfy the protocol contract'
        return $result
    }

    function Invoke-PlannedScan([Collections.IDictionary]$Command) {
        $result = Invoke-PlannedWorker -Command $Command
        $result.ExitCode | Should -Be 0
        $scanResult = @($result.Events | Where-Object { $_.type -eq 'scan-result' })
        $scanResult.Count | Should -Be 1
        return $scanResult[0]
    }

    function Get-Row([Collections.IDictionary]$ScanResult, [string]$Path) {
        $rows = @($ScanResult.files | Where-Object { $_.path -eq $Path })
        $rows.Count | Should -Be 1 -Because "$Path must appear once in the scan result"
        return $rows[0]
    }

    function Get-RunDone($Result) { @($Result.Events | Where-Object { $_.type -eq 'run-done' })[-1] }
    function Get-FileDone($Result, [string]$Path) { @($Result.Events | Where-Object { $_.type -eq 'file-done' -and $_.inputPath -eq $Path })[-1] }

    function Get-InputProbeCount($Result, [string]$Path) {
        @($Result.Events | Where-Object {
                $_.type -eq 'process-starting' -and [IO.Path]::GetFileNameWithoutExtension($_.executablePath) -eq 'ffprobe' -and
                $_.arguments -contains $Path
            }).Count
    }

    function Get-InputProcessCount($Result, [string]$Path) {
        @($Result.Events | Where-Object { $_.type -eq 'process-starting' -and $_.arguments -contains $Path }).Count
    }

    function Get-StreamKinds([string]$Path) {
        $streams = (& ffprobe -v error -show_entries stream=codec_type,codec_name -of json $Path | ConvertFrom-Json).streams
        return @($streams | ForEach-Object { "$($_.codec_type):$($_.codec_name)" })
    }

    function Get-MediaOutputs([string]$Directory) {
        if (-not (Test-Path -LiteralPath $Directory)) { return @() }
        return @(Get-ChildItem -LiteralPath $Directory -File -Recurse -Force |
                Where-Object { $_.Name -notlike 'media-normalizer-report-*' } |
                ForEach-Object { [IO.Path]::GetRelativePath($Directory, $_.FullName) } | Sort-Object)
    }
}

$script:toolsAvailable = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue) -and
[bool](Get-Command ffprobe -ErrorAction SilentlyContinue) -and (& {
        foreach ($name in 'ffmpeg-normalize', 'ffmpeg-normalize.exe') {
            if (Get-Command $name -ErrorAction SilentlyContinue) { return $true }
        }
        foreach ($interpreter in 'python3', 'python', 'py') {
            $command = Get-Command $interpreter -ErrorAction SilentlyContinue
            if (-not $command) { continue }
            $null = & $command.Source -c 'import ffmpeg_normalize' 2>&1
            if ($LASTEXITCODE -eq 0) { return $true }
        }
        return $false
    })
$script:posix = -not $IsWindows

Describe 'Planned output selection through the worker' -Tag 'Integration' -Skip:(-not $script:toolsAvailable) {
    It 'reports target failure without replacing an output, and reports a separate report-write failure' {
        $source = New-ToneMedia (Join-Path $TestDrive 'quality/in/tone.wav')
        $outputDir = (New-Item -ItemType Directory (Join-Path $TestDrive 'quality/out') -Force).FullName
        $destination = Join-Path $outputDir 'tone.wav'
        [IO.File]::Copy($source, $destination)
        $original = (Get-FileHash -LiteralPath $destination).Hash
        $scan = New-WorkerPlannedScanCommand -Paths @($source) -OutputSelection wav -OutputDir $outputDir -CollisionPolicy overwrite
        $scanResult = Invoke-PlannedScan $scan

        $command = New-WorkerPlannedNormalizeCommand -Scan $scan -ScanResult $scanResult -SelectedPaths @($source)
        $command.target = -5
        $command.truePeak = -9
        $failure = Invoke-PlannedWorker $command
        $failure.ExitCode | Should -Be 1
        (Get-RunDone $failure).fail | Should -Be 1
        (Get-FileDone $failure $source).status | Should -Be 'failed'
        (Get-FileDone $failure $source).outputPath | Should -BeNullOrEmpty
        (Get-FileHash -LiteralPath $destination).Hash | Should -Be $original

        $command = New-WorkerPlannedNormalizeCommand -Scan $scan -ScanResult $scanResult -SelectedPaths @($source)
        $command.reportPath = (New-Item -ItemType Directory (Join-Path $outputDir 'blocked.json')).FullName
        $reportFailure = Invoke-PlannedWorker $command
        $reportFailure.ExitCode | Should -Be 1
        (Get-RunDone $reportFailure).success | Should -Be 1
        (Get-RunDone $reportFailure).reportSucceeded | Should -BeFalse
        (Get-FileDone $reportFailure $source).status | Should -Be 'normalized'
        (Get-FileHash -LiteralPath $destination).Hash | Should -Not -Be $original
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $original
    }

    It 'writes only the explicitly selected format at 140% speed (<Selection>)' -ForEach @(
        @{ Selection = 'mp3'; Expected = @('clip.mp3'); Streams = @('audio:mp3') }
        @{ Selection = 'mp4'; Expected = @('clip.mp4'); Streams = @('video:h264', 'audio:aac') }
    ) {
        $inputDir = Join-Path $TestDrive "repro-$Selection/in"
        $outputDir = Join-Path $TestDrive "repro-$Selection/out"
        $source = New-AvMedia (Join-Path $inputDir 'clip.mp4')
        $scan = New-WorkerPlannedScanCommand -Paths @($inputDir) -OutputSelection $Selection -OutputDir $outputDir
        $scanResult = Invoke-PlannedScan $scan
        (Get-Row $scanResult $source).formats | Should -Be @($Selection)

        $run = Invoke-PlannedWorker (New-WorkerPlannedNormalizeCommand -Scan $scan -ScanResult $scanResult -SelectedPaths @($source) -SpeedPercent 140)

        $run.ExitCode | Should -Be 0
        (Get-RunDone $run).success | Should -Be 1
        Get-MediaOutputs $outputDir | Should -Be $Expected
        Get-StreamKinds (Join-Path $outputDir $Expected[0]) | Should -Be $Streams
    }

    It 'classifies mixed inputs by streams instead of extensions' {
        $inputDir = Join-Path $TestDrive 'mixed/in'
        $paths = @{
            mp4 = New-AvMedia (Join-Path $inputDir 'v.mp4')
            mov = New-AvMedia (Join-Path $inputDir 'v.mov')
            mkv = New-PlannedMedia (Join-Path $inputDir 'two-audio.mkv') ($script:video + $script:tone + @('-f', 'lavfi', '-i', 'sine=frequency=880:duration=4', '-map', '0:v', '-map', '1:a', '-map', '2:a') + $script:h264 + @('-c:a', 'aac', '-shortest'))
            avi = New-PlannedMedia (Join-Path $inputDir 'v.avi') ($script:video + $script:tone + @('-c:v', 'mpeg4', '-c:a', 'mp3', '-shortest'))
            wav = New-ToneMedia (Join-Path $inputDir 'w.wav')
            audioMp4 = New-PlannedMedia (Join-Path $inputDir 'audio-only.mp4') ($script:tone + @('-c:a', 'aac'))
            videoOnly = New-PlannedMedia (Join-Path $inputDir 'video-only.mov') ($script:video + $script:h264)
            empty = Join-Path $inputDir 'empty.wav'
            mismatch = Join-Path $inputDir 'mismatch.mp4'
        }
        $cover = New-PlannedMedia (Join-Path $TestDrive 'mixed/cover.png') @('-f', 'lavfi', '-i', 'color=c=red:s=64x64', '-frames:v', '1')
        $paths.coverMp3 = New-PlannedMedia (Join-Path $inputDir 'cover.mp3') ($script:tone + @('-i', $cover, '-map', '0:a', '-map', '1:v', '-c:a', 'libmp3lame', '-c:v', 'mjpeg', '-disposition:v', 'attached_pic', '-id3v2_version', '3'))
        [IO.File]::WriteAllBytes($paths.empty, [byte[]]@())
        Copy-Item -LiteralPath $paths.wav -Destination $paths.mismatch

        $auto = Invoke-PlannedScan (New-WorkerPlannedScanCommand -Paths @($inputDir) -OutputSelection 'auto' -OutputDir (Join-Path $TestDrive 'mixed/out'))
        $expected = @{
            mp4 = @('video', 'mp4'); mov = @('video', 'mov'); mkv = @('video', 'mkv'); avi = @('video', 'mp3')
            wav = @('audio', 'mp3'); audioMp4 = @('audio', 'mp3'); coverMp3 = @('audio', 'mp3'); mismatch = @('audio', 'mp3')
        }
        foreach ($key in $expected.Keys) {
            $row = Get-Row $auto $paths[$key]
            @($row.kind, @($row.formats)) | Should -Be $expected[$key] -Because $key
            $row.reason | Should -BeNullOrEmpty -Because $key
        }
        (Get-Row $auto $paths.avi).warning | Should -Be '映像は出力されません。'
        (Get-Row $auto $paths.videoOnly).reason | Should -Be '音声トラックがありません。'
        (Get-Row $auto $paths.empty).reason | Should -Not -BeNullOrEmpty
        @((Get-Row $auto $paths.empty).formats).Count | Should -Be 0

        $mp4 = Invoke-PlannedScan (New-WorkerPlannedScanCommand -Paths @($inputDir) -OutputSelection 'mp4' -OutputDir (Join-Path $TestDrive 'mixed/out-mp4'))
        (Get-Row $mp4 $paths.mp4).formats | Should -Be @('mp4')
        foreach ($key in 'mov', 'mkv', 'avi') { (Get-Row $mp4 $paths[$key]).reason | Should -Be 'この形式からの MP4 変換は未対応です。' }
        foreach ($key in 'wav', 'audioMp4', 'coverMp3') { (Get-Row $mp4 $paths[$key]).reason | Should -Be '映像がありません。' }

        $both = Invoke-PlannedScan (New-WorkerPlannedScanCommand -Paths @($inputDir) -OutputSelection 'audio-and-video' -OutputDir (Join-Path $TestDrive 'mixed/out-both'))
        (Get-Row $both $paths.mkv).formats | Should -Be @('mp3', 'mkv')
        (Get-Row $both $paths.wav).formats | Should -Be @('mp3')
    }

    It 'separates same-name outputs within one run under <Policy>' -ForEach @(
        @{ Policy = 'rename'; Outputs = @('a (2).mp3', 'a.mp3'); Success = 2; Skipped = 0 }
        @{ Policy = 'overwrite'; Outputs = @('a (2).mp3', 'a.mp3'); Success = 2; Skipped = 0 }
        @{ Policy = 'skip'; Outputs = @('a.mp3'); Success = 1; Skipped = 1 }
    ) {
        $inputDir = Join-Path $TestDrive "dup-$Policy/in"
        $outputDir = Join-Path $TestDrive "dup-$Policy/out"
        $video = New-AvMedia (Join-Path $inputDir 'a.mp4')
        $audio = New-ToneMedia (Join-Path $inputDir 'a.wav') 660
        $scan = New-WorkerPlannedScanCommand -Paths @($inputDir) -OutputSelection 'mp3' -OutputDir $outputDir -CollisionPolicy $Policy
        $scanResult = Invoke-PlannedScan $scan
        (Get-Row $scanResult $video).destinations | Should -Be @((Join-Path $outputDir 'a.mp3'))
        (Get-Row $scanResult $audio).destinations | Should -Be @((Join-Path $outputDir 'a.mp3'))

        $run = Invoke-PlannedWorker (New-WorkerPlannedNormalizeCommand -Scan $scan -ScanResult $scanResult -SelectedPaths @($video, $audio))

        (Get-RunDone $run).success | Should -Be $Success
        (Get-RunDone $run).skipped | Should -Be $Skipped
        (Get-FileDone $run $video).outputPath | Should -Be (Join-Path $outputDir 'a.mp3')
        Get-MediaOutputs $outputDir | Should -Be $Outputs
    }

    It 'protects an unselected input original in the output folder under <Policy>' -ForEach @(
        @{ Policy = 'overwrite'; Status = 'failed'; Outputs = @('a.mp3', 'a.wav') }
        @{ Policy = 'rename'; Status = 'normalized'; Outputs = @('a (2).mp3', 'a.mp3', 'a.wav') }
        @{ Policy = 'skip'; Status = 'skipped'; Outputs = @('a.mp3', 'a.wav') }
    ) {
        $folder = Join-Path $TestDrive "protect-$Policy"
        $selected = New-ToneMedia (Join-Path $folder 'a.wav') 500
        $original = New-ToneMedia (Join-Path $folder 'a.mp3') 300
        $before = (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash
        $scan = New-WorkerPlannedScanCommand -Paths @($folder) -OutputSelection 'mp3' -OutputDir $folder -CollisionPolicy $Policy
        $scanResult = Invoke-PlannedScan $scan
        (Get-Row $scanResult $selected).warning | Should -Be '出力予定名が入力原本と重複しています。'
        if ($Policy -eq 'overwrite') { (Get-Row $scanResult $selected).reason | Should -Be '出力予定名が入力原本と重複しています。' }

        $run = Invoke-PlannedWorker (New-WorkerPlannedNormalizeCommand -Scan $scan -ScanResult $scanResult -SelectedPaths @($selected))

        (Get-FileDone $run $selected).status | Should -Be $Status
        if ($Policy -eq 'overwrite') { (Get-FileDone $run $selected).message | Should -BeLike '出力先が入力原本を指しています*' }
        (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash | Should -Be $before
        @(Get-ChildItem -LiteralPath $folder -File -Force | Where-Object { $_.Name -notlike 'media-normalizer-report-*' } | ForEach-Object Name | Sort-Object) |
            Should -Be $Outputs
    }

    It 'refuses a destination that becomes a link to an input original before finalization' -Skip:(-not $script:posix) {
        $inputDir = Join-Path $TestDrive 'race/in'
        $outputDir = Join-Path $TestDrive 'race/out'
        $selected = New-ToneMedia (Join-Path $inputDir 'a.wav') 500
        $original = New-ToneMedia (Join-Path $inputDir 'keep/a.mp3') 300
        $before = (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash
        $scan = New-WorkerPlannedScanCommand -Paths @($inputDir) -OutputSelection 'mp3' -OutputDir $outputDir -CollisionPolicy 'overwrite' -PreserveHierarchy $false
        $scanResult = Invoke-PlannedScan $scan
        $script:linked = $false

        $run = Invoke-PlannedWorker -Command (New-WorkerPlannedNormalizeCommand -Scan $scan -ScanResult $scanResult -SelectedPaths @($selected)) -OnEvent {
            param($workerEvent, $send)
            if ($workerEvent.type -eq 'temporary-output' -and $workerEvent.role -eq 'primary' -and -not $script:linked) {
                $null = New-Item -ItemType SymbolicLink -Path $workerEvent.finalPath -Target $original
                $script:linked = $true
            }
        }

        $script:linked | Should -BeTrue
        (Get-FileDone $run $selected).status | Should -Be 'failed'
        (Get-FileDone $run $selected).message | Should -BeLike '出力先が入力原本を指しています*'
        (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash | Should -Be $before
        (Get-Item -LiteralPath (Join-Path $outputDir 'a.mp3') -Force).LinkType | Should -Be 'SymbolicLink'
        @(Get-ChildItem -LiteralPath $outputDir -Force -File | Where-Object { $_.Name -like '.*media-normalizer-*' }) | Should -BeNullOrEmpty
    }

    It 'keeps the scan input root when one child file is selected' {
        $inputDir = Join-Path $TestDrive 'root/in'
        $outputDir = Join-Path $TestDrive 'root/out'
        $child = New-ToneMedia (Join-Path $inputDir 'x/song.wav') 500
        $sibling = New-ToneMedia (Join-Path $inputDir 'y/song.wav') 520
        $null = New-ToneMedia (Join-Path $inputDir 'top.wav') 540
        $scan = New-WorkerPlannedScanCommand -Paths @($inputDir) -OutputSelection 'mp3' -OutputDir $outputDir
        $scanResult = Invoke-PlannedScan $scan
        $scanResult.inputRoot | Should -Be $inputDir
        (Get-Row $scanResult $child).destinations | Should -Be @((Join-Path $outputDir 'x/song.mp3'))

        $run = Invoke-PlannedWorker (New-WorkerPlannedNormalizeCommand -Scan $scan -ScanResult $scanResult -SelectedPaths @($child))

        (Get-FileDone $run $child).outputPath | Should -Be (Join-Path $outputDir 'x/song.mp3')
        Get-MediaOutputs $outputDir | Should -Be @((Join-Path 'x' 'song.mp3'))

        $flat = Invoke-PlannedScan (New-WorkerPlannedScanCommand -Paths @($inputDir) -OutputSelection 'mp3' -OutputDir $outputDir -PreserveHierarchy $false)
        (Get-Row $flat $child).destinations | Should -Be @((Join-Path $outputDir 'song.mp3'))
        (Get-Row $flat $sibling).destinations | Should -Be @((Join-Path $outputDir 'song.mp3'))
    }

    It 'fails only inputs changed after scanning and probes unchanged inputs once' {
        $inputDir = Join-Path $TestDrive 'revalidate/in'
        $outputDir = Join-Path $TestDrive 'revalidate/out'
        $keep = New-ToneMedia (Join-Path $inputDir 'keep.wav') 500
        $changed = New-ToneMedia (Join-Path $inputDir 'changed.wav') 520
        $gone = New-ToneMedia (Join-Path $inputDir 'gone.wav') 540
        $scan = New-WorkerPlannedScanCommand -Paths @($inputDir) -OutputSelection 'mp3' -OutputDir $outputDir
        $scanResult = Invoke-PlannedScan $scan
        $command = New-WorkerPlannedNormalizeCommand -Scan $scan -ScanResult $scanResult -SelectedPaths @($keep, $changed, $gone)
        [IO.File]::AppendAllText($changed, 'x')
        Remove-Item -LiteralPath $gone

        $run = Invoke-PlannedWorker $command

        foreach ($path in $changed, $gone) {
            (Get-FileDone $run $path).status | Should -Be 'failed'
            (Get-FileDone $run $path).message | Should -BeLike '入力が変更されたか見つかりません。*'
            Get-InputProcessCount $run $path | Should -Be 0 -Because 'no analysis or temporary output may start for a rejected input'
        }
        (Get-FileDone $run $keep).status | Should -Be 'normalized'
        Get-InputProbeCount $run $keep | Should -Be 1
        (Get-RunDone $run).fail | Should -Be 2
        $report = Get-Content -LiteralPath (Get-RunDone $run).reportPath -Raw | ConvertFrom-Json
        $report.summary.failed | Should -Be 2
        $report.summary.normalized | Should -Be 1
    }

    It 'compares the targets of symbolic links before starting analysis' -Skip:(-not $script:posix) {
        $inputDir = Join-Path $TestDrive 'link-target/in'
        $outputDir = Join-Path $TestDrive 'link-target/out'
        $keepTarget = New-ToneMedia (Join-Path $TestDrive 'link-target/keep.wav') 500
        $changedTarget = New-ToneMedia (Join-Path $TestDrive 'link-target/changed.wav') 520
        $goneTarget = New-ToneMedia (Join-Path $TestDrive 'link-target/gone.wav') 540
        $null = New-Item -ItemType Directory -Path $inputDir
        $keep = Join-Path $inputDir 'keep.wav'
        $changed = Join-Path $inputDir 'changed.wav'
        $gone = Join-Path $inputDir 'gone.wav'
        $null = New-Item -ItemType SymbolicLink -Path $keep -Target $keepTarget
        $null = New-Item -ItemType SymbolicLink -Path $changed -Target $changedTarget
        $null = New-Item -ItemType SymbolicLink -Path $gone -Target $goneTarget
        $scan = New-WorkerPlannedScanCommand -Paths @($inputDir) -OutputSelection 'mp3' -OutputDir $outputDir
        $scanResult = Invoke-PlannedScan $scan
        (Get-Row $scanResult $changed).size | Should -Be (Get-Item -LiteralPath $changedTarget).Length
        $command = New-WorkerPlannedNormalizeCommand -Scan $scan -ScanResult $scanResult -SelectedPaths @($keep, $changed, $gone)

        $null = New-PlannedMedia $changedTarget @('-f', 'lavfi', '-i', 'sine=frequency=520:duration=5')
        Move-Item -LiteralPath $goneTarget -Destination (Join-Path $TestDrive 'link-target/relocated.wav')
        $run = Invoke-PlannedWorker $command

        foreach ($link in $changed, $gone) {
            (Get-FileDone $run $link).status | Should -Be 'failed'
            (Get-FileDone $run $link).message | Should -BeLike '入力が変更されたか見つかりません。*'
            Get-InputProcessCount $run $link | Should -Be 0
        }
        (Get-FileDone $run $keep).status | Should -Be 'normalized'
        Get-MediaOutputs $outputDir | Should -Be @('keep.mp3')
    }

    It 'reuses one input probe for audio and video outputs' {
        $inputDir = Join-Path $TestDrive 'two/in'
        $outputDir = Join-Path $TestDrive 'two/out'
        $source = New-AvMedia (Join-Path $inputDir 'v.mp4')
        $scan = New-WorkerPlannedScanCommand -Paths @($inputDir) -OutputSelection 'audio-and-video' -OutputDir $outputDir
        $scanResult = Invoke-PlannedScan $scan
        (Get-Row $scanResult $source).formats | Should -Be @('mp3', 'mp4')

        $run = Invoke-PlannedWorker (New-WorkerPlannedNormalizeCommand -Scan $scan -ScanResult $scanResult -SelectedPaths @($source))

        (Get-RunDone $run).success | Should -Be 2
        Get-InputProbeCount $run $source | Should -Be 1
        Get-MediaOutputs $outputDir | Should -Be @('v.mp3', 'v.mp4')
        Get-StreamKinds (Join-Path $outputDir 'v.mp3') | Should -Be @('audio:mp3')
        Get-StreamKinds (Join-Path $outputDir 'v.mp4') | Should -Be @('video:h264', 'audio:aac')
    }

    It 'analyzes original audio regardless of explicit MP4 and speed' {
        $inputDir = Join-Path $TestDrive 'analyze/in'
        $outputDir = Join-Path $TestDrive 'analyze/out'
        $subtitle = Join-Path $TestDrive 'analyze/sub.srt'
        $null = New-Item -ItemType Directory -Path $inputDir -Force
        Set-Content -LiteralPath $subtitle -Value "1`n00:00:01,000 --> 00:00:02,000`nhello`n" -Encoding utf8NoBOM
        $mov = New-PlannedMedia (Join-Path $inputDir 'subbed.mov') ($script:video + $script:tone + @('-i', $subtitle, '-map', '0:v', '-map', '1:a', '-map', '2:s') + $script:h264 + @('-c:a', 'aac', '-c:s', 'mov_text', '-shortest'))
        $wav = New-ToneMedia (Join-Path $inputDir 'tone.wav')
        $silent = New-PlannedMedia (Join-Path $inputDir 'silent.mp4') ($script:video + $script:h264)
        $broken = Join-Path $inputDir 'broken.mp3'
        Set-Content -LiteralPath $broken -Value 'not media' -Encoding ascii
        $scan = New-WorkerPlannedScanCommand -Paths @($inputDir) -OutputSelection 'mp4' -OutputDir $outputDir -AnalyzeOnly
        $scanResult = Invoke-PlannedScan $scan
        foreach ($path in $mov, $wav) { (Get-Row $scanResult $path).reason | Should -BeNullOrEmpty }
        (Get-Row $scanResult $silent).reason | Should -Be '音声トラックがありません。'
        (Get-Row $scanResult $broken).reason | Should -Not -BeNullOrEmpty

        $run = Invoke-PlannedWorker (New-WorkerPlannedNormalizeCommand -Scan $scan -ScanResult $scanResult -SelectedPaths @($mov, $wav) -SpeedPercent 140)

        (Get-RunDone $run).analyzed | Should -Be 2
        Get-MediaOutputs $outputDir | Should -BeNullOrEmpty
        $report = Get-Content -LiteralPath (Get-RunDone $run).reportPath -Raw | ConvertFrom-Json
        $report.summary.analyzed | Should -Be 2
        foreach ($file in $report.files) { @($file.before.Streams)[0].IntegratedLufs | Should -BeOfType [double] }
    }

    It 'returns a cancelled scan without rows or leftover probes' {
        $inputDir = Join-Path $TestDrive 'cancel/in'
        foreach ($index in 1..8) { $null = New-ToneMedia (Join-Path $inputDir "t$index.wav") (300 + $index * 10) }
        $scan = New-WorkerPlannedScanCommand -Paths @($inputDir) -OutputSelection 'mp3' -OutputDir (Join-Path $TestDrive 'cancel/out')
        $script:started = 0
        $script:cancelSent = $false

        $run = Invoke-PlannedWorker -Command $scan -OnEvent {
            param($workerEvent, $send)
            if ($workerEvent.type -eq 'process-started') { $script:started++ }
            if ($script:started -ge 2 -and -not $script:cancelSent) {
                $script:cancelSent = $true
                & $send ([ordered]@{ schemaVersion = 1; id = [guid]::NewGuid().ToString(); cmd = 'cancel'; runId = $scan.runId })
            }
        }

        $run.ExitCode | Should -Be 0
        $result = @($run.Events | Where-Object { $_.type -eq 'scan-result' })[0]
        $result.status | Should -Be 'cancelled'
        @($result.files).Count | Should -Be 0
        @($run.Events | Where-Object { $_.Contains('runId') -and $_.runId -ne $scan.runId }) | Should -BeNullOrEmpty
        @($run.Events | Where-Object { $_.type -eq 'process-exited' }).Count |
            Should -Be @($run.Events | Where-Object { $_.type -eq 'process-started' }).Count
        if ($script:posix) {
            @(& ps -axo command= | Where-Object { $_ -like "*$inputDir*" }) | Should -BeNullOrEmpty
        }
        $rescan = Invoke-PlannedScan (New-WorkerPlannedScanCommand -Paths @($inputDir) -OutputSelection 'mp3' -OutputDir (Join-Path $TestDrive 'cancel/out'))
        $rescan.status | Should -Be 'completed'
        @($rescan.files).Count | Should -Be 8
    }

    It 'reports a probe timeout on its own row and completes later rows' -Tag 'Slow' -Skip:(-not $script:posix) {
        $inputDir = Join-Path $TestDrive 'timeout/in'
        $null = New-Item -ItemType Directory -Path $inputDir -Force
        $hanging = Join-Path $inputDir 'a-hang.wav'
        & mkfifo $hanging
        $healthy = New-ToneMedia (Join-Path $inputDir 'b-ok.wav')
        try {
            $result = Invoke-PlannedScan (New-WorkerPlannedScanCommand -Paths @($inputDir) -OutputSelection 'mp3' -OutputDir (Join-Path $TestDrive 'timeout/out'))
        } finally {
            Remove-Item -LiteralPath $hanging -Force
        }

        $result.status | Should -Be 'completed'
        (Get-Row $result $hanging).reason | Should -Be 'メディア情報の取得がタイムアウトしました。'
        (Get-Row $result $healthy).formats | Should -Be @('mp3')
    }
}
