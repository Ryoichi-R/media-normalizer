#Requires -Modules Pester

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\lib\MediaNormalizer.Progress.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\..\lib\MediaNormalizer.Probe.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\..\lib\MediaNormalizer.Core.psm1') -Force
}

AfterAll {
    Remove-Module MediaNormalizer.Core -Force -ErrorAction SilentlyContinue
    Remove-Module MediaNormalizer.Probe -Force -ErrorAction SilentlyContinue
    Remove-Module MediaNormalizer.Progress -Force -ErrorAction SilentlyContinue
}

Describe 'Write-NormalizationReport failure contract' {
    BeforeEach {
        $script:testRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'mn-report-failure-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'ディレクトリをReportPathとして受け付けない' {
        { Write-NormalizationReport -Path $script:testRoot -Records @([pscustomobject]@{ action = 'analyzed' }) } |
            Should -Throw '*JSONファイルパス*'
    }

    It 'JSON以外の拡張子を拒否する' {
        $path = Join-Path $script:testRoot 'report.txt'
        { Write-NormalizationReport -Path $path -Records @([pscustomobject]@{ action = 'analyzed' }) } |
            Should -Throw '*.json*'
    }

    It '解析のみのレポート保存失敗をReportSucceeded=falseで返す' {
        Mock -ModuleName MediaNormalizer.Core Get-Command { [pscustomobject]@{ Name = $Name } }

        $input = Join-Path $script:testRoot 'sample.wav'
        [IO.File]::WriteAllBytes($input, [byte[]](1))
        $output = Join-Path $script:testRoot 'out'
        New-Item -Path $output -ItemType Directory | Out-Null
        $report = Join-Path $output 'locked.json'
        [IO.File]::WriteAllText($report, 'locked')
        $lock = [IO.File]::Open(
            $report,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None)
        try {
            $state = New-MediaNormalizerState
            $analysis = [pscustomobject]@{
                Streams = @([pscustomobject]@{
                    AudioStreamIndex = 0
                    IntegratedLufs = -20.0
                    TruePeakDbtp = -3.0
                })
            }
            $result = Invoke-Normalize `
                -State $state `
                -Mode audio `
                -InputDir $script:testRoot `
                -OutputDir $output `
                -Target -16 `
                -TruePeak -1 `
                -Bitrate '192k' `
                -SampleRate '48000' `
                -CollisionPolicy rename `
                -TargetFiles @((Get-Item -LiteralPath $input)) `
                -AnalyzeOnly `
                -ReportPath $report `
                -Analyzer { param($path, $target, $truePeak) $analysis }.GetNewClosure() `
                -Logger { param($message) }

            $result.Analyzed | Should -Be 1
            $result.Fail | Should -Be 0
            $result.ReportSucceeded | Should -BeFalse
            $result.ReportError | Should -Not -BeNullOrEmpty
        } finally {
            $lock.Dispose()
        }
    }
}

Describe 'Test-VideoSpeedChangeSafety' {
    It 'HDR10の速度変更を拒否する' {
        $inventory = [pscustomobject]@{
            StreamTags = @([pscustomobject]@{
                Index = 0
                Type = 'video'
                PixelFormat = 'yuv420p10le'
                BitsPerRawSample = '10'
                ColorTransfer = 'smpte2084'
                ColorPrimaries = 'bt2020'
                ColorSpace = 'bt2020nc'
            })
        }

        $result = Test-VideoSpeedChangeSafety -Inventory $inventory

        $result.IsSafe | Should -BeFalse
        ($result.Reasons -join "`n") | Should -Match '8bitを超える|HDR|BT.2020'
    }

    It '標準的な8bit SDR映像を許可する' {
        $inventory = [pscustomobject]@{
            StreamTags = @([pscustomobject]@{
                Index = 0
                Type = 'video'
                PixelFormat = 'yuv420p'
                BitsPerRawSample = '8'
                ColorTransfer = 'bt709'
                ColorPrimaries = 'bt709'
                ColorSpace = 'bt709'
            })
        }

        (Test-VideoSpeedChangeSafety -Inventory $inventory).IsSafe | Should -BeTrue
    }
}

Describe 'Invoke-NormalizeCli report failure exit code' {
    BeforeEach {
        $script:cliRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'mn-cli-report-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:cliRoot -ItemType Directory | Out-Null
        $script:cliInput = Join-Path $script:cliRoot 'sample.wav'
        [IO.File]::WriteAllBytes($script:cliInput, [byte[]](1))
    }

    AfterEach {
        Remove-Item -LiteralPath $script:cliRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '最終レポート保存失敗を終了コード1へ反映する' {
        Mock -ModuleName MediaNormalizer.Core Get-MediaDuration { 1.0 }
        Mock -ModuleName MediaNormalizer.Core Invoke-Normalize {
            @{
                Success = 0
                Analyzed = 1
                Fail = 0
                Cancelled = 0
                Skipped = 0
                ReportSucceeded = $false
                ReportError = 'locked'
            }
        }

        Invoke-NormalizeCli `
            -InputPath $script:cliInput `
            -OutputDir $script:cliRoot `
            -AnalyzeOnly

        $global:LASTEXITCODE | Should -Be 1
    }

    It 'bothの解析レポートmodeをInvoke-Normalizeへ伝播する' {
        $script:observedReportMode = $null
        Mock -ModuleName MediaNormalizer.Core Get-MediaDuration { 1.0 }
        Mock -ModuleName MediaNormalizer.Core Invoke-Normalize {
            $script:observedReportMode = $ReportMode
            @{
                Success = 0
                Analyzed = 1
                Fail = 0
                Cancelled = 0
                Skipped = 0
                ReportSucceeded = $true
                ReportError = $null
            }
        }

        Invoke-NormalizeCli `
            -InputPath $script:cliInput `
            -OutputDir $script:cliRoot `
            -Mode both `
            -AnalyzeOnly

        $global:LASTEXITCODE | Should -Be 0
        $script:observedReportMode | Should -Be 'both'
    }
}
