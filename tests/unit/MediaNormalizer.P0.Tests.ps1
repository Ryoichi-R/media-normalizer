#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:libRoot = [IO.Path]::Combine(
        $PSScriptRoot,
        '..',
        '..',
        'lib')
    Import-Module ([IO.Path]::Combine(
            $script:libRoot,
            'MediaNormalizer.Core.psm1')) -Force
}

AfterAll {
    Remove-Module MediaNormalizer.Core -Force -ErrorAction SilentlyContinue
}

Describe 'P0 audio input and output formats' {
    It 'direct audio extensions are included' {
        $extensions = Get-AudioInputExtensions
        foreach ($extension in @('.mp3', '.wav', '.m4a', '.flac', '.ogg', '.opus')) {
            $extensions | Should -Contain $extension
        }
    }

    It 'provides all supported audio output formats' {
        Get-AudioOutputFormats | Should -Be @(
            'mp3',
            'm4a',
            'aac',
            'flac',
            'wav',
            'opus',
            'ogg')
    }

    It 'does not pass a lossy bitrate option to FLAC' {
        $profile = Get-AudioOutputProfile `
            -Format flac `
            -Bitrate 320k `
            -SampleRate 48000

        $profile.Extension | Should -Be '.flac'
        $profile.Codec | Should -Be 'flac'
        $profile.Lossless | Should -BeTrue
        $profile.NormalizeArgs | Should -Not -Contain '-b:a'
    }
}

Describe 'P0 recursive input and hierarchy preservation' {
    BeforeEach {
        $script:inputRoot = Join-Path $TestDrive 'input'
        $script:nestedRoot = Join-Path (Join-Path $script:inputRoot 'album') 'disc-1'
        $script:outputRoot = Join-Path $TestDrive 'output'
        New-Item -ItemType Directory -Path $script:nestedRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $script:outputRoot -Force | Out-Null
        $script:mediaPath = Join-Path $script:nestedRoot 'track.flac'
        Set-Content -LiteralPath $script:mediaPath -Value 'fixture'
    }

    It 'recursively finds a direct audio file' {
        $files = Get-MediaInputFiles -InputPath @($script:inputRoot) -Recurse
        $files.Count | Should -Be 1
        $files[0].FullName | Should -Be ([IO.Path]::GetFullPath($script:mediaPath))
    }

    It 'keeps the source directory hierarchy under the output root' {
        $directory = Resolve-MediaOutputDirectory `
            -InputRoot $script:inputRoot `
            -InputFilePath $script:mediaPath `
            -OutputRoot $script:outputRoot `
            -PreserveHierarchy:$true

        $directory | Should -Be (
            [IO.Path]::GetFullPath((
                    Join-Path (Join-Path $script:outputRoot 'album') 'disc-1')))
    }

    It 'falls back to a flat output when hierarchy preservation is disabled' {
        $directory = Resolve-MediaOutputDirectory `
            -InputRoot $script:inputRoot `
            -InputFilePath $script:mediaPath `
            -OutputRoot $script:outputRoot `
            -PreserveHierarchy:$false

        $directory | Should -Be ([IO.Path]::GetFullPath($script:outputRoot))
    }

    It 'uses the parent directory as the root for a single direct file' {
        Get-MediaInputRoot -InputPath @($script:mediaPath) |
            Should -Be ([IO.Path]::GetFullPath($script:nestedRoot))
    }
}

Describe 'P0 analysis and skip decision' {
    It 'skips only when every audio stream is within loudness and peak limits' {
        $analysis = [pscustomobject]@{
            Streams = @(
                [pscustomobject]@{
                    AudioStreamIndex = 0
                    IntegratedLufs = -16.2
                    TruePeakDbtp = -1.4
                },
                [pscustomobject]@{
                    AudioStreamIndex = 1
                    IntegratedLufs = -15.7
                    TruePeakDbtp = -1.1
                })
        }

        $result = Test-NormalizationNeeded `
            -Analysis $analysis `
            -Target -16 `
            -TruePeak -1 `
            -Tolerance 0.5

        $result.Needed | Should -BeFalse
        $result.Reasons | Should -BeNullOrEmpty
    }

    It 'requires normalization when true peak exceeds the selected limit' {
        $analysis = [pscustomobject]@{
            Streams = @(
                [pscustomobject]@{
                    AudioStreamIndex = 0
                    IntegratedLufs = -16.0
                    TruePeakDbtp = -0.4
                })
        }

        $result = Test-NormalizationNeeded `
            -Analysis $analysis `
            -Target -16 `
            -TruePeak -1 `
            -Tolerance 0.5

        $result.Needed | Should -BeTrue
        ($result.Reasons -join "`n") | Should -Match 'true peak'
    }
}

Describe 'P0 output integrity and safe promotion' {
    It 'reports audio streams dropped by an audio-only output without hiding the result' {
        $inputInventory = [pscustomobject]@{
            Length = 100
            DurationSec = 10
            StreamCounts = @{ video = 1; audio = 2; subtitle = 0; data = 0; attachment = 0 }
            ChapterCount = 0
            FormatTags = $null
            StreamTags = @()
        }
        $outputInventory = [pscustomobject]@{
            Length = 90
            DurationSec = 10
            StreamCounts = @{ video = 0; audio = 1; subtitle = 0; data = 0; attachment = 0 }
            ChapterCount = 0
            FormatTags = $null
            StreamTags = @()
        }

        $result = Compare-MediaInventory `
            -InputInventory $inputInventory `
            -OutputInventory $outputInventory `
            -Mode audio

        $result.IsValid | Should -BeTrue
        $result.DroppedAudioStreams | Should -Be 1
        ($result.Warnings -join "`n") | Should -Match '1 個の音声トラック'
    }

    It 'rejects a video output that lost subtitles or chapters' {
        $inputInventory = [pscustomobject]@{
            Length = 100
            DurationSec = 10
            StreamCounts = @{ video = 1; audio = 2; subtitle = 1; data = 0; attachment = 0 }
            ChapterCount = 3
            FormatTags = $null
            StreamTags = @()
        }
        $outputInventory = [pscustomobject]@{
            Length = 90
            DurationSec = 10
            StreamCounts = @{ video = 1; audio = 2; subtitle = 0; data = 0; attachment = 0 }
            ChapterCount = 0
            FormatTags = $null
            StreamTags = @()
        }

        $result = Compare-MediaInventory `
            -InputInventory $inputInventory `
            -OutputInventory $outputInventory `
            -Mode video

        $result.IsValid | Should -BeFalse
        ($result.Errors -join "`n") | Should -Match 'subtitle'
        ($result.Errors -join "`n") | Should -Match 'チャプター'
    }

    It 'creates a temporary output in the final directory with the final extension' {
        $finalPath = Join-Path $TestDrive 'out\sample.flac'
        $temporaryPath = New-SafeOutputPath -FinalPath $finalPath

        (Split-Path -Parent $temporaryPath) |
            Should -Be (Split-Path -Parent ([IO.Path]::GetFullPath($finalPath)))
        [IO.Path]::GetExtension($temporaryPath) | Should -Be '.flac'
        [IO.Path]::GetFileName($temporaryPath) | Should -Match '^\.sample\.media-normalizer-'
    }

    It 'includes the run identity in recovery-cleanable temporary output names' {
        $finalPath = Join-Path $TestDrive 'run-scopedsample.flac'
        $runId = '6f55000c-709c-40f0-9f76-ececf7a5e3ca'
        $temporaryPath = New-SafeOutputPath -FinalPath $finalPath -RunId $runId
        [IO.Path]::GetFileName($temporaryPath) | Should -Match ([regex]::Escape($runId))
        [IO.Path]::GetExtension($temporaryPath) | Should -Be '.flac'
        [IO.Path]::GetFullPath($temporaryPath) | Should -Not -Be ([IO.Path]::GetFullPath($finalPath))
    }

    It 'replaces an existing final file only at promotion time' {
        $directory = Join-Path $TestDrive 'promote'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $finalPath = Join-Path $directory 'sample.wav'
        $temporaryPath = New-SafeOutputPath -FinalPath $finalPath
        Set-Content -LiteralPath $finalPath -Value 'old'
        Set-Content -LiteralPath $temporaryPath -Value 'verified-new'

        Complete-SafeOutput `
            -TemporaryPath $temporaryPath `
            -FinalPath $finalPath

        (Get-Content -LiteralPath $finalPath -Raw).Trim() | Should -Be 'verified-new'
        Test-Path -LiteralPath $temporaryPath | Should -BeFalse
    }
}

Describe 'P0 structured report' {
    It 'writes an atomic JSON report with summary counts' {
        $reportPath = Join-Path $TestDrive 'reports\run.json'
        $records = @(
            [pscustomobject]@{ action = 'normalized'; inputPath = 'a.wav' },
            [pscustomobject]@{ action = 'skipped'; inputPath = 'b.wav' },
            [pscustomobject]@{ action = 'analyzed'; inputPath = 'c.wav' })

        $written = Write-NormalizationReport `
            -Path $reportPath `
            -Records $records `
            -Configuration @{ targetLufs = -16 }

        $written | Should -Be ([IO.Path]::GetFullPath($reportPath))
        $json = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $json.schemaVersion | Should -Be 2
        $json.summary.total | Should -Be 3
        $json.summary.normalized | Should -Be 1
        $json.summary.skipped | Should -Be 1
        $json.summary.analyzed | Should -Be 1
    }

    It 'schema 2 の形状を固定する契約テスト（設計判断4・5）' {
        # before/after は本テストではダミー値だが、schemaVersion=2 が導入する
        # フィールド集合（TargetOffset の非存在・speedIntermediateProfile の存在）を
        # レコードレベルで固定する。実際の before/after 生成は
        # Get-MediaLoudnessAnalysis 側の契約であり、tests/unit/LoudnessParameterRange.Tests.ps1
        # の「返却オブジェクトに TargetOffset を含まない」で別途検証している。
        $reportPath = Join-Path $TestDrive 'reports\schema2.json'
        $records = @(
            [pscustomobject]@{
                action = 'normalized'
                inputPath = 'a.mp4'
                before = [pscustomobject]@{
                    Streams = @([pscustomobject]@{
                        AudioStreamIndex = 0
                        IntegratedLufs = -20.0
                        TruePeakDbtp = -3.0
                        LoudnessRangeLu = 5.0
                        Threshold = '-30.0'
                    })
                }
                speedIntermediateProfile = $null
            })

        Write-NormalizationReport -Path $reportPath -Records $records -Configuration @{ targetLufs = -16 } | Out-Null
        $json = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json

        $json.schemaVersion | Should -Be 2
        $json.files[0].PSObject.Properties['speedIntermediateProfile'] | Should -Not -BeNullOrEmpty
        $json.files[0].speedIntermediateProfile | Should -BeNullOrEmpty
        $json.files[0].before.streams[0].PSObject.Properties['targetOffset'] | Should -BeNullOrEmpty
        $json.files[0].before.streams[0].PSObject.Properties['threshold'] | Should -Not -BeNullOrEmpty
    }
}
