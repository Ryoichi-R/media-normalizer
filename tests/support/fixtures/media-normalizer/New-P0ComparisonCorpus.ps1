#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FfmpegPath,
    [Parameter(Mandatory)][string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedFfmpeg = (Resolve-Path -LiteralPath $FfmpegPath).Path
if (-not (Test-Path -LiteralPath $resolvedFfmpeg -PathType Leaf)) {
    throw "FFmpeg executable must be a file: $FfmpegPath"
}

$fullOutput = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $fullOutput) {
    throw "Refusing to overwrite an existing comparison corpus: $fullOutput"
}

function Invoke-FfmpegProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $resolvedFfmpeg
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'FFmpeg process did not start.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $outputText = $stdoutTask.GetAwaiter().GetResult() + "`n" + $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $tail = $outputText
            if ($tail.Length -gt 3000) { $tail = $tail.Substring($tail.Length - 3000) }
            throw "FFmpeg exited with code $($process.ExitCode): $tail"
        }

        return [pscustomobject]@{ ExitCode = $process.ExitCode; OutputText = $outputText }
    } finally {
        $process.Dispose()
    }
}

$versionResult = Invoke-FfmpegProcess -Arguments @('-hide_banner', '-version')
$versionLines = @($versionResult.OutputText -split "`r?`n")
$versionLine = [string]($versionLines | Where-Object { $_ -match '^ffmpeg version ' } | Select-Object -First 1)
$configurationLine = [string]($versionLines | Where-Object { $_ -match '^configuration:' } | Select-Object -First 1)
$encoderResult = Invoke-FfmpegProcess -Arguments @('-hide_banner', '-encoders')
foreach ($encoder in @('libx264', 'libmp3lame', 'aac', 'flac', 'pcm_s24le')) {
    $encoderMatches = @(
        $encoderResult.OutputText -split "`r?`n" |
            Where-Object { $_ -match "\s$([regex]::Escape($encoder))(?:\s|$)" }
    )
    if ($encoderMatches.Count -eq 0) {
        throw "Selected FFmpeg does not expose required sample encoder '$encoder'. Use the pinned comparison build."
    }
}

[void][IO.Directory]::CreateDirectory($fullOutput)
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('mn-p0-8-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporaryDirectory)
$masterWave = Join-Path $temporaryDirectory 'dynamic-master.wav'
$subtitlePath = Join-Path $temporaryDirectory 'multistream.srt'
$metadataPath = Join-Path $temporaryDirectory 'multistream.ffmeta'

try {
    $null = Invoke-FfmpegProcess -Arguments @(
        '-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
        '-f', 'lavfi', '-i', 'sine=frequency=997:sample_rate=48000:duration=4',
        '-f', 'lavfi', '-i', 'sine=frequency=997:sample_rate=48000:duration=4',
        '-f', 'lavfi', '-i', 'sine=frequency=997:sample_rate=48000:duration=4',
        '-filter_complex', '[0:a]volume=-12dB[loud];[1:a]volume=-22dB[medium];[2:a]volume=-32dB[quiet];[loud][medium][quiet]concat=n=3:v=0:a=1[out]',
        '-map', '[out]', '-ar', '48000', '-c:a', 'pcm_s24le', $masterWave
    )

    $waveOutput = Join-Path $fullOutput 'audio-dynamic.wav'
    Copy-Item -LiteralPath $masterWave -Destination $waveOutput

    $null = Invoke-FfmpegProcess -Arguments @(
        '-hide_banner', '-loglevel', 'error', '-nostdin', '-y', '-i', $masterWave,
        '-map', '0:a:0', '-c:a', 'flac', '-compression_level', '5',
        '-metadata', 'title=MN_P0_8_Dynamic_FLAC', (Join-Path $fullOutput 'audio-dynamic.flac')
    )
    $null = Invoke-FfmpegProcess -Arguments @(
        '-hide_banner', '-loglevel', 'error', '-nostdin', '-y', '-i', $masterWave,
        '-map', '0:a:0', '-c:a', 'libmp3lame', '-b:a', '192k', '-id3v2_version', '3',
        '-metadata', 'title=MN_P0_8_Dynamic_MP3', (Join-Path $fullOutput 'audio-dynamic.mp3')
    )
    $null = Invoke-FfmpegProcess -Arguments @(
        '-hide_banner', '-loglevel', 'error', '-nostdin', '-y', '-i', $masterWave,
        '-map', '0:a:0', '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart',
        '-metadata', 'title=MN_P0_8_Dynamic_M4A', (Join-Path $fullOutput 'audio-dynamic.m4a')
    )

    foreach ($container in @('mp4', 'mkv')) {
        $arguments = @(
            '-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
            '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=25:duration=12',
            '-i', $masterWave,
            '-map', '0:v:0', '-map', '1:a:0',
            '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '26', '-threads', '1', '-pix_fmt', 'yuv420p',
            '-c:a', 'aac', '-b:a', '192k', '-t', '12',
            '-metadata', "title=MN_P0_8_Basic_$($container.ToUpperInvariant())",
            '-metadata', 'creation_time=2026-09-27T00:00:00Z'
        )
        if ($container -eq 'mp4') { $arguments += @('-movflags', '+faststart') }
        $arguments += (Join-Path $fullOutput "video-basic.$container")
        $null = Invoke-FfmpegProcess -Arguments $arguments
    }

    [IO.File]::WriteAllText($subtitlePath, "1`n00:00:00,000 --> 00:00:05,000`nJapanese subtitle fixture`n`n2`n00:00:06,000 --> 00:00:11,500`nSecond subtitle fixture`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($metadataPath, ";FFMETADATA1`ntitle=MN_P0_8_Multistream`n[CHAPTER]`nTIMEBASE=1/1000`nSTART=0`nEND=6000`ntitle=Part_1`n[CHAPTER]`nTIMEBASE=1/1000`nSTART=6000`nEND=12000`ntitle=Part_2`n", [Text.UTF8Encoding]::new($false))
    $null = Invoke-FfmpegProcess -Arguments @(
        '-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
        '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=25:duration=12',
        '-i', $masterWave, '-i', $masterWave, '-i', $subtitlePath, '-f', 'ffmetadata', '-i', $metadataPath,
        '-map', '0:v:0', '-map', '1:a:0', '-map', '2:a:0', '-map', '3:s:0',
        '-map_metadata', '4', '-map_chapters', '4',
        '-metadata:s:a:0', 'language=jpn', '-metadata:s:a:1', 'language=eng', '-metadata:s:s:0', 'language=jpn',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '26', '-threads', '1', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-b:a', '192k', '-c:s', 'srt', '-t', '12',
        (Join-Path $fullOutput 'video-multistream.mkv')
    )

    [IO.File]::WriteAllText(
        (Join-Path $fullOutput 'invalid-corrupt.mp4'),
        "This is a deliberately invalid media fixture for cross-platform failure parity.`n",
        [Text.UTF8Encoding]::new($false))
} finally {
    if (Test-Path -LiteralPath $temporaryDirectory -PathType Container) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

$fixtureDefinitions = @(
    @{ Name = 'audio-dynamic.wav'; Category = 'audio'; Mode = 'audio'; Scenario = 'lossless PCM; dynamic loudness segments' },
    @{ Name = 'audio-dynamic.flac'; Category = 'audio'; Mode = 'audio'; Scenario = 'lossless FLAC; same dynamic master' },
    @{ Name = 'audio-dynamic.mp3'; Category = 'audio'; Mode = 'audio'; Scenario = 'lossy MP3; same dynamic master' },
    @{ Name = 'audio-dynamic.m4a'; Category = 'audio'; Mode = 'audio'; Scenario = 'AAC in M4A; same dynamic master' },
    @{ Name = 'video-basic.mp4'; Category = 'video'; Mode = 'video'; Scenario = 'single video and audio stream; MP4' },
    @{ Name = 'video-basic.mkv'; Category = 'video'; Mode = 'video'; Scenario = 'single video and audio stream; Matroska' },
    @{ Name = 'video-multistream.mkv'; Category = 'video'; Mode = 'video'; Scenario = 'two audio streams, subtitle, and two chapters; speed-change refusal case' },
    @{ Name = 'invalid-corrupt.mp4'; Category = 'negative'; Mode = 'video'; Scenario = 'invalid bytes under a supported extension; failure parity' }
)

$fixtureEntries = foreach ($definition in $fixtureDefinitions) {
    $path = Join-Path $fullOutput $definition.Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Expected comparison fixture was not generated: $($definition.Name)"
    }
    $item = Get-Item -LiteralPath $path
    $hash = Get-FileHash -LiteralPath $path -Algorithm SHA256
    [ordered]@{
        path = $definition.Name
        category = $definition.Category
        recommendedMode = $definition.Mode
        scenario = $definition.Scenario
        byteLength = $item.Length
        sha256 = $hash.Hash.ToLowerInvariant()
    }
}

$binaryHash = (Get-FileHash -LiteralPath $resolvedFfmpeg -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest = [ordered]@{
    schemaVersion = 1
    fixtureSetId = 'media-normalizer-p0-8-sample-v1'
    generator = [ordered]@{
        executableName = [IO.Path]::GetFileName($resolvedFfmpeg)
        sha256 = $binaryHash
        version = $versionLine
        buildConfiguration = $configurationLine
    }
    fixtures = @($fixtureEntries)
}
$manifestPath = Join-Path $fullOutput 'fixture-manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8

Write-Output "Comparison corpus created: $fullOutput"
Write-Output "Fixture manifest: $manifestPath"
Write-Output 'Copy this exact directory to both native systems and run Test-P0ComparisonCorpus.ps1 before comparing reports.'
