#Requires -Modules Pester

<#
    TODO.md MN-10 / plans/media-normalizer-ui-responsiveness-remediation-plan.md Phase 4。
    Get-MediaLoudnessAnalysis / Invoke-MediaNormalizerProcess を実 ffmpeg で検証する。
    Invoke-Normalize.Tests.ps1 は正規化パイプライン全体を検証するのに対し、本ファイルは
    解析パス(runner 化の主対象)の応答性・キャンセル安全性・進捗単調性に絞る。
#>

Set-StrictMode -Version Latest

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\lib\MediaNormalizer.Probe.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\..\lib\MediaNormalizer.Progress.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\..\lib\MediaNormalizer.Core.psm1') -Force
    . (Join-Path $PSScriptRoot '..\support\fixtures\media-normalizer\New-TestMedia.ps1')
}

$ffmpegAvailable = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)

Describe 'Get-MediaLoudnessAnalysis 実 ffmpeg 統合' -Tag 'Integration' -Skip:(-not $ffmpegAvailable) {
    BeforeEach {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mn-la-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '複数音声ストリームで PhaseProgressPercent が単調非減少である' {
        $mediaPath = Join-Path $script:tmpRoot 'multi-audio.mp4'
        New-TestRichMedia -OutputPath $mediaPath -DurationSec 4 | Out-Null

        $state = New-MediaNormalizerState
        $samples = [System.Collections.Generic.List[double]]::new()
        $progress = { param($c, $t) $samples.Add($state.PhaseProgressPercent) }.GetNewClosure()

        $analysis = Get-MediaLoudnessAnalysis -FilePath $mediaPath -Target -16.0 -TruePeak -1.0 `
            -State $state -Progress $progress -CliMode -CurrentFileDurationSec 4.0 -PhaseLabel '解析中'

        $analysis.Streams.Count | Should -Be 2

        $nonNegative = @($samples | Where-Object { $_ -ge 0 })
        $nonNegative.Count | Should -BeGreaterThan 0
        for ($i = 1; $i -lt $nonNegative.Count; $i++) {
            $nonNegative[$i] | Should -BeGreaterOrEqual $nonNegative[$i - 1]
        }
    }

    It '空白と日本語を含むパスでも解析できる' {
        $dir = Join-Path $script:tmpRoot '空白 を含む フォルダ'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $mediaPath = Join-Path $dir '日本語 サンプル.mp4'
        New-TestMedia -OutputPath $mediaPath -DurationSec 2 | Out-Null

        $state = New-MediaNormalizerState
        $analysis = Get-MediaLoudnessAnalysis -FilePath $mediaPath -Target -16.0 -TruePeak -1.0 -State $state -CliMode
        $analysis.Streams.Count | Should -Be 1
        $analysis.Streams[0].IntegratedLufs | Should -BeLessThan 0
    }

    It '存在しないファイルに対するエラーメッセージが現行の文言と一致する' {
        $missing = Join-Path $script:tmpRoot 'does-not-exist.mp4'
        { Get-MediaLoudnessAnalysis -FilePath $missing -Target -16.0 -TruePeak -1.0 -CliMode } |
            Should -Throw '*ffprobe による検証に失敗しました*'
    }

    It '実行後に一時ファイル(stdout/stderr/progress)が残らない' {
        $mediaPath = Join-Path $script:tmpRoot 'cleanup.mp4'
        New-TestMedia -OutputPath $mediaPath -DurationSec 2 | Out-Null

        $tempDir = [IO.Path]::GetTempPath()
        $before = @(Get-ChildItem -Path $tempDir -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)

        $state = New-MediaNormalizerState
        Get-MediaLoudnessAnalysis -FilePath $mediaPath -Target -16.0 -TruePeak -1.0 -State $state -CliMode | Out-Null

        $after = @(Get-ChildItem -Path $tempDir -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        $leaked = @(Compare-Object -ReferenceObject $before -DifferenceObject $after -ErrorAction SilentlyContinue |
            Where-Object { $_.SideIndicator -eq '=>' })
        $leaked | Should -BeNullOrEmpty
    }

    # 「解析中にキャンセルすると子孫プロセス・一時ファイルが残らない」という不変条件は、
    # 実 ffmpeg では合成素材のデコードが実時間よりはるかに高速(90秒の音声でも1秒未満)で
    # 完了してしまい、キャンセルが間に合う実時間の窓を確定的に作れないため、ここでは検証しない。
    # 同じ不変条件は次の決定論的な単体テストでカバー済み:
    #   - tests/unit/ProcessProgress.Tests.ps1
    #     「キャンセル要求時の CancelAction は1回だけ呼ぶ」(フェイクプロセスで確定的に検証)
    #   - tests/unit/MediaNormalizer.ProcessRunner.Tests.ps1
    #     「Get-MediaLoudnessAnalysis はキャンセル済み State では後続ストリームを開始しない」
    #     (Invoke-MediaNormalizerProcess を Mock し、キャンセル後に次ストリームが起動されないことを検証)
}
