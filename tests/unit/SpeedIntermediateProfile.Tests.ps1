#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:libRoot = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib')
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Core.psm1')) -Force

    function script:New-TestInventory {
        param(
            [int]$Data = 0,
            [int]$Attachment = 0,
            [object[]]$AudioStreams = @(
                [pscustomobject]@{ Index = 0; Type = 'audio'; CodecName = 'aac'; Channels = 2; SampleFmt = 'fltp'; SampleRate = '48000'; BitsPerSample = $null; BitsPerRawSample = $null }
            )
        )
        return [pscustomobject]@{
            StreamCounts = @{ video = 1; audio = @($AudioStreams).Count; subtitle = 0; data = $Data; attachment = $Attachment }
            StreamTags   = @($AudioStreams)
        }
    }
}

AfterAll {
    Remove-Module MediaNormalizer.Core -Force -ErrorAction SilentlyContinue
}

Describe 'New-FfmpegSpeedArguments 二重圧縮解消（video分岐）' {
    It '-c:a aac を含まない' {
        InModuleScope MediaNormalizer.Core {
            $profile = [pscustomobject]@{ Codec = 'flac'; ContainerExtension = '.mkv'; PreserveData = $false; PreserveAttachments = $false; UseFastStart = $false }
            $args = New-FfmpegSpeedArguments -Mode video -InputPath 'in.mp4' -OutputPath 'out.mkv' -SpeedPercent 150 -IntermediateProfile $profile
            ($args -join ' ') | Should -Not -Match '-c:a aac'
        }
    }

    It 'audio/video両分岐で-arを含まない（設計判断7）' {
        InModuleScope MediaNormalizer.Core {
            $audioProfile = [pscustomobject]@{ Codec = 'flac'; ContainerExtension = '.flac' }
            $videoProfile = [pscustomobject]@{ Codec = 'alac'; ContainerExtension = '.mp4'; PreserveData = $false; PreserveAttachments = $false; UseFastStart = $true }
            $audioArgs = New-FfmpegSpeedArguments -Mode audio -InputPath 'in.wav' -OutputPath 'out.flac' -SpeedPercent 150 -IntermediateProfile $audioProfile
            $videoArgs = New-FfmpegSpeedArguments -Mode video -InputPath 'in.mp4' -OutputPath 'out.mp4' -SpeedPercent 150 -IntermediateProfile $videoProfile
            ($audioArgs -join ' ') | Should -Not -Match '-ar '
            ($videoArgs -join ' ') | Should -Not -Match '-ar '
        }
    }

    It '中間拡張子は選択プロファイルどおりになる' {
        InModuleScope MediaNormalizer.Core {
            $profile = [pscustomobject]@{ Codec = 'pcm_s32le'; ContainerExtension = '.mkv'; PreserveData = $false; PreserveAttachments = $false; UseFastStart = $false }
            $args = New-FfmpegSpeedArguments -Mode video -InputPath 'in.mov' -OutputPath 'C:\tmp\intermediate.mkv' -SpeedPercent 150 -IntermediateProfile $profile
            $args[-1] | Should -Be 'C:\tmp\intermediate.mkv'
            ($args -join ' ') | Should -Match '-c:a pcm_s32le'
        }
    }

    It 'UseFastStartに従ってMP4/MOV系だけ-movflags +faststartが付く' {
        InModuleScope MediaNormalizer.Core {
            $mp4Profile = [pscustomobject]@{ Codec = 'alac'; ContainerExtension = '.mp4'; PreserveData = $false; PreserveAttachments = $false; UseFastStart = $true }
            $mkvProfile = [pscustomobject]@{ Codec = 'flac'; ContainerExtension = '.mkv'; PreserveData = $false; PreserveAttachments = $false; UseFastStart = $false }
            $mp4Args = New-FfmpegSpeedArguments -Mode video -InputPath 'in.mp4' -OutputPath 'out.mp4' -SpeedPercent 150 -IntermediateProfile $mp4Profile
            $mkvArgs = New-FfmpegSpeedArguments -Mode video -InputPath 'in.mp4' -OutputPath 'out.mkv' -SpeedPercent 150 -IntermediateProfile $mkvProfile
            ($mp4Args -join ' ') | Should -Match '\-movflags \+faststart'
            ($mkvArgs -join ' ') | Should -Not -Match '\-movflags'
        }
    }

    It 'data/attachmentを保持しない場合は-write_tmcd falseが付く（Phase 2A実装知見）' {
        InModuleScope MediaNormalizer.Core {
            $profile = [pscustomobject]@{ Codec = 'flac'; ContainerExtension = '.mkv'; PreserveData = $false; PreserveAttachments = $false; UseFastStart = $false }
            $args = New-FfmpegSpeedArguments -Mode video -InputPath 'in.mp4' -OutputPath 'out.mkv' -SpeedPercent 150 -IntermediateProfile $profile
            ($args -join ' ') | Should -Match '-write_tmcd false'
            ($args -join ' ') | Should -Not -Match '0:d\?'
            ($args -join ' ') | Should -Not -Match '0:t\?'
        }
    }

    It 'PreserveData/PreserveAttachmentsが$trueの場合はmap/copyが両方含まれる' {
        InModuleScope MediaNormalizer.Core {
            $profile = [pscustomobject]@{ Codec = 'alac'; ContainerExtension = '.mp4'; PreserveData = $true; PreserveAttachments = $true; UseFastStart = $true }
            $args = New-FfmpegSpeedArguments -Mode video -InputPath 'in.mp4' -OutputPath 'out.mp4' -SpeedPercent 150 -IntermediateProfile $profile
            ($args -join ' ') | Should -Match '0:d\?'
            ($args -join ' ') | Should -Match '0:t\?'
            ($args -join ' ') | Should -Match '-c:d copy'
            ($args -join ' ') | Should -Match '-c:t copy'
            ($args -join ' ') | Should -Not -Match '-write_tmcd'
        }
    }
}

Describe 'Get-SpeedIntermediateProfile 境界値（設計判断5・6、Phase 2A確定ロジック）' {
    It 'MP4/MOV/MKV入力・data/attachmentなし・8ch以下16bitはvideo-alac-same-containerを選ぶ' {
        foreach ($ext in @('.mp4', '.mov', '.mkv')) {
            $inv = New-TestInventory
            $result = Get-SpeedIntermediateProfile -Mode video -InputExtension $ext -Inventory $inv
            $result.ProfileId | Should -Be 'video-alac-same-container'
            $result.Codec | Should -Be 'alac'
            $result.ContainerExtension | Should -Be $ext
        }
    }

    It 'data(tmcd)を持つMP4入力はvideo-flac-mkvへ倒す（Phase 2A実測: 同一コンテナ維持はtimecode喪失で不合格）' {
        $inv = New-TestInventory -Data 1
        $result = Get-SpeedIntermediateProfile -Mode video -InputExtension '.mp4' -Inventory $inv
        $result.ProfileId | Should -Be 'video-flac-mkv'
        $result.Codec | Should -Be 'flac'
        $result.ContainerExtension | Should -Be '.mkv'
        $result.AncillaryFallback | Should -Be 'DropWithWarning'
    }

    It 'attachmentを持つMKV入力はvideo-flac-mkvへ倒す' {
        $inv = New-TestInventory -Attachment 1
        $result = Get-SpeedIntermediateProfile -Mode video -InputExtension '.mkv' -Inventory $inv
        $result.ProfileId | Should -Be 'video-flac-mkv'
        $result.AncillaryFallback | Should -Be 'DropWithWarning'
    }

    It 'data/attachmentを持たない場合、AncillaryFallbackはNoneになる' {
        $inv = New-TestInventory
        $result = Get-SpeedIntermediateProfile -Mode video -InputExtension '.mp4' -Inventory $inv
        $result.AncillaryFallback | Should -Be 'None'
        $result.PreserveData | Should -BeFalse
        $result.PreserveAttachments | Should -BeFalse
    }

    It '8chはALAC/FLAC条件を満たし、9chはpcm_s32leへ倒す（PCMソース）' {
        $inv8 = New-TestInventory -AudioStreams @(
            [pscustomobject]@{ Index = 0; Type = 'audio'; CodecName = 'pcm_s16le'; Channels = 8; SampleFmt = 's16'; SampleRate = '48000'; BitsPerSample = 16; BitsPerRawSample = $null })
        $result8 = Get-SpeedIntermediateProfile -Mode video -InputExtension '.mp4' -Inventory $inv8
        $result8.ProfileId | Should -Be 'video-alac-same-container'

        $inv9 = New-TestInventory -AudioStreams @(
            [pscustomobject]@{ Index = 0; Type = 'audio'; CodecName = 'pcm_s16le'; Channels = 9; SampleFmt = 's16'; SampleRate = '48000'; BitsPerSample = 16; BitsPerRawSample = $null })
        $result9 = Get-SpeedIntermediateProfile -Mode video -InputExtension '.mp4' -Inventory $inv9
        $result9.ProfileId | Should -Be 'video-pcm-mkv'
        $result9.Codec | Should -Be 'pcm_s32le'
        $result9.ContainerExtension | Should -Be '.mkv'
    }

    It '非可逆圧縮ソース(AAC等)は9chでもchannels条件だけでpcm_s32leへ倒す' {
        $inv = New-TestInventory -AudioStreams @(
            [pscustomobject]@{ Index = 0; Type = 'audio'; CodecName = 'aac'; Channels = 9; SampleFmt = 'fltp'; SampleRate = '48000'; BitsPerSample = $null; BitsPerRawSample = $null })
        $result = Get-SpeedIntermediateProfile -Mode video -InputExtension '.mp4' -Inventory $inv
        $result.Codec | Should -Be 'pcm_s32le'
    }

    It '24bitPCMはALAC/FLAC条件を満たし、32bitPCMはpcm_s32leへ倒す（Phase 2A実測: 32bitは静かに24bitへdownconvertされるため）' {
        $inv24 = New-TestInventory -AudioStreams @(
            [pscustomobject]@{ Index = 0; Type = 'audio'; CodecName = 'pcm_s32le'; Channels = 2; SampleFmt = 's32'; SampleRate = '48000'; BitsPerSample = 0; BitsPerRawSample = '24' })
        $result24 = Get-SpeedIntermediateProfile -Mode video -InputExtension '.mp4' -Inventory $inv24
        $result24.ProfileId | Should -Be 'video-alac-same-container'

        $inv32 = New-TestInventory -AudioStreams @(
            [pscustomobject]@{ Index = 0; Type = 'audio'; CodecName = 'pcm_s32le'; Channels = 2; SampleFmt = 's32'; SampleRate = '48000'; BitsPerSample = 32; BitsPerRawSample = $null })
        $result32 = Get-SpeedIntermediateProfile -Mode video -InputExtension '.mp4' -Inventory $inv32
        $result32.Codec | Should -Be 'pcm_s32le'
    }

    It 'PCMソースのflt/fltpはpcm_f32leへ、dbl/dblpはpcm_f64leへ倒す' {
        $invFlt = New-TestInventory -AudioStreams @(
            [pscustomobject]@{ Index = 0; Type = 'audio'; CodecName = 'pcm_f32le'; Channels = 2; SampleFmt = 'fltp'; SampleRate = '48000'; BitsPerSample = 32; BitsPerRawSample = $null })
        (Get-SpeedIntermediateProfile -Mode video -InputExtension '.mp4' -Inventory $invFlt).Codec | Should -Be 'pcm_f32le'

        $invDbl = New-TestInventory -AudioStreams @(
            [pscustomobject]@{ Index = 0; Type = 'audio'; CodecName = 'pcm_f64le'; Channels = 2; SampleFmt = 'dblp'; SampleRate = '48000'; BitsPerSample = 64; BitsPerRawSample = $null })
        (Get-SpeedIntermediateProfile -Mode video -InputExtension '.mp4' -Inventory $invDbl).Codec | Should -Be 'pcm_f64le'
    }

    It 'AAC等の非可逆圧縮ソースはsample_fmt=fltpでも精度判定をスキップしALAC/FLAC候補になる（Phase 2B実装時に実際のAAC音声で発覚した修正）' {
        $inv = New-TestInventory -AudioStreams @(
            [pscustomobject]@{ Index = 0; Type = 'audio'; CodecName = 'aac'; Channels = 2; SampleFmt = 'fltp'; SampleRate = '48000'; BitsPerSample = $null; BitsPerRawSample = $null })
        $result = Get-SpeedIntermediateProfile -Mode video -InputExtension '.mp4' -Inventory $inv
        $result.ProfileId | Should -Be 'video-alac-same-container'
        $result.Codec | Should -Be 'alac'
    }

    It 'PCMソースで精度情報が欠落・0の場合は品質優先でpcm_f32leへ倒す' {
        $inv = New-TestInventory -AudioStreams @(
            [pscustomobject]@{ Index = 0; Type = 'audio'; CodecName = 'pcm_s16le'; Channels = 2; SampleFmt = 's16'; SampleRate = '48000'; BitsPerSample = 0; BitsPerRawSample = $null })
        (Get-SpeedIntermediateProfile -Mode video -InputExtension '.mp4' -Inventory $inv).Codec | Should -Be 'pcm_f32le'
    }

    It '複数音声混在では最も厳しいストリームの判定を採用する（PCM 16bit + PCM double混在）' {
        $inv = New-TestInventory -AudioStreams @(
            [pscustomobject]@{ Index = 0; Type = 'audio'; CodecName = 'pcm_s16le'; Channels = 2; SampleFmt = 's16'; SampleRate = '48000'; BitsPerSample = 16; BitsPerRawSample = $null },
            [pscustomobject]@{ Index = 1; Type = 'audio'; CodecName = 'pcm_f64le'; Channels = 2; SampleFmt = 'dblp'; SampleRate = '48000'; BitsPerSample = 64; BitsPerRawSample = $null }
        )
        (Get-SpeedIntermediateProfile -Mode video -InputExtension '.mp4' -Inventory $inv).Codec | Should -Be 'pcm_f64le'
    }

    It 'MP4のPCMフォールバックは.mp4を返さず.mkvになる。音声PCMは.wavになる' {
        $inv = New-TestInventory -AudioStreams @(
            [pscustomobject]@{ Index = 0; Type = 'audio'; CodecName = 'pcm_s16le'; Channels = 9; SampleFmt = 's16'; SampleRate = '48000'; BitsPerSample = 16; BitsPerRawSample = $null })
        $videoResult = Get-SpeedIntermediateProfile -Mode video -InputExtension '.mp4' -Inventory $inv
        $videoResult.ContainerExtension | Should -Be '.mkv'
        $videoResult.ContainerExtension | Should -Not -Be '.mp4'

        $audioResult = Get-SpeedIntermediateProfile -Mode audio -InputExtension '.mp4' -Inventory $inv
        $audioResult.ContainerExtension | Should -Be '.wav'
        $audioResult.ProfileId | Should -Be 'audio-pcm-wav'
    }

    It '音声モードはALAC採否を流用せず、FLAC条件を満たせばaudio-flac、満たさなければaudio-pcm-wav' {
        $invOk = New-TestInventory
        $resultOk = Get-SpeedIntermediateProfile -Mode audio -InputExtension '.wav' -Inventory $invOk
        $resultOk.ProfileId | Should -Be 'audio-flac'
        $resultOk.ContainerExtension | Should -Be '.flac'

        $invNg = New-TestInventory -AudioStreams @(
            [pscustomobject]@{ Index = 0; Type = 'audio'; CodecName = 'pcm_f32le'; Channels = 2; SampleFmt = 'fltp'; SampleRate = '48000'; BitsPerSample = 32; BitsPerRawSample = $null })
        $resultNg = Get-SpeedIntermediateProfile -Mode audio -InputExtension '.wav' -Inventory $invNg
        $resultNg.ProfileId | Should -Be 'audio-pcm-wav'
        $resultNg.Codec | Should -Be 'pcm_f32le'
    }

    It 'Codec と ContainerExtension は必ず同一プロファイルの値が返る（選定規則2）' {
        $inv = New-TestInventory
        $result = Get-SpeedIntermediateProfile -Mode video -InputExtension '.mov' -Inventory $inv
        $result.Codec | Should -Be 'alac'
        $result.ContainerExtension | Should -Be '.mov'
        ($result.ProfileId -eq 'video-alac-same-container') | Should -BeTrue
    }

    It 'SelectionReasonが常に非空文字列で返る' {
        $inv = New-TestInventory -Data 1
        $result = Get-SpeedIntermediateProfile -Mode video -InputExtension '.mp4' -Inventory $inv
        $result.SelectionReason | Should -Not -BeNullOrEmpty
    }
}

Describe 'Compare-MediaInventory の AllowAncillaryStreamDrop（設計判断8）' {
    It '速度変更時(AllowAncillaryStreamDrop)はdata/attachment減少がwarningsになりIsValidを維持する' {
        $inputInv = [pscustomobject]@{
            Length = 100; DurationSec = 5
            StreamCounts = @{ video = 1; audio = 1; subtitle = 0; data = 1; attachment = 0 }
            ChapterCount = 0; FormatTags = $null; StreamTags = @()
        }
        $outputInv = [pscustomobject]@{
            Length = 90; DurationSec = 5
            StreamCounts = @{ video = 1; audio = 1; subtitle = 0; data = 0; attachment = 0 }
            ChapterCount = 0; FormatTags = $null; StreamTags = @()
        }
        $result = Compare-MediaInventory -InputInventory $inputInv -OutputInventory $outputInv -Mode video -AllowAncillaryStreamDrop
        $result.IsValid | Should -BeTrue
        ($result.Warnings -join ';') | Should -Match 'data'
        $result.Errors | Should -BeNullOrEmpty
    }

    It '100%速度相当(AllowAncillaryStreamDropなし)ではdata減少は従来どおりerrorsになる（既存挙動維持）' {
        $inputInv = [pscustomobject]@{
            Length = 100; DurationSec = 5
            StreamCounts = @{ video = 1; audio = 1; subtitle = 0; data = 1; attachment = 0 }
            ChapterCount = 0; FormatTags = $null; StreamTags = @()
        }
        $outputInv = [pscustomobject]@{
            Length = 90; DurationSec = 5
            StreamCounts = @{ video = 1; audio = 1; subtitle = 0; data = 0; attachment = 0 }
            ChapterCount = 0; FormatTags = $null; StreamTags = @()
        }
        $result = Compare-MediaInventory -InputInventory $inputInv -OutputInventory $outputInv -Mode video
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ';') | Should -Match 'data'
    }

    It 'AllowAncillaryStreamDropでも他の必須メタデータ喪失はerrorsのまま' {
        $inputInv = [pscustomobject]@{
            Length = 100; DurationSec = 5
            StreamCounts = @{ video = 1; audio = 0; subtitle = 0; data = 1; attachment = 0 }
            ChapterCount = 0; FormatTags = $null; StreamTags = @()
        }
        $outputInv = [pscustomobject]@{
            Length = 90; DurationSec = 5
            StreamCounts = @{ video = 0; audio = 0; subtitle = 0; data = 0; attachment = 0 }
            ChapterCount = 0; FormatTags = $null; StreamTags = @()
        }
        $result = Compare-MediaInventory -InputInventory $inputInv -OutputInventory $outputInv -Mode video -AllowAncillaryStreamDrop
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ';') | Should -Match 'video'
    }
}

Describe 'Get-MediaInventory StreamTags拡張（Phase 2B、Compare-MediaInventoryへの非影響確認）' {
    It '既存の.Tagsのみを参照する比較ロジックは新フィールド追加の影響を受けない' {
        $inputInv = [pscustomobject]@{
            Length = 100; DurationSec = 5
            StreamCounts = @{ video = 1; audio = 1; subtitle = 0; data = 0; attachment = 0 }
            ChapterCount = 0; FormatTags = $null
            StreamTags = @([pscustomobject]@{ Index = 0; Type = 'audio'; Tags = $null; Channels = 2; SampleFmt = 's16'; SampleRate = '48000'; BitsPerSample = 16; BitsPerRawSample = $null })
        }
        $outputInv = [pscustomobject]@{
            Length = 90; DurationSec = 5
            StreamCounts = @{ video = 1; audio = 1; subtitle = 0; data = 0; attachment = 0 }
            ChapterCount = 0; FormatTags = $null
            StreamTags = @([pscustomobject]@{ Index = 0; Type = 'audio'; Tags = $null; Channels = 2; SampleFmt = 's32'; SampleRate = '96000'; BitsPerSample = 32; BitsPerRawSample = $null })
        }
        $result = Compare-MediaInventory -InputInventory $inputInv -OutputInventory $outputInv -Mode video
        $result.IsValid | Should -BeTrue
    }
}
