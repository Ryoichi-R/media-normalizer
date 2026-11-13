#Requires -Modules Pester

BeforeAll {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    foreach ($module in 'Probe', 'Progress', 'Core') {
        Import-Module (Join-Path $root "lib/MediaNormalizer.$module.psm1") -Force
    }
    function New-ReliabilityWave([string]$Path, [string]$Source) {
        & ffmpeg -hide_banner -loglevel error -f lavfi -i $Source -t 3 $Path
        if ($LASTEXITCODE -ne 0) { throw "FFmpeg fixture generation failed: $Path" }
    }
    function Invoke-ReliabilityRun([hashtable]$Overrides) {
        $state = New-MediaNormalizerState
        $parameters = @{
            State = $state; Mode = 'audio'; InputDir = $script:inputs; OutputDir = $script:outputs
            Target = -16; TruePeak = -1; Bitrate = '192k'; SampleRate = '48000'
            CollisionPolicy = 'overwrite'; AudioOutputFormat = 'wav'
            Logger = { param($message) }
        }
        foreach ($key in $Overrides.Keys) { $parameters[$key] = $Overrides[$key] }
        $result = Invoke-Normalize @parameters
        return @{ Result = $result; Records = $state.ReportRecords }
    }
}

Describe 'Media Normalizer functional reliability' -Tag Integration -Skip:(-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    BeforeEach {
        $script:inputs = (New-Item -ItemType Directory (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName
        $script:outputs = Join-Path $script:inputs 'out'
        $source = Join-Path $inputs 'tone.wav'
        New-ReliabilityWave $source 'sine=frequency=1000:sample_rate=48000'
        $script:original = (Get-FileHash -LiteralPath $source).Hash
    }

    It 'refuses to overwrite an original and permits a separate name' {
        $failed = Invoke-ReliabilityRun @{ OutputDir = $inputs }
        $failed.Result.Fail | Should -Be 1
        $failed.Records[0].error | Should -Match '入力原本'
        $failed.Records[0].outputPath | Should -BeNullOrEmpty
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $original

        $renamed = Invoke-ReliabilityRun @{ OutputDir = $inputs; CollisionPolicy = 'rename' }
        $renamed.Result.Success | Should -Be 1
        (Split-Path -Leaf $renamed.Records[0].outputPath) | Should -Be 'tone (2).wav'
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $original
    }

    It 'rejects an unattainable target and preserves an existing output' {
        [void][IO.Directory]::CreateDirectory($outputs)
        $destination = Join-Path $outputs 'tone.wav'
        [IO.File]::Copy($source, $destination)
        $before = (Get-FileHash -LiteralPath $destination).Hash

        $run = Invoke-ReliabilityRun @{ Target = -5; TruePeak = -9 }
        $run.Result.Fail | Should -Be 1
        $run.Result.Success | Should -Be 0
        $run.Records[0].validation.Loudness.IsValid | Should -BeFalse
        $run.Records[0].outputPath | Should -BeNullOrEmpty
        (Get-FileHash -LiteralPath $destination).Hash | Should -Be $before
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $original
        $report = Get-Content -LiteralPath $run.Result.ReportPath -Raw | ConvertFrom-Json
        $report.summary.failed | Should -Be 1
        @(Get-ChildItem -LiteralPath $outputs -Force -Filter '.*media-normalizer*').Count | Should -Be 0
    }

    It 'uses 48 kHz for Opus with a 44.1 kHz preset' {
        $run = Invoke-ReliabilityRun @{ SampleRate = '44100'; AudioOutputFormat = 'opus' }
        $run.Result.Fail | Should -Be 0
        $run.Result.Success | Should -Be 1
        $run.Records[0].requestedSampleRate | Should -Be 44100
        $run.Records[0].effectiveSampleRate | Should -Be 48000
        $output = Get-MediaInventory -FilePath $run.Records[0].outputPath
        $output.StreamTags[0].SampleRate | Should -Be '48000'
    }

    It 'reports silence as null measurements and skips conversion' {
        $silent = Join-Path $inputs 'silent.wav'
        New-ReliabilityWave $silent 'anullsrc=r=48000:cl=mono'
        $analysis = Invoke-ReliabilityRun @{ AnalyzeOnly = $true; TargetFiles = [IO.FileInfo]$silent }
        $analysis.Result.Analyzed | Should -Be 1
        $analysis.Records[0].before.Streams[0].measurementStatus | Should -Be 'silent'
        $analysis.Records[0].before.Streams[0].IntegratedLufs | Should -BeNullOrEmpty

        $conversion = Invoke-ReliabilityRun @{ TargetFiles = [IO.FileInfo]$silent; AudioOutputFormat = 'flac'; SpeedPercent = 125 }
        $conversion.Result.Skipped | Should -Be 1
        $conversion.Records[0].skipReason | Should -Be 'silent'
        $conversion.Records[0].outputPath | Should -BeNullOrEmpty
        $report = Get-Content -LiteralPath $conversion.Result.ReportPath -Raw | ConvertFrom-Json
        $report.summary.skipReasonCounts.silent | Should -Be 1
        $report.files[0].before.Streams[0].TruePeakDbtp | Should -BeNullOrEmpty
    }

    It 'prunes a nested output and rejects an explicit input in that subtree' {
        [void][IO.Directory]::CreateDirectory($outputs)
        $old = Join-Path $outputs 'old.wav'
        [IO.File]::Copy($source, $old)
        $neighbor = New-Item -ItemType Directory (Join-Path $inputs 'out2')
        [IO.File]::Copy($source, (Join-Path $neighbor.FullName 'neighbor.wav'))

        $run = Invoke-ReliabilityRun @{}
        $run.Result.Success | Should -Be 2
        [IO.Directory]::Exists((Join-Path $outputs 'out')) | Should -BeFalse
        $files = Get-MediaInputFiles -InputPath $inputs -OutputDir $outputs -Recurse
        $files.Name | Should -Contain 'neighbor.wav'
        $files.Name | Should -Not -Contain 'old.wav'
        { Get-MediaInputFiles -InputPath @($inputs, $old) -OutputDir $outputs -Recurse } | Should -Throw '*明示入力*'
    }

    It 'distinguishes a short non-silent measurement from digital silence' {
        $short = Join-Path $inputs 'short.wav'
        & ffmpeg -hide_banner -loglevel error -f lavfi -i 'sine=frequency=1000:sample_rate=48000:duration=0.05' $short
        $LASTEXITCODE | Should -Be 0
        $analysis = Invoke-ReliabilityRun @{ AnalyzeOnly = $true; TargetFiles = [IO.FileInfo]$short }
        $analysis.Result.Analyzed | Should -Be 1
        $track = $analysis.Records[0].before.Streams[0]
        $track.measurementStatus | Should -Be 'unmeasurable'
        $track.IntegratedLufs | Should -BeNullOrEmpty
        $track.TruePeakDbtp | Should -BeLessThan 0

        $run = Invoke-ReliabilityRun @{ TargetFiles = [IO.FileInfo]$short }
        $run.Result.Fail | Should -Be 1
        $run.Records[0].outputPath | Should -BeNullOrEmpty
    }

    It 'keeps a verified output if the report cannot be saved' {
        [void][IO.Directory]::CreateDirectory($outputs)
        $blockedReport = (New-Item -ItemType Directory (Join-Path $outputs 'blocked.json')).FullName
        $run = Invoke-ReliabilityRun @{ ReportPath = $blockedReport }

        $run.Result.Success | Should -Be 1
        $run.Result.ReportSucceeded | Should -BeFalse
        $run.Records[0].action | Should -Be 'normalized'
        Test-Path -LiteralPath $run.Records[0].outputPath -PathType Leaf | Should -BeTrue
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $original
    }
}
