#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:libRoot = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib')
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Core.psm1')) -Force
}

AfterAll {
    Remove-Module MediaNormalizer.Core -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-SpeedPercent' {
    It '未指定は既定値100を返す' {
        ConvertTo-SpeedPercent -Value $null | Should -Be 100
        ConvertTo-SpeedPercent -Value '' | Should -Be 100
    }

    It '150を1.5倍速指定として受け付ける' {
        ConvertTo-SpeedPercent -Value '150' | Should -Be 150
    }

    It '50から200の範囲外は拒否する' {
        { ConvertTo-SpeedPercent -Value 49 } | Should -Throw
        { ConvertTo-SpeedPercent -Value 201 } | Should -Throw
    }
}

Describe 'New-FfmpegSpeedArguments' {
    It 'audioは中間プロファイルのコーデックでatempoフィルタ適用した一時ファイルを生成する（二重圧縮解消）' {
        InModuleScope MediaNormalizer.Core {
            $profile = [pscustomobject]@{ Codec = 'flac'; ContainerExtension = '.flac' }
            $args = New-FfmpegSpeedArguments -Mode audio -InputPath 'C:\in\a.mp4' -OutputPath 'C:\tmp\a.flac' -SpeedPercent 150 -IntermediateProfile $profile
            ($args -join ' ') | Should -Match 'atempo=1\.5'
            ($args -join ' ') | Should -Match '-c:a flac'
            ($args -join ' ') | Should -Not -Match 'pcm_s16le'
            ($args -join ' ') | Should -Not -Match '-ar '
            $args[-1] | Should -Be 'C:\tmp\a.flac'
        }
    }

    It 'videoは映像PTSと音声atempoを同じ倍率で変換し、中間プロファイルのコーデックを使う（二重圧縮解消）' {
        InModuleScope MediaNormalizer.Core {
            $profile = [pscustomobject]@{
                Codec               = 'alac'
                ContainerExtension  = '.mp4'
                PreserveData        = $false
                PreserveAttachments = $false
                UseFastStart        = $true
            }
            $args = New-FfmpegSpeedArguments -Mode video -InputPath 'C:\in\a.mp4' -OutputPath 'C:\tmp\a.mp4' -SpeedPercent 150 -IntermediateProfile $profile
            ($args -join ' ') | Should -Match 'setpts=PTS/1\.5'
            ($args -join ' ') | Should -Match 'atempo=1\.5'
            ($args -join ' ') | Should -Match 'libx264'
            ($args -join ' ') | Should -Match '-c:a alac'
            ($args -join ' ') | Should -Not -Match '-c:a aac'
            ($args -join ' ') | Should -Not -Match '-ar '
            ($args -join ' ') | Should -Match '-write_tmcd false'
            $args[-1] | Should -Be 'C:\tmp\a.mp4'
        }
    }
}
