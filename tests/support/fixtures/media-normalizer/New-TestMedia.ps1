function New-TestMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [int]$DurationSec = 5
    )

    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        throw 'ffmpeg が見つかりません。'
    }

    $outDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -LiteralPath $outDir -Force | Out-Null
    }

    $args = @(
        '-y',
        '-f', 'lavfi', '-i', "testsrc=size=320x240:rate=30:duration=$DurationSec",
        '-f', 'lavfi', '-i', "sine=frequency=1000:duration=$DurationSec",
        '-c:v', 'libx264',
        '-c:a', 'aac',
        '-pix_fmt', 'yuv420p',
        '-shortest',
        $OutputPath
    )

    & ffmpeg @args 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
        throw "テストメディア生成に失敗しました: $OutputPath"
    }

    return $OutputPath
}

function New-TestAudio {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [int]$DurationSec = 2
    )

    $outDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    & ffmpeg `
        -y `
        -f lavfi `
        -i "sine=frequency=880:duration=$DurationSec" `
        -metadata 'title=Direct audio fixture' `
        $OutputPath 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
        throw "テスト音声生成に失敗しました: $OutputPath"
    }
    return $OutputPath
}

function New-TestRichMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [int]$DurationSec = 2
    )

    $outDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    $subtitlePath = Join-Path $outDir 'fixture.srt'
    $metadataPath = Join-Path $outDir 'fixture.ffmeta'
    @'
1
00:00:00,000 --> 00:00:01,500
subtitle fixture
'@ | Set-Content -LiteralPath $subtitlePath -Encoding UTF8
    @'
;FFMETADATA1
title=Preservation fixture
[CHAPTER]
TIMEBASE=1/1000
START=0
END=1500
title=Intro
'@ | Set-Content -LiteralPath $metadataPath -Encoding UTF8

    $arguments = @(
        '-y',
        '-f', 'lavfi', '-i', "testsrc=size=320x240:rate=30:duration=$DurationSec",
        '-f', 'lavfi', '-i', "sine=frequency=440:duration=$DurationSec",
        '-f', 'lavfi', '-i', "sine=frequency=880:duration=$DurationSec",
        '-i', $subtitlePath,
        '-i', $metadataPath,
        '-map', '0:v',
        '-map', '1:a',
        '-map', '2:a',
        '-map', '3:s',
        '-map_metadata', '4',
        '-map_chapters', '4',
        '-metadata:s:a:0', 'language=jpn',
        '-metadata:s:a:1', 'language=eng',
        '-metadata:s:s:0', 'language=jpn',
        '-c:v', 'libx264',
        '-c:a', 'aac',
        '-c:s', 'mov_text',
        '-pix_fmt', 'yuv420p',
        '-shortest',
        $OutputPath
    )
    & ffmpeg @arguments 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
        throw "複数ストリームテストメディア生成に失敗しました: $OutputPath"
    }
    return $OutputPath
}

function New-TestSpeedableMedia {
    <#
        字幕・チャプターを持たない「映像 + 単一音声」の動画を生成する。
        速度変更が実際に完走する経路(事実6)のE2Eテストに使う。
        global metadataを最低1件持たせ、事実15(中間コンテナ変更でのメタデータ喪失)の
        回帰をE2Eで検出できるようにする(設計判断9)。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [int]$DurationSec = 5
    )

    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        throw 'ffmpeg が見つかりません。'
    }

    $outDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -LiteralPath $outDir -Force | Out-Null
    }

    $arguments = @(
        '-y',
        '-f', 'lavfi', '-i', "testsrc=size=320x240:rate=30:duration=$DurationSec",
        '-f', 'lavfi', '-i', "sine=frequency=440:duration=$DurationSec",
        '-metadata', 'title=Speed change fixture',
        '-metadata', 'comment=E2E fixture without subtitle or chapter',
        '-metadata', 'creation_time=2026-08-07T00:00:00Z',
        '-c:v', 'libx264',
        '-c:a', 'aac',
        '-pix_fmt', 'yuv420p',
        '-shortest',
        $OutputPath
    )
    & ffmpeg @arguments 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
        throw "速度変更用テストメディア生成に失敗しました: $OutputPath"
    }
    return $OutputPath
}
