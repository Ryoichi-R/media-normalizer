Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MediaNormalizer.Platform.psm1') -Scope Local -DisableNameChecking

# 入力ファイル候補の拡張子リスト（モジュールスコープで一箇所に集約）。
# Audio は音声ファイルの直接入力と、動画コンテナからの音声出力の両方を扱う。
# Video はコンテナ互換性を検証済みの MP4/MOV/MKV を対象とする。
$script:AudioInputExtensions = @(
    '.aac', '.aif', '.aiff', '.alac', '.flac', '.m4a', '.mp3',
    '.ogg', '.opus', '.wav', '.wma',
    '.mp4', '.mov', '.mkv', '.avi'
)
$script:VideoInputExtensions = @('.mp4', '.mov', '.mkv')
$script:AudioOutputFormats = @('mp3', 'm4a', 'aac', 'flac', 'wav', 'opus', 'ogg')

# FFmpeg loudnorm フィルタの受理範囲（実測で確認済み。GUI/CLI/処理入口の3層が
# 同じ範囲を参照する単一の正とする）。
$script:LoudnessTargetRange = @{ Min = -70.0; Max = -5.0 }
$script:LoudnessTruePeakRange = @{ Min = -9.0; Max = 0.0 }

function Get-AudioInputExtensions { return $script:AudioInputExtensions }
function Get-VideoInputExtensions { return $script:VideoInputExtensions }
function Get-AudioOutputFormats { return $script:AudioOutputFormats }

function Get-LoudnessParameterRange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Target', 'TruePeak')]
        [string]$Name
    )
    if ($Name -eq 'Target') { return $script:LoudnessTargetRange }
    return $script:LoudnessTruePeakRange
}

function Test-LoudnessParameter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][double]$Target,
        [Parameter(Mandatory)][double]$TruePeak
    )

    $targetRange = Get-LoudnessParameterRange -Name 'Target'
    $truePeakRange = Get-LoudnessParameterRange -Name 'TruePeak'
    $errorList = [Collections.Generic.List[string]]::new()

    if ([double]::IsNaN($Target) -or [double]::IsInfinity($Target)) {
        $errorList.Add("ターゲット $Target は有限の数値で指定してください。")
    } elseif ($Target -lt $targetRange.Min -or $Target -gt $targetRange.Max) {
        $errorList.Add(
            "ターゲット $Target LUFS は指定できません。" +
            "$($targetRange.Min) 〜 $($targetRange.Max) の範囲で指定してください。")
    }

    if ([double]::IsNaN($TruePeak) -or [double]::IsInfinity($TruePeak)) {
        $errorList.Add("True Peak $TruePeak は有限の数値で指定してください。")
    } elseif ($TruePeak -lt $truePeakRange.Min -or $TruePeak -gt $truePeakRange.Max) {
        $errorList.Add(
            "True Peak $TruePeak dBTP は指定できません。" +
            "$($truePeakRange.Min) 〜 $($truePeakRange.Max) の範囲で指定してください。")
    }

    return [pscustomobject]@{
        IsValid = $errorList.Count -eq 0
        Errors  = $errorList.ToArray()
    }
}

function Get-AudioOutputProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('mp3', 'm4a', 'aac', 'flac', 'wav', 'opus', 'ogg')]
        [string]$Format,
        [string]$Bitrate = '192k',
        [string]$SampleRate = '48000'
    )

    $profiles = @{
        mp3  = @{ Extension = '.mp3'; Codec = 'libmp3lame'; Lossless = $false; UsesBitrate = $true }
        m4a  = @{ Extension = '.m4a'; Codec = 'aac';         Lossless = $false; UsesBitrate = $true }
        aac  = @{ Extension = '.aac'; Codec = 'aac';         Lossless = $false; UsesBitrate = $true }
        flac = @{ Extension = '.flac'; Codec = 'flac';       Lossless = $true;  UsesBitrate = $false }
        wav  = @{ Extension = '.wav'; Codec = 'pcm_s24le';   Lossless = $true;  UsesBitrate = $false }
        opus = @{ Extension = '.opus'; Codec = 'libopus';    Lossless = $false; UsesBitrate = $true }
        ogg  = @{ Extension = '.ogg'; Codec = 'libvorbis';   Lossless = $false; UsesBitrate = $true }
    }

    $audioProfile = $profiles[$Format.ToLowerInvariant()]
    $arguments = @('-c:a', $audioProfile.Codec, '-ar', $SampleRate)
    if ($audioProfile.UsesBitrate) {
        $arguments += @('-b:a', $Bitrate)
    }

    return [pscustomobject]@{
        Format          = $Format.ToLowerInvariant()
        Extension       = $audioProfile.Extension
        Codec           = $audioProfile.Codec
        Lossless        = [bool]$audioProfile.Lossless
        UsesBitrate     = [bool]$audioProfile.UsesBitrate
        NormalizeArgs   = $arguments
    }
}

function Get-RelativeMediaPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$Path
    )

    $baseFull = [IO.Path]::GetFullPath($BasePath).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    if ((Get-MediaNormalizerPlatform) -eq 'Windows') {
        # Keep the existing Windows URI behavior unchanged.
        $baseUri = [Uri]($baseFull + [IO.Path]::DirectorySeparatorChar)
        $pathUri = [Uri]$pathFull
        $relative = [Uri]::UnescapeDataString(
            $baseUri.MakeRelativeUri($pathUri).ToString()).Replace(
                [IO.Path]::AltDirectorySeparatorChar,
                [IO.Path]::DirectorySeparatorChar)
    } else {
        # System.Uri treats POSIX paths as relative URIs; Path.GetRelativePath is correct for
        # absolute macOS/Linux filesystem paths and is available in the bundled PowerShell 7.
        $relative = [IO.Path]::GetRelativePath($baseFull, $pathFull)
    }
    if ($relative -eq '..' -or
        $relative.StartsWith('..' + [IO.Path]::DirectorySeparatorChar) -or
        [IO.Path]::IsPathRooted($relative)) {
        return [IO.Path]::GetFileName($pathFull)
    }
    return $relative
}

function Resolve-MediaOutputDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InputRoot,
        [Parameter(Mandatory)][string]$InputFilePath,
        [Parameter(Mandatory)][string]$OutputRoot,
        [bool]$PreserveHierarchy = $true
    )

    $outputFull = [IO.Path]::GetFullPath($OutputRoot)
    if (-not $PreserveHierarchy) { return $outputFull }

    $inputRootFull = [IO.Path]::GetFullPath($InputRoot)
    if (Test-Path -LiteralPath $inputRootFull -PathType Leaf) {
        return $outputFull
    }

    $relative = Get-RelativeMediaPath -BasePath $inputRootFull -Path $InputFilePath
    $relativeDirectory = Split-Path -Parent $relative
    if ([string]::IsNullOrWhiteSpace($relativeDirectory) -or $relativeDirectory -eq '.') {
        return $outputFull
    }

    $candidate = [IO.Path]::GetFullPath((Join-Path $outputFull $relativeDirectory))
    $rootWithSeparator = $outputFull.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ((Get-MediaNormalizerPlatform) -eq 'Windows') {
        [StringComparison]::OrdinalIgnoreCase
    } else {
        [StringComparison]::Ordinal
    }
    if (-not $candidate.StartsWith($rootWithSeparator, $comparison)) {
        throw "出力階層が出力ルート外を指しています: $candidate"
    }
    return $candidate
}

function Get-MediaInputFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$InputPath,
        [switch]$Recurse
    )

    $files = [Collections.Generic.List[System.IO.FileInfo]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $InputPath) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        $fullPath = [IO.Path]::GetFullPath($item)
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            if ($seen.Add($fullPath)) {
                $files.Add([IO.FileInfo]::new($fullPath))
            }
            continue
        }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
            throw "入力パスが見つかりません: $fullPath"
        }
        $children = if ($Recurse) {
            Get-ChildItem -LiteralPath $fullPath -File -Recurse
        } else {
            Get-ChildItem -LiteralPath $fullPath -File
        }
        foreach ($child in $children) {
            if ($seen.Add($child.FullName)) { $files.Add($child) }
        }
    }
    return ,$files.ToArray()
}

function Get-MediaInputRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$InputPath)

    [string[]]$directories = @($InputPath | ForEach-Object {
        $fullPath = [IO.Path]::GetFullPath($_)
        if (Test-Path -LiteralPath $fullPath -PathType Container) {
            $fullPath
        } else {
            Split-Path -Parent $fullPath
        }
    })
    if ($directories.Count -eq 0) {
        throw '入力ルートを解決できません。'
    }

    $candidate = $directories[0]
    while (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $prefix = $candidate.TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $allInside = $true
        foreach ($directory in $directories) {
            if (-not (
                    [string]::Equals($directory, $candidate, [StringComparison]::OrdinalIgnoreCase) -or
                    $directory.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
                $allInside = $false
                break
            }
        }
        if ($allInside) { return $candidate }
        $parent = Split-Path -Parent $candidate
        if ($parent -eq $candidate) { break }
        $candidate = $parent
    }
    return $directories[0]
}

function New-SafeOutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FinalPath,
        [string]$RunId
    )

    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($FinalPath))
    $extension = [IO.Path]::GetExtension($FinalPath)
    $baseName = [IO.Path]::GetFileNameWithoutExtension($FinalPath)
    $runMarker = if ($RunId) { "$RunId-" } else { '' }
    Join-Path $directory (".{0}.media-normalizer-{1}{2}" -f
        $baseName, $runMarker, ([guid]::NewGuid().ToString('N') + $extension))
}

function Resolve-MediaNormalizerExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('FFmpeg', 'FFprobe')][string]$Name)

    $resolved = Resolve-MediaNormalizerCommand -Name $Name
    if (-not [string]::IsNullOrWhiteSpace($resolved)) { return $resolved }
    # CLI preflight reports a missing system command. Keeping the conventional name here
    # preserves direct Core calls and lets injected process runners be tested without tools.
    return $Name.ToLowerInvariant()
}

function Get-MediaInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [pscustomobject]$State,
        [scriptblock]$Logger,
        [scriptblock]$Progress,
        [scriptblock]$PumpEvents,
        [switch]$CliMode,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )

    $arguments = @(
        '-v', 'error',
        '-show_streams',
        '-show_chapters',
        '-show_format',
        '-of', 'json',
        $FilePath
    )
    $result = Invoke-MediaNormalizerProcess `
        -FilePath (Resolve-MediaNormalizerExecutable -Name FFprobe) `
        -Arguments $arguments `
        -State $State `
        -PhaseLabel '情報取得中' `
        -Logger $Logger `
        -Progress $Progress `
        -PumpEvents $PumpEvents `
        -CliMode:$CliMode `
        -CancellationToken $CancellationToken `
        -TrackElapsedForEta $false `
        -TrackPhaseProgress $false `
        -SlowWarnSeconds 0
    if ($result.ExitCode -ne 0) {
        throw "ffprobe による検証に失敗しました: $FilePath"
    }
    try {
        $probe = $result.StdoutText | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "ffprobe の検証結果を解析できません: $FilePath"
    }

    $streamCounts = @{ audio = 0; video = 0; subtitle = 0; data = 0; attachment = 0 }
    $streamTags = [Collections.Generic.List[object]]::new()
    foreach ($stream in @($probe.streams)) {
        $type = [string]$stream.codec_type
        if ($streamCounts.ContainsKey($type)) { $streamCounts[$type]++ }
        $tags = if ($stream.PSObject.Properties['tags']) { $stream.tags } else { $null }
        $streamTags.Add([pscustomobject]@{
            Index            = [int]$stream.index
            Type             = $type
            Tags             = $tags
            CodecName        = if ($stream.PSObject.Properties['codec_name']) { [string]$stream.codec_name } else { $null }
            Channels         = if ($stream.PSObject.Properties['channels']) { [int]$stream.channels } else { $null }
            SampleFmt        = if ($stream.PSObject.Properties['sample_fmt']) { [string]$stream.sample_fmt } else { $null }
            SampleRate       = if ($stream.PSObject.Properties['sample_rate']) { [string]$stream.sample_rate } else { $null }
            BitsPerSample    = if ($stream.PSObject.Properties['bits_per_sample']) { [int]$stream.bits_per_sample } else { $null }
            BitsPerRawSample = if ($stream.PSObject.Properties['bits_per_raw_sample']) { [string]$stream.bits_per_raw_sample } else { $null }
            PixelFormat      = if ($stream.PSObject.Properties['pix_fmt']) { [string]$stream.pix_fmt } else { $null }
            ColorRange       = if ($stream.PSObject.Properties['color_range']) { [string]$stream.color_range } else { $null }
            ColorSpace       = if ($stream.PSObject.Properties['color_space']) { [string]$stream.color_space } else { $null }
            ColorTransfer    = if ($stream.PSObject.Properties['color_transfer']) { [string]$stream.color_transfer } else { $null }
            ColorPrimaries   = if ($stream.PSObject.Properties['color_primaries']) { [string]$stream.color_primaries } else { $null }
        })
    }
    $duration = 0.0
    if ($probe.PSObject.Properties['format'] -and
        $probe.format.PSObject.Properties['duration'] -and
        $probe.format.duration) {
        [void][double]::TryParse(
            [string]$probe.format.duration,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$duration)
    }

    return [pscustomobject]@{
        Path         = [IO.Path]::GetFullPath($FilePath)
        # Normalization stages are deliberately dot-prefixed. PowerShell's
        # filesystem provider hides those paths unless Get-Item uses -Force.
        Length       = (Get-Item -LiteralPath $FilePath -Force).Length
        DurationSec  = $duration
        StreamCounts = $streamCounts
        ChapterCount = if ($probe.PSObject.Properties['chapters']) { @($probe.chapters).Count } else { 0 }
        FormatTags   = if ($probe.PSObject.Properties['format'] -and
            $probe.format.PSObject.Properties['tags']) { $probe.format.tags } else { $null }
        StreamTags   = $streamTags.ToArray()
    }
}

function Compare-MediaInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$InputInventory,
        [Parameter(Mandatory)]$OutputInventory,
        [Parameter(Mandatory)][ValidateSet('audio', 'video')][string]$Mode,
        # 速度変更時のみ$true。data/attachmentのストリーム数減少をerrorsではなくwarningsとして扱う
        # (設計判断8。Phase 2A実測で両ストリームの保持が実装到達可能な範囲で不安定と判明したため、
        # 速度変更時は常にdrop側になる。100%速度の既存保持経路には影響しない)。
        [switch]$AllowAncillaryStreamDrop
    )

    $errors = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $droppedAudioStreams = [math]::Max(
        0,
        [int]$InputInventory.StreamCounts.audio -
        [int]$OutputInventory.StreamCounts.audio)
    if ($OutputInventory.Length -le 0) { $errors.Add('出力ファイルが空です。') }
    if ($OutputInventory.DurationSec -le 0) { $errors.Add('出力の再生時間を確認できません。') }
    if ($OutputInventory.StreamCounts.audio -lt 1) { $errors.Add('出力に音声トラックがありません。') }

    if ($Mode -eq 'audio' -and $droppedAudioStreams -gt 0) {
        $warnings.Add(
            "音声出力で $droppedAudioStreams 個の音声トラックが保持されませんでした " +
            "($($OutputInventory.StreamCounts.audio) < $($InputInventory.StreamCounts.audio))")
    } elseif ($Mode -eq 'video') {
        foreach ($type in @('video', 'audio', 'subtitle', 'data', 'attachment')) {
            if ($OutputInventory.StreamCounts[$type] -lt $InputInventory.StreamCounts[$type]) {
                $message = (
                    "出力の $type ストリーム数が入力より少ないです " +
                    "($($OutputInventory.StreamCounts[$type]) < $($InputInventory.StreamCounts[$type]))")
                if ($AllowAncillaryStreamDrop -and $type -in @('data', 'attachment')) {
                    $warnings.Add($message)
                } else {
                    $errors.Add($message)
                }
            }
        }
        if ($OutputInventory.ChapterCount -lt $InputInventory.ChapterCount) {
            $errors.Add(
                "出力のチャプター数が入力より少ないです " +
                "($($OutputInventory.ChapterCount) < $($InputInventory.ChapterCount))")
        }

        if ($InputInventory.FormatTags) {
            foreach ($property in $InputInventory.FormatTags.PSObject.Properties) {
                if ($property.Name -in @('encoder', 'major_brand', 'minor_version', 'compatible_brands')) {
                    continue
                }
                $outputProperty = if ($OutputInventory.FormatTags) {
                    $OutputInventory.FormatTags.PSObject.Properties[$property.Name]
                } else { $null }
                if (-not $outputProperty -or [string]$outputProperty.Value -ne [string]$property.Value) {
                    $errors.Add("メタデータが保持されていません: $($property.Name)")
                }
            }
        }
        foreach ($type in @('video', 'audio', 'subtitle', 'data', 'attachment')) {
            $inputStreams = @($InputInventory.StreamTags | Where-Object Type -eq $type)
            $outputStreams = @($OutputInventory.StreamTags | Where-Object Type -eq $type)
            for ($index = 0; $index -lt $inputStreams.Count; $index++) {
                if (-not $inputStreams[$index].Tags -or $index -ge $outputStreams.Count) {
                    continue
                }
                foreach ($property in $inputStreams[$index].Tags.PSObject.Properties) {
                    if ($property.Name -in @(
                            'encoder',
                            'vendor_id',
                            'handler_name',
                            'DURATION',
                            'NUMBER_OF_FRAMES',
                            'NUMBER_OF_BYTES')) {
                        continue
                    }
                    $outputProperty = if ($outputStreams[$index].Tags) {
                        $outputStreams[$index].Tags.PSObject.Properties[$property.Name]
                    } else { $null }
                    if (-not $outputProperty -or
                        [string]$outputProperty.Value -ne [string]$property.Value) {
                        $errors.Add(
                            "${type}[$index] のメタデータが保持されていません: $($property.Name)")
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        IsValid             = $errors.Count -eq 0
        Errors              = $errors.ToArray()
        Warnings            = $warnings.ToArray()
        DroppedAudioStreams = $droppedAudioStreams
    }
}

function Complete-SafeOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TemporaryPath,
        [Parameter(Mandatory)][string]$FinalPath
    )

    $temporaryFull = [IO.Path]::GetFullPath($TemporaryPath)
    $finalFull = [IO.Path]::GetFullPath($FinalPath)
    if (-not (Test-Path -LiteralPath $temporaryFull -PathType Leaf)) {
        throw "検証済み一時出力が見つかりません: $temporaryFull"
    }
    if (-not [string]::Equals(
            (Split-Path -Parent $temporaryFull),
            (Split-Path -Parent $finalFull),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw '安全な置換には最終出力と同じディレクトリの一時ファイルが必要です。'
    }

    if (Test-Path -LiteralPath $finalFull -PathType Leaf) {
        $backupPath = New-SafeOutputPath -FinalPath ($finalFull + '.rollback')
        try {
            [IO.File]::Replace($temporaryFull, $finalFull, $backupPath, $true)
            if (Test-Path -LiteralPath $backupPath) {
                Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
            }
        } catch {
            if ((Test-Path -LiteralPath $backupPath) -and -not (Test-Path -LiteralPath $finalFull)) {
                Move-Item -LiteralPath $backupPath -Destination $finalFull
            }
            throw
        }
    } else {
        Move-Item -LiteralPath $temporaryFull -Destination $finalFull
    }
}

function Get-MediaLoudnessAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        # 互換のため保持。測定値は目標非依存のため本関数では未使用（設計判断 4）。
        [double]$Target = -16.0,
        [double]$TruePeak = -1.0,
        [pscustomobject]$State,
        [scriptblock]$Logger,
        [scriptblock]$Progress,
        [scriptblock]$PumpEvents,
        [switch]$CliMode,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None,
        [double]$CurrentFileDurationSec = -1.0,
        [string]$PhaseLabel = '解析中'
    )

    $inventory = Get-MediaInventory -FilePath $FilePath `
        -State $State -Logger $Logger -Progress $Progress -PumpEvents $PumpEvents -CliMode:$CliMode `
        -CancellationToken $CancellationToken
    $audioCount = [int]$inventory.StreamCounts.audio
    if ($audioCount -lt 1) {
        throw "音声トラックが見つかりません: $FilePath"
    }

    $streams = [Collections.Generic.List[object]]::new()
    for ($audioIndex = 0; $audioIndex -lt $audioCount; $audioIndex++) {
        if (Test-MediaNormalizerCancellationRequested -State $State -CancellationToken $CancellationToken) {
            throw "キャンセルされました: $FilePath (audio=$audioIndex)"
        }

        $filter = 'loudnorm=print_format=json'
        $arguments = @(
            '-hide_banner',
            '-nostats',
            '-v', 'info',
            '-i', $FilePath,
            '-map', "0:a:$audioIndex",
            '-af', $filter,
            '-f', 'null',
            '-'
        )
        $result = Invoke-MediaNormalizerProcess `
            -FilePath (Resolve-MediaNormalizerExecutable -Name FFmpeg) `
            -Arguments $arguments `
            -State $State `
            -PhaseLabel $PhaseLabel `
            -Logger $Logger `
            -Progress $Progress `
            -PumpEvents $PumpEvents `
            -CliMode:$CliMode `
            -CurrentFileDurationSec $CurrentFileDurationSec `
            -TrackElapsedForEta $false `
            -TrackPhaseProgress $true `
            -PhaseProgressBasePercent ([double]$audioIndex / $audioCount * 100.0) `
            -PhaseProgressScale (1.0 / $audioCount) `
            -WriteProgressFile `
            -CancellationToken $CancellationToken
        if ($result.ExitCode -ne 0) {
            throw "ffmpeg によるラウドネス解析に失敗しました: $FilePath (audio=$audioIndex)"
        }
        $text = $result.StderrText
        $analysisMatches = [regex]::Matches($text, '(?s)\{\s*"input_i".*?\}')
        if ($analysisMatches.Count -eq 0) {
            # loudnorm の JSON は通常 stderr に出るが、ビルド差異に備えて stdout も連結し再試行する。
            $text = $result.StderrText + "`n" + $result.StdoutText
            $analysisMatches = [regex]::Matches($text, '(?s)\{\s*"input_i".*?\}')
        }
        if ($analysisMatches.Count -eq 0) {
            throw "ラウドネス解析結果を取得できません: $FilePath (audio=$audioIndex)"
        }
        try {
            $stats = $analysisMatches[$analysisMatches.Count - 1].Value | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "ラウドネス解析結果を解析できません: $FilePath (audio=$audioIndex)"
        }

        $integrated = 0.0
        $peak = 0.0
        $range = 0.0
        if (-not [double]::TryParse(
                [string]$stats.input_i,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$integrated)) {
            throw "Integrated Loudness が不正です: $($stats.input_i)"
        }
        if (-not [double]::TryParse(
                [string]$stats.input_tp,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$peak)) {
            throw "True Peak が不正です: $($stats.input_tp)"
        }
        [void][double]::TryParse(
            [string]$stats.input_lra,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$range)

        $streams.Add([pscustomobject]@{
            AudioStreamIndex = $audioIndex
            IntegratedLufs   = $integrated
            TruePeakDbtp     = $peak
            LoudnessRangeLu  = $range
            Threshold        = [string]$stats.input_thresh
        })
    }

    return [pscustomobject]@{
        Path       = [IO.Path]::GetFullPath($FilePath)
        AnalyzedAt = (Get-Date).ToString('o')
        Streams    = $streams.ToArray()
    }
}

function Test-NormalizationNeeded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Analysis,
        [double]$Target,
        [double]$TruePeak,
        [ValidateRange(0.0, 10.0)][double]$Tolerance = 0.5
    )

    $reasons = [Collections.Generic.List[string]]::new()
    foreach ($stream in @($Analysis.Streams)) {
        $delta = [math]::Abs([double]$stream.IntegratedLufs - $Target)
        if ($delta -gt $Tolerance) {
            $reasons.Add(
                "audio[$($stream.AudioStreamIndex)] loudness delta " +
                "$($delta.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)) LU")
        }
        if ([double]$stream.TruePeakDbtp -gt $TruePeak) {
            $reasons.Add(
                "audio[$($stream.AudioStreamIndex)] true peak " +
                "$($stream.TruePeakDbtp) dBTP > $TruePeak dBTP")
        }
    }

    return [pscustomobject]@{
        Needed  = $reasons.Count -gt 0
        Reasons = $reasons.ToArray()
    }
}

function Write-NormalizationReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Records,
        [hashtable]$Configuration
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        throw "レポート出力先にはJSONファイルパスを指定してください: $fullPath"
    }
    if (-not [string]::Equals(
            [IO.Path]::GetExtension($fullPath),
            '.json',
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "レポート出力先の拡張子は.jsonである必要があります: $fullPath"
    }
    $directory = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    $payload = [ordered]@{
        schemaVersion = 2
        generatedAt   = (Get-Date).ToString('o')
        configuration = $Configuration
        summary       = [ordered]@{
            total     = @($Records).Count
            normalized = @($Records | Where-Object Action -eq 'normalized').Count
            skipped    = @($Records | Where-Object Action -eq 'skipped').Count
            analyzed   = @($Records | Where-Object Action -eq 'analyzed').Count
            failed     = @($Records | Where-Object Action -eq 'failed').Count
        }
        files         = @($Records)
    }
    $temporary = "$fullPath.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        $payload | ConvertTo-Json -Depth 12 |
            Set-Content -LiteralPath $temporary -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $fullPath -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
    return $fullPath
}

function ConvertTo-SpeedPercent {
    [CmdletBinding()]
    param(
        [object]$Value,
        [int]$Default = 100
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        $Value = $Default
    }

    $percent = 0
    if (-not [int]::TryParse(
            [string]$Value,
            [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$percent)) {
        throw "速度(%) は 50 から 200 の整数で指定してください: $Value"
    }
    if ($percent -lt 50 -or $percent -gt 200) {
        throw "速度(%) は 50 から 200 の範囲で指定してください: $percent"
    }
    return $percent
}

function ConvertTo-SpeedFactorText {
    param([Parameter(Mandatory)][int]$SpeedPercent)
    $factor = [double]$SpeedPercent / 100.0
    return $factor.ToString('0.####', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-SpeedIntermediateProfile {
    <#
        速度変更の中間ファイルで使うコーデック・コンテナ・ancillary方針を
        入力ごとに一体で決定する（設計判断5・6、Phase 2A実測で確定）。
        Phase 2A実測により、data/attachmentストリームの「保持」は実装到達可能な
        範囲で不安定なため、AncillaryFallbackは常に drop 側（None/DropWithWarning）
        のみを返す。PreserveData/PreserveAttachmentsは常に $false。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('audio', 'video')][string]$Mode,
        [Parameter(Mandatory)][string]$InputExtension,
        [Parameter(Mandatory)]$Inventory
    )

    $ext = $InputExtension.ToLowerInvariant()
    if (-not $ext.StartsWith('.')) { $ext = '.' + $ext }
    $audioStreams = @($Inventory.StreamTags | Where-Object Type -eq 'audio')
    $hasAncillary = ([int]$Inventory.StreamCounts.data -gt 0) -or ([int]$Inventory.StreamCounts.attachment -gt 0)

    # tier: 0=可逆(ALAC/FLAC対応), 1=pcm_s32le, 2=pcm_f32le, 3=pcm_f64le
    # 複数音声ストリームのうち最も厳しい(値が大きい)tierを全体の判定に採用する。
    $tier = 0
    $tierReasons = [Collections.Generic.List[string]]::new()
    foreach ($stream in $audioStreams) {
        $channels = if ($null -ne $stream.Channels) { [int]$stream.Channels } else { 0 }
        $codecName = [string]$stream.CodecName
        # 既にPCM/ロスレスであるソース(pcm_*, flac, alac)だけ、sample_fmt/bits_per_sampleで
        # 実効精度を厳密判定する。AAC/MP3/Opus等の非可逆圧縮ソースはffprobe上sample_fmt=fltp等
        # (デコーダの内部表現)を報告するが、これは元の符号化精度を意味しない。素直にflt判定すると
        # 実務で遭遇するほぼ全ての動画がPCMへ落ち、ALAC/FLAC中間化が機能しなくなるため区別する
        # (Phase 2B実装時に実際のAAC音声で発覚)。
        $isLosslessSource = ($codecName -match '^pcm_') -or ($codecName -in @('flac', 'alac'))

        $streamTier = 0
        if (-not $isLosslessSource) {
            if ($channels -gt 8) {
                $streamTier = 1
                $tierReasons.Add("audio[$($stream.Index)] (codec=$codecName) は ${channels}ch (>8ch) のため pcm_s32le が必要")
            }
        } else {
            $sampleFmt = [string]$stream.SampleFmt
            $bits = 0
            $bitsOk = $false
            if ($stream.BitsPerSample -and [int]$stream.BitsPerSample -gt 0) {
                $bits = [int]$stream.BitsPerSample
                $bitsOk = $true
            } elseif ($stream.BitsPerRawSample) {
                $parsed = 0
                if ([int]::TryParse([string]$stream.BitsPerRawSample, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -gt 0) {
                    $bits = $parsed
                    $bitsOk = $true
                }
            }

            if ($sampleFmt -match '^dbl') {
                $streamTier = 3
                $tierReasons.Add("audio[$($stream.Index)] は dbl/dblp のため pcm_f64le が必要")
            } elseif ($sampleFmt -match '^flt') {
                $streamTier = 2
                $tierReasons.Add("audio[$($stream.Index)] は flt/fltp のため pcm_f32le が必要")
            } elseif (-not $bitsOk -or $channels -le 0) {
                $streamTier = 2
                $tierReasons.Add("audio[$($stream.Index)] は精度情報が欠落しているため品質優先で pcm_f32le")
            } elseif ($channels -gt 8) {
                $streamTier = 1
                $tierReasons.Add("audio[$($stream.Index)] は ${channels}ch (>8ch) のため pcm_s32le が必要")
            } elseif ($bits -gt 24) {
                $streamTier = 1
                $tierReasons.Add("audio[$($stream.Index)] は ${bits}bit (>24bit) のため pcm_s32le が必要")
            }
        }
        if ($streamTier -gt $tier) { $tier = $streamTier }
    }

    $pcmCodec = switch ($tier) {
        1 { 'pcm_s32le' }
        2 { 'pcm_f32le' }
        3 { 'pcm_f64le' }
        default { 'pcm_f32le' }
    }

    if ($Mode -eq 'audio') {
        if ($tier -eq 0) {
            return [pscustomobject]@{
                ProfileId           = 'audio-flac'
                Codec               = 'flac'
                ContainerExtension  = '.flac'
                PreserveData        = $false
                PreserveAttachments = $false
                AncillaryFallback   = 'None'
                UseFastStart        = $false
                SelectionReason     = '全音声ストリームがFLAC可逆化条件(channels<=8, 非float/double, 実効精度<=24bit)を満たす'
            }
        }
        return [pscustomobject]@{
            ProfileId           = 'audio-pcm-wav'
            Codec               = $pcmCodec
            ContainerExtension  = '.wav'
            PreserveData        = $false
            PreserveAttachments = $false
            AncillaryFallback   = 'None'
            UseFastStart        = $false
            SelectionReason     = ($tierReasons -join '; ')
        }
    }

    # video
    if ($tier -eq 0 -and -not $hasAncillary -and $ext -in @('.mp4', '.mov', '.mkv')) {
        return [pscustomobject]@{
            ProfileId           = 'video-alac-same-container'
            Codec               = 'alac'
            ContainerExtension  = $ext
            PreserveData        = $false
            PreserveAttachments = $false
            AncillaryFallback   = 'None'
            UseFastStart        = ($ext -in @('.mp4', '.mov'))
            SelectionReason     = '全音声ストリームがALAC可逆化条件を満たし、data/attachmentを持たないため元コンテナを維持'
        }
    }

    if ($tier -eq 0) {
        $reason = if ($hasAncillary) {
            'ALAC条件は満たすが、data/attachmentを持つため同一コンテナ維持ではtimecode等の' +
            'メタデータ喪失が実測で確認されており(Phase 2A)、MKVへ変換してFLACを使う'
        } else {
            "入力コンテナ $ext は速度変更の実測対象コンテナではないため、MKVへ変換してFLACを使う"
        }
        return [pscustomobject]@{
            ProfileId           = 'video-flac-mkv'
            Codec               = 'flac'
            ContainerExtension  = '.mkv'
            PreserveData        = $false
            PreserveAttachments = $false
            AncillaryFallback   = if ($hasAncillary) { 'DropWithWarning' } else { 'None' }
            UseFastStart        = $false
            SelectionReason     = $reason
        }
    }

    return [pscustomobject]@{
        ProfileId           = 'video-pcm-mkv'
        Codec               = $pcmCodec
        ContainerExtension  = '.mkv'
        PreserveData        = $false
        PreserveAttachments = $false
        AncillaryFallback   = if ($hasAncillary) { 'DropWithWarning' } else { 'None' }
        UseFastStart        = $false
        SelectionReason     = ($tierReasons -join '; ')
    }
}

function Test-VideoSpeedChangeSafety {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory)

    $reasons = [Collections.Generic.List[string]]::new()
    foreach ($stream in @($Inventory.StreamTags | Where-Object Type -eq 'video')) {
        $pixelFormat = [string]$stream.PixelFormat
        $rawBits = 0
        [void][int]::TryParse([string]$stream.BitsPerRawSample, [ref]$rawBits)
        if ($rawBits -gt 8 -or $pixelFormat -match '(p|yuv|gbr).*(10|12|14|16)(le|be)?$') {
            $reasons.Add("video[$($stream.Index)] は8bitを超える映像です (pix_fmt=$pixelFormat, bits=$rawBits)")
        }
        if ([string]$stream.ColorTransfer -in @('smpte2084', 'arib-std-b67')) {
            $reasons.Add("video[$($stream.Index)] はHDR伝達特性を使用しています (transfer=$($stream.ColorTransfer))")
        }
        if ([string]$stream.ColorPrimaries -eq 'bt2020' -or
            [string]$stream.ColorSpace -like 'bt2020*') {
            $reasons.Add("video[$($stream.Index)] はBT.2020色域を使用しています")
        }
    }

    return [pscustomobject]@{
        IsSafe  = $reasons.Count -eq 0
        Reasons = $reasons.ToArray()
    }
}

function New-FfmpegSpeedArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('audio', 'video')][string]$Mode,
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][int]$SpeedPercent,
        [Parameter(Mandatory)]$IntermediateProfile
    )

    $factorText = ConvertTo-SpeedFactorText -SpeedPercent $SpeedPercent
    if ($Mode -eq 'audio') {
        return @(
            '-y', '-i', $InputPath,
            '-vn',
            '-filter:a', "atempo=$factorText",
            '-c:a', $IntermediateProfile.Codec,
            $OutputPath
        )
    }

    $arguments = @(
        '-y', '-i', $InputPath,
        '-map', '0:v?',
        '-map', '0:a?',
        '-map', '0:s?'
    )
    if ($IntermediateProfile.PreserveData) { $arguments += @('-map', '0:d?') }
    if ($IntermediateProfile.PreserveAttachments) { $arguments += @('-map', '0:t?') }
    $arguments += @(
        '-filter:v', "setpts=PTS/$factorText",
        '-filter:a', "atempo=$factorText",
        '-c:v', 'libx264',
        '-preset', 'medium',
        '-crf', '20',
        '-pix_fmt', 'yuv420p',
        '-c:a', $IntermediateProfile.Codec,
        '-c:s', 'copy'
    )
    if ($IntermediateProfile.PreserveData) { $arguments += @('-c:d', 'copy') }
    if ($IntermediateProfile.PreserveAttachments) { $arguments += @('-c:t', 'copy') }
    $arguments += @('-map_metadata', '0', '-map_chapters', '0')
    if (-not $IntermediateProfile.PreserveData) {
        # mov/mp4系muxerが映像ストリームのtimecodeメタデータからtmcdトラックを
        # 自動再生成することがあるため(Phase 2A実測)、data未保持時は明示的に無効化する。
        # MKV出力でも無害(muxerが認識せず無視する、Phase 2A実測で確認済み)。
        $arguments += @('-write_tmcd', 'false')
    }
    if ($IntermediateProfile.UseFastStart) {
        $arguments += @('-movflags', '+faststart')
    }
    return @($arguments) + $OutputPath
}

function Remove-MediaNormalizerTemporaryFile {
    [CmdletBinding()]
    param(
        [string]$LiteralPath,
        [ValidateRange(1, 100)][int]$RetryCount = 10,
        [ValidateRange(0, 5000)][int]$RetryDelayMilliseconds = 50
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) { return $true }
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        if (-not (Test-Path -LiteralPath $LiteralPath)) { return $true }
        try {
            Remove-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        } catch {
            if ($attempt -eq $RetryCount) { return $false }
        }
        if (-not (Test-Path -LiteralPath $LiteralPath)) { return $true }
        if ($attempt -lt $RetryCount -and $RetryDelayMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $RetryDelayMilliseconds
        }
    }
    return $false
}

function New-FfmpegNormalizeArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('audio', 'video')][string]$Mode,
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [double]$Target,
        [double]$TruePeak,
        [string]$Bitrate,
        [string]$SampleRate,
        [ValidateSet('mp3', 'm4a', 'aac', 'flac', 'wav', 'opus', 'ogg')]
        [string]$AudioOutputFormat = 'mp3'
    )

    $arguments = @(
        $InputPath,
        '-nt', 'ebu',
        '-t', $Target.ToString('0.0###', [Globalization.CultureInfo]::InvariantCulture),
        '-tp', $TruePeak.ToString('0.0###', [Globalization.CultureInfo]::InvariantCulture)
    )
    if ($Mode -eq 'audio') {
        $audioProfile = Get-AudioOutputProfile `
            -Format $AudioOutputFormat `
            -Bitrate $Bitrate `
            -SampleRate $SampleRate
        $arguments += '-vn'
        $arguments += $audioProfile.NormalizeArgs
    } else {
        $arguments += @(
            '-c:v', 'copy',
            '-c:a', 'aac',
            '-b:a', $Bitrate,
            '-ar', $SampleRate
        )
    }
    $arguments += @('-o', $OutputPath, '-pr', '-p', '-f')
    return $arguments
}

function ConvertTo-ProcessArgumentList {
    param([Parameter(Mandatory)][object[]]$Arguments)
    return @($Arguments | ForEach-Object {
        $value = [string]$_
        if ($value.Length -eq 0) { return '""' }
        if ($value -notmatch '[\s"]') { return $value }

        # Start-Process は ArgumentList を最終的に1本のWindowsコマンドラインへ結合する。
        # CommandLineToArgvW / C runtime規則に従い、引用符直前と終端のbackslashを二重化する。
        $escaped = [regex]::Replace($value, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        return '"' + $escaped + '"'
    })
}

function ConvertTo-DisplayCommandArguments {
    param([Parameter(Mandatory)][object[]]$Arguments)
    return (($Arguments | ForEach-Object {
        if ($_ -match '[\s&()`;|<>!''"]') {
            $escaped = $_ -replace '"', '\"'
            "`"$escaped`""
        } else { $_ }
    }) -join ' ')
}

function New-MediaNormalizerState {
    [pscustomobject]@{
        CachedFiles         = @()
        DurationMap         = @{}
        ReservedOutPaths    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        CancelRequested     = $false
        RunningProcess      = $null
        FileIndex           = @{}
        HasThreadJob        = $false
        FfprobeAvailable    = $null
        ScanValid           = $false
        ProgressTotal       = 0
        ProgressCurrent     = 0
        TotalDurationSec    = 0.0
        ProcessedDurationSec = 0.0
        ProcessingStartTime = $null
        CurrentFileElapsedSec = 0.0
        ReportRecords       = [System.Collections.Generic.List[object]]::new()
        ReportPath          = $null
        CurrentPhase         = $null
        PhaseProgressPercent = -1.0
    }
}

function Get-MediaNormalizerLogFileLength {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0L }
    try { return (Get-Item -LiteralPath $Path).Length } catch { return 0L }
}

function Test-MediaNormalizerCancellationRequested {
    param(
        [pscustomobject]$State,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )

    return (($State -and $State.CancelRequested) -or
        ($CancellationToken -and $CancellationToken.IsCancellationRequested))
}

function Wait-MediaNormalizerProcessWithProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ProcessLike,
        [string]$StdoutPath,
        [string]$StderrPath,
        [Parameter(Mandatory)][pscustomobject]$State,
        [scriptblock]$Logger,
        [scriptblock]$Progress,
        [scriptblock]$PumpEvents,
        [switch]$CliMode,
        [double]$CurrentFileDurationSec = -1.0,
        [string]$HeartbeatLabel = '実行中...',
        [string]$LongRunningMessage = '長時間処理中です。動画サイズ次第で数分以上かかることがあります。',
        [int]$SlowWarnSeconds = 120,
        [scriptblock]$CancelAction,
        [scriptblock]$OutputPump,
        [Alias('UpdateElapsedFromProgress')]
        [bool]$TrackElapsedForEta = $true,
        [bool]$TrackPhaseProgress = $false,
        [double]$PhaseProgressBasePercent = 0.0,
        [double]$PhaseProgressScale = 1.0,
        [double]$ProgressSpeedFactor = 1.0,
        [double]$ProgressBaseSec = 0.0,
        [double]$ProgressScale = 1.0,
        [double]$HeartbeatIntervalSeconds = 5.0,
        [double]$UiUpdateIntervalSeconds = 0.25,
        [int]$SleepMilliseconds = 100,
        [scriptblock]$GetNow = { Get-Date },
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )

    $startAt = & $GetNow
    $lastHeartbeat = $startAt
    $lastUiUpdate = $startAt
    $lastOutSize = 0L
    $lastErrSize = 0L
    $slowWarned = $false
    $cancelSignalled = $false

    while (-not $ProcessLike.HasExited) {
        if ($OutputPump) { & $OutputPump }
        if ($PumpEvents -and (-not $CliMode -or $State.PSObject.Properties['WorkerProtocolContext'])) { & $PumpEvents }
        Start-Sleep -Milliseconds $SleepMilliseconds
        if ($OutputPump) { & $OutputPump }

        if ((Test-MediaNormalizerCancellationRequested -State $State -CancellationToken $CancellationToken) -and
            -not $cancelSignalled -and -not $ProcessLike.HasExited) {
            if ($CancelAction) { & $CancelAction }
            $cancelSignalled = $true
        }

        $now = & $GetNow

        if ((($now - $lastHeartbeat).TotalSeconds) -ge $HeartbeatIntervalSeconds) {
            $elapsedSec = [int](($now - $startAt).TotalSeconds)
            $stdoutSize = Get-MediaNormalizerLogFileLength -Path $StdoutPath
            $stderrSize = Get-MediaNormalizerLogFileLength -Path $StderrPath
            $deltaBytes = ($stdoutSize - $lastOutSize) + ($stderrSize - $lastErrSize)

            if ($Logger) {
                if ($deltaBytes -gt 0) {
                    & $Logger "  [DEBUG] $HeartbeatLabel ${elapsedSec}s (ログ増加 ${deltaBytes} bytes)"
                } else {
                    & $Logger "  [DEBUG] $HeartbeatLabel ${elapsedSec}s"
                }
            }

            if ($Logger -and -not $slowWarned -and $SlowWarnSeconds -gt 0 -and $elapsedSec -ge $SlowWarnSeconds) {
                & $Logger "  [INFO ] $LongRunningMessage"
                $slowWarned = $true
            }

            $lastOutSize = $stdoutSize
            $lastErrSize = $stderrSize
            $lastHeartbeat = $now
        }

        if ((($now - $lastUiUpdate).TotalSeconds) -ge $UiUpdateIntervalSeconds) {
            $partialSec = -1.0
            if ($TrackElapsedForEta -or $TrackPhaseProgress) {
                $partialSec = Get-FfmpegProgress -StderrPath $StderrPath -StdoutPath $StdoutPath -CurrentFileDurationSec $CurrentFileDurationSec -SpeedFactor $ProgressSpeedFactor
            }
            if ($TrackElapsedForEta -and $partialSec -gt 0) {
                $scaledSec = $ProgressBaseSec + ($partialSec * $ProgressScale)
                if ($CurrentFileDurationSec -gt 0) {
                    $scaledSec = [math]::Min($CurrentFileDurationSec, $scaledSec)
                }
                $State.CurrentFileElapsedSec = [math]::Max(0.0, $scaledSec)
            }
            if ($TrackPhaseProgress -and $partialSec -ge 0 -and $CurrentFileDurationSec -gt 0) {
                $streamPercent = [math]::Max(0.0, [math]::Min(100.0, ($partialSec / $CurrentFileDurationSec) * 100.0))
                $State.PhaseProgressPercent = [math]::Max(
                    0.0,
                    [math]::Min(100.0, $PhaseProgressBasePercent + ($streamPercent * $PhaseProgressScale)))
            }
            if ($Progress) { & $Progress $State.ProgressCurrent $State.ProgressTotal }
            $lastUiUpdate = $now
        }
    }
}

function Send-MediaNormalizerWorkerProcessEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Fields
    )

    $event = [ordered]@{ schemaVersion = 1; type = $Type }
    foreach ($key in $Fields.Keys) { $event[$key] = $Fields[$key] }
    $null = $Context.EventSink.Invoke([pscustomobject]$event)
}

function Get-MediaNormalizerProcessStartUtc {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)

    try {
        return [DateTimeOffset]::new($Process.StartTime.ToUniversalTime()).ToString('o')
    } catch {
        throw "[RECOVERY_REQUIRED] process開始時刻を取得できません: pid=$($Process.Id)"
    }
}

function Wait-MediaNormalizerWorkerProcessRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ProcessToken,
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$ProcessStartedAtUtc,
        [Parameter(Mandatory)][pscustomobject]$State,
        [scriptblock]$PumpEvents
    )

    $timeoutSeconds = if ($Context.AckTimeoutSeconds -gt 0) { [int]$Context.AckTimeoutSeconds } else { 10 }
    $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($PumpEvents) { $null = $PumpEvents.Invoke() }
        if ($Context.PendingProcessAcks.ContainsKey($ProcessToken)) {
            $ack = $Context.PendingProcessAcks[$ProcessToken]
            $Context.PendingProcessAcks.Remove($ProcessToken)
            if (-not $ack.accepted) { $Context.RecoveryRequired = $true; throw "[RECOVERY_REQUIRED] host rejected process registration: pid=$ProcessId" }
            $ackStartedAt = [DateTimeOffset]::Parse([string]$ack.processStartedAtUtc).UtcTicks
            $expectedStartedAt = [DateTimeOffset]::Parse($ProcessStartedAtUtc).UtcTicks
            if ([int]$ack.processId -ne $ProcessId -or $ackStartedAt -ne $expectedStartedAt) {
                $Context.RecoveryRequired = $true
                throw "[RECOVERY_REQUIRED] host process registration ACK identity mismatch: pid=$ProcessId"
            }
            return
        }
        # A started process must finish the registration handshake even when cancellation arrives.
        # The following wait stops it and emits process-exited after its identity is acknowledged.
        Start-Sleep -Milliseconds 25
    }
    $Context.RecoveryRequired = $true
    throw "[RECOVERY_REQUIRED] host process registration ACK timed out: pid=$ProcessId, runId=$RunId"
}

function Register-MediaNormalizerWorkerTemporaryOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$TemporaryPath,
        [Parameter(Mandatory)][string]$FinalPath,
        [Parameter(Mandatory)][ValidateSet('primary', 'speed')][string]$Role,
        [Parameter(Mandatory)][pscustomobject]$State,
        [scriptblock]$PumpEvents
    )

    $fullTemporaryPath = [IO.Path]::GetFullPath($TemporaryPath)
    if ($Context.ExpectedTemporaryPaths.ContainsKey($fullTemporaryPath)) {
        throw "[RECOVERY_REQUIRED] duplicate temporary output registration: $fullTemporaryPath"
    }
    $Context.ExpectedTemporaryPaths[$fullTemporaryPath] = $true
    Send-MediaNormalizerStructuredEvent -EventSink $Context.EventSink -Type 'temporary-output' -Fields @{
        runId = $RunId; inputPath = [IO.Path]::GetFullPath($InputPath)
        temporaryPath = $fullTemporaryPath; finalPath = [IO.Path]::GetFullPath($FinalPath); role = $Role
    }

    $timeoutSeconds = if ($Context.AckTimeoutSeconds -gt 0) { [int]$Context.AckTimeoutSeconds } else { 10 }
    $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($PumpEvents) { $null = $PumpEvents.Invoke() }
        if ($Context.PendingTemporaryAcks.ContainsKey($fullTemporaryPath)) {
            $ack = $Context.PendingTemporaryAcks[$fullTemporaryPath]
            $Context.PendingTemporaryAcks.Remove($fullTemporaryPath)
            $Context.ExpectedTemporaryPaths.Remove($fullTemporaryPath)
            if (-not $ack.accepted) {
                $Context.RecoveryRequired = $true
                throw "[RECOVERY_REQUIRED] host rejected temporary output registration: $fullTemporaryPath"
            }
            return
        }
        if (Test-MediaNormalizerCancellationRequested -State $State) {
            throw [OperationCanceledException]::new('Cancelled before temporary output registration was acknowledged.')
        }
        Start-Sleep -Milliseconds 25
    }
    $Context.RecoveryRequired = $true
    throw "[RECOVERY_REQUIRED] host temporary output registration ACK timed out: $fullTemporaryPath"
}

function Register-NormalizationTemporaryOutputIfSupported {
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$TemporaryPath,
        [Parameter(Mandatory)][string]$FinalPath,
        [Parameter(Mandatory)][ValidateSet('primary', 'speed')][string]$Role,
        [scriptblock]$PumpEvents
    )

    if ($State.PSObject.Properties['WorkerProtocolContext'] -and $State.WorkerProtocolContext.EventSink) {
        Register-MediaNormalizerWorkerTemporaryOutput -Context $State.WorkerProtocolContext -RunId $RunId -InputPath $InputPath `
            -TemporaryPath $TemporaryPath -FinalPath $FinalPath -Role $Role -State $State -PumpEvents $PumpEvents
    }
}

function Invoke-MediaNormalizerProcess {
    <#
        外部プロセス(ffmpeg/ffprobe/ffmpeg-normalize等)の起動・待機・キャンセル・後始末を
        一体化した共通runner。lib内の外部プロセス実行はここへ集約する
        (TODO.md MN-10 / plans/media-normalizer-ui-responsiveness-remediation-plan.md 設計判断1・2)。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [pscustomobject]$State,
        [string]$PhaseLabel,
        [scriptblock]$Logger,
        [scriptblock]$Progress,
        [scriptblock]$PumpEvents,
        [switch]$CliMode,
        [double]$CurrentFileDurationSec = -1.0,
        [bool]$TrackElapsedForEta = $true,
        [bool]$TrackPhaseProgress = $true,
        [double]$PhaseProgressBasePercent = 0.0,
        [double]$PhaseProgressScale = 1.0,
        [double]$ProgressSpeedFactor = 1.0,
        [double]$ProgressScale = 1.0,
        [double]$ProgressBaseSec = 0.0,
        [string]$LongRunningMessage = '長時間処理中です。動画サイズ次第で数分以上かかることがあります。',
        [int]$SlowWarnSeconds = 120,
        [double]$UiUpdateIntervalSeconds = 0.25,
        [switch]$WriteProgressFile,
        [int]$SleepMilliseconds = 100,
        [scriptblock]$GetNow = { Get-Date },
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )

    if (-not $State) { $State = New-MediaNormalizerState }
    if (-not $CliMode -and -not $PumpEvents -and $Logger) {
        & $Logger "  [WARN ] Invoke-MediaNormalizerProcess: PumpEvents 未指定です ($PhaseLabel)。UI が応答しなくなる可能性があります。"
    }

    $stdoutTmp = [IO.Path]::GetTempFileName()
    $stderrTmp = [IO.Path]::GetTempFileName()
    $progressTmp = $null
    $effectiveArguments = $Arguments
    if ($WriteProgressFile) {
        $progressTmp = [IO.Path]::GetTempFileName()
        $effectiveArguments = @('-progress', $progressTmp) + @($Arguments)
    }
    $progressSourcePath = if ($WriteProgressFile) { $progressTmp } else { $stdoutTmp }

    $State.CurrentPhase = $PhaseLabel
    $State.PhaseProgressPercent = -1.0
    if ($Progress) { & $Progress $State.ProgressCurrent $State.ProgressTotal }

    $proc = $null
    $useWindowsStartProcess = (Get-MediaNormalizerPlatform) -eq 'Windows'
    $stdoutWriter = $null
    $stderrWriter = $null
    $streamState = $null
    $outputPump = $null
    $retainTemporaryLogs = $false
    $workerContext = if ($State.PSObject.Properties['WorkerProtocolContext']) { $State.WorkerProtocolContext } else { $null }
    $processToken = [guid]::NewGuid().ToString('D')
    $processStartedAtUtc = $null
    $parentProcess = [Diagnostics.Process]::GetCurrentProcess()
    $parentStartedAtUtc = [DateTimeOffset]::new($parentProcess.StartTime.ToUniversalTime()).ToString('o')
    try {
        if ($workerContext) {
            Send-MediaNormalizerWorkerProcessEvent -Context $workerContext -Type 'process-starting' -Fields @{
                runId = $workerContext.RunId; processToken = $processToken; executablePath = $FilePath
                arguments = @($effectiveArguments); parentProcessId = $PID; parentStartedAtUtc = $parentStartedAtUtc
            }
        }
        if ($useWindowsStartProcess) {
            # WindowsのStart-Process / 引数引用規則は既存経路をそのまま保つ。
            $proc = Start-Process `
                -FilePath $FilePath `
                -ArgumentList (ConvertTo-ProcessArgumentList -Arguments $effectiveArguments) `
                -NoNewWindow `
                -PassThru `
                -RedirectStandardOutput $stdoutTmp `
                -RedirectStandardError $stderrTmp
            if ($workerContext) {
                try { $processStartedAtUtc = Get-MediaNormalizerProcessStartUtc -Process $proc }
                catch { $workerContext.RecoveryRequired = $true; throw }
            }
        } else {
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $FilePath
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in $effectiveArguments) {
                $startInfo.ArgumentList.Add([string]$argument)
            }

            $proc = [Diagnostics.Process]::new()
            $proc.StartInfo = $startInfo
            $stdoutWriter = [IO.StreamWriter]::new($stdoutTmp, $false, [Text.UTF8Encoding]::new($false))
            $stderrWriter = [IO.StreamWriter]::new($stderrTmp, $false, [Text.UTF8Encoding]::new($false))
            $stdoutWriter.AutoFlush = $true
            $stderrWriter.AutoFlush = $true
            if (-not $proc.Start()) { throw "外部processを開始できませんでした: $FilePath" }
            if ($workerContext) {
                try { $processStartedAtUtc = Get-MediaNormalizerProcessStartUtc -Process $proc }
                catch { $workerContext.RecoveryRequired = $true; throw }
            }
            $streamState = [pscustomobject]@{
                StdoutReader = $proc.StandardOutput
                StderrReader = $proc.StandardError
                StdoutBuffer = [char[]]::new(4096)
                StderrBuffer = [char[]]::new(4096)
                StdoutTask = $null
                StderrTask = $null
                StdoutComplete = $false
                StderrComplete = $false
            }
            $streamState.StdoutTask = $streamState.StdoutReader.ReadAsync($streamState.StdoutBuffer, 0, $streamState.StdoutBuffer.Length)
            $streamState.StderrTask = $streamState.StderrReader.ReadAsync($streamState.StderrBuffer, 0, $streamState.StderrBuffer.Length)
            $outputPump = {
                while (-not $streamState.StdoutComplete -and $streamState.StdoutTask.IsCompleted) {
                    $count = $streamState.StdoutTask.GetAwaiter().GetResult()
                    if ($count -eq 0) {
                        $streamState.StdoutComplete = $true
                    } else {
                        $stdoutWriter.Write($streamState.StdoutBuffer, 0, $count)
                        $stdoutWriter.Flush()
                        $streamState.StdoutTask = $streamState.StdoutReader.ReadAsync($streamState.StdoutBuffer, 0, $streamState.StdoutBuffer.Length)
                    }
                }
                while (-not $streamState.StderrComplete -and $streamState.StderrTask.IsCompleted) {
                    $count = $streamState.StderrTask.GetAwaiter().GetResult()
                    if ($count -eq 0) {
                        $streamState.StderrComplete = $true
                    } else {
                        $stderrWriter.Write($streamState.StderrBuffer, 0, $count)
                        $stderrWriter.Flush()
                        $streamState.StderrTask = $streamState.StderrReader.ReadAsync($streamState.StderrBuffer, 0, $streamState.StderrBuffer.Length)
                    }
                }
            }.GetNewClosure()
        }
        $State.RunningProcess = $proc
        if ($workerContext) {
            Send-MediaNormalizerWorkerProcessEvent -Context $workerContext -Type 'process-started' -Fields @{
                runId = $workerContext.RunId; processToken = $processToken; processId = [int]$proc.Id
                processStartedAtUtc = $processStartedAtUtc; executablePath = $FilePath
                parentProcessId = $PID; parentStartedAtUtc = $parentStartedAtUtc
            }
            Wait-MediaNormalizerWorkerProcessRegistration -Context $workerContext -RunId $workerContext.RunId `
                -ProcessToken $processToken -ProcessId ([int]$proc.Id) -ProcessStartedAtUtc $processStartedAtUtc `
                -State $State -PumpEvents $PumpEvents
        }

        $cancelFired = $false
        $cancelAction = {
            if (-not $cancelFired -and $proc -and -not $proc.HasExited) {
                if ($useWindowsStartProcess) {
                    try { & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null } catch { }
                } else {
                    $stopResult = Stop-MediaNormalizerProcessTree -RootProcessId $proc.Id -GracePeriodSeconds 5
                    if (-not $stopResult.Stopped) {
                        throw "[RECOVERY_REQUIRED] 外部process treeを停止できません。PID=$($proc.Id), remaining=$($stopResult.RemainingProcessIds -join ',')"
                    }
                }
                $cancelFired = $true
            }
        }.GetNewClosure()

        Wait-MediaNormalizerProcessWithProgress `
            -ProcessLike $proc `
            -StdoutPath $progressSourcePath `
            -StderrPath $stderrTmp `
            -State $State `
            -Logger $Logger `
            -Progress $Progress `
            -PumpEvents $PumpEvents `
            -CliMode:$CliMode `
            -CurrentFileDurationSec $CurrentFileDurationSec `
            -HeartbeatLabel "$PhaseLabel..." `
            -LongRunningMessage $LongRunningMessage `
            -SlowWarnSeconds $SlowWarnSeconds `
            -CancelAction $cancelAction `
            -OutputPump $outputPump `
            -CancellationToken $CancellationToken `
            -TrackElapsedForEta $TrackElapsedForEta `
            -TrackPhaseProgress $TrackPhaseProgress `
            -PhaseProgressBasePercent $PhaseProgressBasePercent `
            -PhaseProgressScale $PhaseProgressScale `
            -UiUpdateIntervalSeconds $UiUpdateIntervalSeconds `
            -ProgressSpeedFactor $ProgressSpeedFactor `
            -ProgressScale $ProgressScale `
            -ProgressBaseSec $ProgressBaseSec `
            -SleepMilliseconds $SleepMilliseconds `
            -GetNow $GetNow

        $proc.WaitForExit()
        if (-not $useWindowsStartProcess) {
            # ReadLineAsyncの完了をメインRunspaceからdrainし、別スレッド上でPowerShellを実行しない。
            $drainDeadline = [DateTime]::UtcNow.AddSeconds(5)
            while ((-not $streamState.StdoutComplete -or -not $streamState.StderrComplete) -and
                [DateTime]::UtcNow -lt $drainDeadline) {
                & $outputPump
                if (-not $streamState.StdoutComplete -or -not $streamState.StderrComplete) {
                    Start-Sleep -Milliseconds 10
                }
            }
            if (-not $streamState.StdoutComplete -or -not $streamState.StderrComplete) {
                $retainTemporaryLogs = $true
                throw '[RECOVERY_REQUIRED] 子process stdout/stderr pipeが終了しませんでした。'
            }
            $stdoutWriter.Flush()
            $stderrWriter.Flush()
            $stdoutWriter.Dispose()
            $stderrWriter.Dispose()
            $stdoutWriter = $null
            $stderrWriter = $null
        }
        $exitCode = $proc.ExitCode
        if ($workerContext) {
            Send-MediaNormalizerWorkerProcessEvent -Context $workerContext -Type 'process-exited' -Fields @{
                runId = $workerContext.RunId; processToken = $processToken; processId = [int]$proc.Id
                processStartedAtUtc = $processStartedAtUtc; exitCode = [int]$exitCode
            }
        }

        $State.PhaseProgressPercent = 100.0
        if ($Progress) { & $Progress $State.ProgressCurrent $State.ProgressTotal }

        $stdoutText = if (Test-Path -LiteralPath $stdoutTmp) {
            Get-Content -LiteralPath $stdoutTmp -Raw -ErrorAction SilentlyContinue
        } else { '' }
        $stderrText = if (Test-Path -LiteralPath $stderrTmp) {
            Get-Content -LiteralPath $stderrTmp -Raw -ErrorAction SilentlyContinue
        } else { '' }
        if (-not $stdoutText) { $stdoutText = '' }
        if (-not $stderrText) { $stderrText = '' }

        $reportedExitCode = $exitCode
        if (-not $useWindowsStartProcess -and $exitCode -eq 0 -and
            (Test-MediaNormalizerCancellationRequested -State $State -CancellationToken $CancellationToken)) {
            # shell may return 0 after a terminated background child; preserve cancellation as non-success.
            $reportedExitCode = 130
        }
        return [pscustomobject]@{
            ExitCode   = $reportedExitCode
            StdoutText = $stdoutText
            StderrText = $stderrText
        }
    } finally {
        if (-not $useWindowsStartProcess -and $proc -and -not $proc.HasExited) {
            try {
                $stopResult = Stop-MediaNormalizerProcessTree -RootProcessId $proc.Id -GracePeriodSeconds 5
                if ($stopResult.Stopped) { $proc.WaitForExit(5000) | Out-Null }
                if (-not $proc.HasExited) { $retainTemporaryLogs = $true }
            } catch {
                $retainTemporaryLogs = $true
            }
        }
        if (-not $retainTemporaryLogs) {
            $State.RunningProcess = $null
        }
        $State.CurrentPhase = $null
        $State.PhaseProgressPercent = -1.0
        if ($Progress) { & $Progress $State.ProgressCurrent $State.ProgressTotal }
        if (-not $retainTemporaryLogs) {
            if ($stdoutWriter) { try { $stdoutWriter.Dispose() } catch { } }
            if ($stderrWriter) { try { $stderrWriter.Dispose() } catch { } }
            if ($proc) { try { $proc.Dispose() } catch { } }
            foreach ($tmp in @($stdoutTmp, $stderrTmp, $progressTmp)) {
                if ($tmp -and (Test-Path -LiteralPath $tmp)) {
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                }
            }
        } elseif ($Logger) {
            & $Logger "[ERROR] 子process treeの停止を確認できず、一時logを保持しました: stdout=$stdoutTmp stderr=$stderrTmp"
        }
    }
}

function Test-FfmpegNormalizePython {
    param([Parameter(Mandatory)][string]$Command)

    try {
        $null = & $Command -c 'import ffmpeg_normalize' 2>&1
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Find-FfmpegNormalize {
    [CmdletBinding()]
    param([ValidateSet('Windows', 'macOS', 'Linux')][string]$Platform = (Get-MediaNormalizerPlatform))

    $hasPinnedPython = -not [string]::IsNullOrWhiteSpace($env:MEDIA_NORMALIZER_PYTHON) -or
        -not [string]::IsNullOrWhiteSpace($env:MEDIA_NORMALIZER_RUNTIME_ROOT)
    if ($hasPinnedPython) {
        $pinnedPython = Resolve-MediaNormalizerCommand -Name Python -Platform $Platform
        if ($pinnedPython -and (Test-FfmpegNormalizePython -Command $pinnedPython)) {
            return [pscustomobject]@{
                Cmd  = $pinnedPython
                Args = @('-m', 'ffmpeg_normalize')
            }
        }
        # 同梱modeまたは明示Python指定では、PATH上の別runtimeへ移らない。
        return $null
    }

    # Windowsでは拡張子付きlauncherを維持し、POSIXではpipの拡張子なしentry pointを使う。
    $candidates = if ($Platform -eq 'Windows') {
        @('ffmpeg-normalize.exe', 'ffmpeg-normalize.cmd', 'ffmpeg-normalize.bat')
    } else {
        @('ffmpeg-normalize')
    }
    foreach ($candidate in $candidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) {
            return [pscustomobject]@{ Cmd = $command.Source; Args = @() }
        }
    }

    $pythonCandidates = if ($Platform -eq 'Windows') { @('py', 'python') } else { @('python3', 'python') }
    foreach ($candidate in $pythonCandidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command -and (Test-FfmpegNormalizePython -Command $command.Source)) {
            return [pscustomobject]@{ Cmd = $command.Source; Args = @('-m', 'ffmpeg_normalize') }
        }
    }
    return $null
}

function Resolve-UniqueOutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][string]$Extension,
        [ValidateSet('rename', 'skip', 'overwrite')][string]$Policy = 'rename',
        [int]$MaxAttempts = 999,
        [scriptblock]$Logger
    )

    if (-not $Extension.StartsWith('.')) { $Extension = '.' + $Extension }
    $original = Join-Path $Directory ($BaseName + $Extension)

    if ($Policy -eq 'overwrite') {
        [void]$State.ReservedOutPaths.Add($original)
        return $original
    }

    if (-not (Test-Path -LiteralPath $original) -and -not $State.ReservedOutPaths.Contains($original)) {
        [void]$State.ReservedOutPaths.Add($original)
        return $original
    }

    if ($Policy -eq 'skip') {
        return $null
    }

    for ($i = 2; $i -le $MaxAttempts; $i++) {
        $candidate = Join-Path $Directory ("$BaseName ($i)$Extension")
        if (-not (Test-Path -LiteralPath $candidate) -and -not $State.ReservedOutPaths.Contains($candidate)) {
            [void]$State.ReservedOutPaths.Add($candidate)
            return $candidate
        }
    }

    $stamp = Get-Date -Format 'yyyyMMddHHmmssfff'
    $fallback = Join-Path $Directory ("$BaseName ($stamp)$Extension")
    if ($Logger) { & $Logger "  [WARN ] Resolve-UniqueOutputPath: max attempts reached, using timestamp fallback ($fallback)" }
    [void]$State.ReservedOutPaths.Add($fallback)
    return $fallback
}

function Get-NormalizationRunFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][ValidateSet('audio', 'video')][string]$Mode,
        [Parameter(Mandatory)][string]$InputDir,
        [string[]]$InputPaths,
        [System.IO.FileInfo[]]$TargetFiles,
        [bool]$Recurse = $true,
        [scriptblock]$GetTargetExtensions
    )

    if ($TargetFiles) {
        return @($TargetFiles)
    }

    $effectiveInputs = if ($InputPaths -and $InputPaths.Count -gt 0) {
        @($InputPaths)
    } else {
        @($InputDir)
    }
    $allFiles = Get-MediaInputFiles -InputPath $effectiveInputs -Recurse:$Recurse
    $extMap = if ($GetTargetExtensions) {
        & $GetTargetExtensions
    } else {
        @{ Audio = Get-AudioInputExtensions; Video = Get-VideoInputExtensions }
    }
    $files = @($allFiles | Where-Object {
            $ext = $_.Extension.ToLower()
            if ($Mode -eq 'audio') { $ext -in $extMap.Audio }
            else { $ext -in $extMap.Video }
        })

    $State.ProgressTotal += $files.Count
    foreach ($file in $files) {
        if (-not $State.DurationMap.ContainsKey($file.FullName)) {
            $duration = Get-MediaDuration -State $State -FilePath $file.FullName
            $State.DurationMap[$file.FullName] = $duration
            if ($duration -gt 0) { $State.TotalDurationSec += $duration }
        }
    }

    return $files
}

function New-NormalizationReportRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter(Mandatory)][ValidateSet('audio', 'video')][string]$Mode,
        [Parameter(Mandatory)][string]$AudioOutputFormat
    )

    return [ordered]@{
        inputPath               = $File.FullName
        outputPath              = $null
        mode                    = $Mode
        outputFormat            = if ($Mode -eq 'audio') { $AudioOutputFormat } else { $File.Extension.TrimStart('.').ToLowerInvariant() }
        action                  = 'pending'
        startedAt               = (Get-Date).ToString('o')
        completedAt             = $null
        before                  = $null
        after                   = $null
        validation              = $null
        droppedAudioStreams     = 0
        reason                  = $null
        error                   = $null
        speedIntermediateProfile = $null
    }
}

function Get-NormalizationCurrentSpeedPercent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter(Mandatory)][int]$DefaultSpeedPercent,
        [hashtable]$SpeedPercentByPath
    )

    if ($SpeedPercentByPath -and $SpeedPercentByPath.ContainsKey($File.FullName)) {
        return ConvertTo-SpeedPercent `
            -Value $SpeedPercentByPath[$File.FullName] `
            -Default $DefaultSpeedPercent
    }
    return $DefaultSpeedPercent
}

function Get-NormalizationCurrentDuration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][System.IO.FileInfo]$File
    )

    if ($State.DurationMap.ContainsKey($File.FullName)) {
        $durationValue = $State.DurationMap[$File.FullName]
        if ($durationValue -and $durationValue -gt 0) {
            return [double]$durationValue
        }
    }
    return -1.0
}

function Get-MediaNormalizerRuntimePreflight {
    [CmdletBinding()]
    param([bool]$AnalyzeOnly, [scriptblock]$Logger)

    $runtimeCheckCommand = if ((Get-MediaNormalizerPlatform) -eq 'macOS') { 'runtime-check.sh' } else { 'runtime-check.bat' }
    $ffnorm = $null
    if (-not $AnalyzeOnly) {
        try {
            $ffnorm = Find-FfmpegNormalize
        } catch {
            & $Logger '[ERROR] ffmpeg-normalize runtimeを確認できません。'
            & $Logger "        $runtimeCheckCommand を実行し、同梱runtimeを確認してください。"
            & $Logger "        $($_.Exception.Message)"
            return [pscustomobject]@{ Available = $false; FfmpegNormalize = $null }
        }
    }
    if (-not $AnalyzeOnly -and -not $ffnorm) {
        if ($env:MEDIA_NORMALIZER_RUNTIME_ROOT) {
            & $Logger '[ERROR] 内蔵 ffmpeg-normalize を実行できません。'
            & $Logger "        $runtimeCheckCommand を実行し、ZIPを再展開してください。"
        } else {
            & $Logger '[ERROR] ffmpeg-normalize が見つからないか、Pythonモジュールを読み込めません。'
            $installCommand = if ((Get-MediaNormalizerPlatform) -eq 'Windows') {
                'py -m pip install --user ffmpeg-normalize'
            } else {
                'python3 -m pip install --user ffmpeg-normalize'
            }
            & $Logger "        開発環境では $installCommand を実行してください。"
        }
        return [pscustomobject]@{ Available = $false; FfmpegNormalize = $null }
    }

    foreach ($tool in @('FFmpeg', 'FFprobe')) {
        try {
            $command = Resolve-MediaNormalizerCommand -Name $tool
        } catch {
            & $Logger "[ERROR] $tool runtimeを確認できません: $($_.Exception.Message)"
            & $Logger "        $runtimeCheckCommand を実行し、同梱runtimeを確認してください。"
            return [pscustomobject]@{ Available = $false; FfmpegNormalize = $null }
        }
        if ($command) { continue }

        if ($tool -eq 'FFmpeg') {
            if ($env:MEDIA_NORMALIZER_RUNTIME_ROOT) {
                & $Logger "[ERROR] 内蔵 FFmpeg を実行できません。$runtimeCheckCommand を実行してください。"
            } else {
                & $Logger '[ERROR] ffmpeg が見つかりません。開発環境のPATHに追加してください。'
            }
        } else {
            & $Logger "[ERROR] 出力検証に必要な ffprobe が見つかりません。$runtimeCheckCommand を実行してください。"
        }
        return [pscustomobject]@{ Available = $false; FfmpegNormalize = $null }
    }

    return [pscustomobject]@{ Available = $true; FfmpegNormalize = $ffnorm }
}

function Send-MediaNormalizerStructuredEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$EventSink,
        [Parameter(Mandatory)][ValidateSet('run-start', 'file-start', 'progress', 'log', 'file-done', 'run-done', 'error', 'temporary-output')][string]$Type,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Fields
    )

    $event = [ordered]@{ schemaVersion = 1; type = $Type }
    foreach ($key in $Fields.Keys) { $event[$key] = $Fields[$key] }
    $null = & $EventSink ([pscustomobject]$event)
}

function Send-MediaNormalizerRunDoneEvent {
    [CmdletBinding()]
    param(
        [scriptblock]$EventSink,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][hashtable]$Result,
        [string]$ErrorMessage
    )

    if (-not $EventSink) { return }
    if ($ErrorMessage) {
        Send-MediaNormalizerStructuredEvent -EventSink $EventSink -Type error -Fields @{
            runId = $RunId
            code = 'RUN_FAILED'
            message = $ErrorMessage
        }
    }
    Send-MediaNormalizerStructuredEvent -EventSink $EventSink -Type run-done -Fields @{
        runId = $RunId
        success = [int]$Result.Success
        analyzed = if ($Result.ContainsKey('Analyzed')) { [int]$Result.Analyzed } else { 0 }
        fail = [int]$Result.Fail
        skipped = [int]$Result.Skipped
        cancelled = [int]$Result.Cancelled
        reportPath = if ($Result.ContainsKey('ReportPath')) { $Result.ReportPath } else { $null }
        reportSucceeded = if ($Result.ContainsKey('ReportSucceeded')) { [bool]$Result.ReportSucceeded } else { $null }
    }
}

function New-MediaNormalizerEventCallbacks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$EventSink,
        [Parameter(Mandatory)][scriptblock]$Logger,
        [scriptblock]$Progress,
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][pscustomobject]$FileContext
    )

    $sink = $EventSink
    $loggerBase = $Logger
    $logger = {
        param($message)
        $null = $loggerBase.Invoke($message)
        $text = [string]$message
        $level = if ($text -match '\[ERROR\]|\[FAIL\s*\]') { 'error' }
            elseif ($text -match '\[WARN\s*\]') { 'warning' }
            elseif ($text -match '\[DEBUG\]') { 'debug' }
            else { 'info' }
        $null = $sink.Invoke([pscustomobject]@{
            schemaVersion = 1; type = 'log'; runId = $RunId; level = $level; message = $text
        })
    }.GetNewClosure()

    $progressBase = $Progress
    $progressState = $State
    $progress = {
        param($current, $total)
        if ($progressBase) { $null = $progressBase.Invoke($current, $total) }
        $percent = [double]$progressState.PhaseProgressPercent
        if ($percent -lt 0) {
            $percent = if ([int]$total -gt 0) { ([double]$current / [double]$total) * 100.0 } else { 0.0 }
        }
        $eta = $null
        if ([double]$progressState.TotalDurationSec -gt 0) {
            $eta = [math]::Max(0.0, [double]$progressState.TotalDurationSec -
                [double]$progressState.ProcessedDurationSec - [double]$progressState.CurrentFileElapsedSec)
        }
        $phase = if ([string]::IsNullOrWhiteSpace([string]$progressState.CurrentPhase)) { 'overall' } else { [string]$progressState.CurrentPhase }
        $null = $sink.Invoke([pscustomobject]@{
            schemaVersion = 1; type = 'progress'; runId = $RunId
            percent = [math]::Max(0.0, [math]::Min(100.0, $percent)); phase = $phase
            eta = $eta; inputPath = $FileContext.InputPath
        })
    }.GetNewClosure()

    return @{ Logger = $logger; Progress = $progress; FileContext = $FileContext }
}

function Send-MediaNormalizerFileStartEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$EventSink,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][int]$Total
    )

    Send-MediaNormalizerStructuredEvent -EventSink $EventSink -Type file-start -Fields @{
        runId = $RunId; fileIndex = $Index; total = $Total; inputPath = $File.FullName
    }
}

function Send-MediaNormalizerFileDoneEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$EventSink,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InputPath,
        [AllowNull()][object]$OutputPath,
        [Parameter(Mandatory)][ValidateSet('normalized', 'analyzed', 'skipped', 'failed', 'cancelled')][string]$Status,
        [object]$Measurements,
        [AllowNull()][object]$Message
    )

    Send-MediaNormalizerStructuredEvent -EventSink $EventSink -Type file-done -Fields @{
        runId = $RunId; inputPath = $InputPath; outputPath = $OutputPath
        status = $Status; measurements = $Measurements; message = $Message
    }
}

function Send-MediaNormalizerFileErrorEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$EventSink,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$Message
    )

    Send-MediaNormalizerStructuredEvent -EventSink $EventSink -Type error -Fields @{
        runId = $RunId; code = 'FILE_PROCESSING_FAILED'; inputPath = $InputPath; message = $Message
    }
}

function Complete-MediaNormalizerRunEarly {
    [CmdletBinding()]
    param(
        [scriptblock]$EventSink,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][hashtable]$Result
    )

    $errorMessage = if ([int]$Result.Fail -gt 0) { 'Input validation, runtime preflight, or output setup failed.' } else { $null }
    Send-MediaNormalizerRunDoneEvent -EventSink $EventSink -RunId $RunId -Result $Result -ErrorMessage $errorMessage
    return $Result
}

function Invoke-Normalize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][ValidateSet('audio', 'video')][string]$Mode,
        [Parameter(Mandatory)][string]$InputDir,
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][double]$Target,
        [Parameter(Mandatory)][double]$TruePeak,
        [Parameter(Mandatory)][string]$Bitrate,
        [Parameter(Mandatory)][string]$SampleRate,
        [Parameter(Mandatory)][ValidateSet('rename', 'skip', 'overwrite')][string]$CollisionPolicy,
        [System.IO.FileInfo[]]$TargetFiles,
        [scriptblock]$Logger,
        [scriptblock]$Progress,
        [scriptblock]$GetTargetExtensions,
        [scriptblock]$PumpEvents,
        [int]$SpeedPercent = 100,
        [hashtable]$SpeedPercentByPath,
        [ValidateSet('mp3', 'm4a', 'aac', 'flac', 'wav', 'opus', 'ogg')]
        [string]$AudioOutputFormat = 'mp3',
        [switch]$AnalyzeOnly,
        [bool]$SkipIfNormalized = $true,
        [ValidateRange(0.0, 10.0)][double]$NormalizationTolerance = 0.5,
        [bool]$Recurse = $true,
        [bool]$PreserveHierarchy = $true,
        [string[]]$InputPaths,
        [string]$ReportPath,
        [ValidateSet('audio', 'video', 'both')][string]$ReportMode,
        [scriptblock]$Analyzer,
        [scriptblock]$EventSink,
        [string]$RunId = ([guid]::NewGuid().ToString('D')),
        [switch]$CliMode,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )

    if (-not $Logger) { $Logger = { param($m) Write-Host $m } }

    $activeFileContext = [pscustomobject]@{ InputPath = $null }
    if ($EventSink) {
        $callbacks = New-MediaNormalizerEventCallbacks -EventSink $EventSink -Logger $Logger `
            -Progress $Progress -State $State -RunId $RunId -FileContext $activeFileContext
        $Logger = $callbacks.Logger
        $Progress = $callbacks.Progress
        $activeFileContext = $callbacks.FileContext
        Send-MediaNormalizerStructuredEvent -EventSink $EventSink -Type run-start -Fields @{ runId = $RunId; mode = $Mode }
    }

    $loudnessRangeCheck = Test-LoudnessParameter -Target $Target -TruePeak $TruePeak
    if (-not $loudnessRangeCheck.IsValid) {
        foreach ($rangeError in $loudnessRangeCheck.Errors) {
            & $Logger "[ERROR] $rangeError"
        }
        return (Complete-MediaNormalizerRunEarly $EventSink $RunId @{ Success = 0; Fail = 1; Cancelled = 0; Skipped = 0 })
    }

    if ($Mode -eq 'audio') {
        & $Logger "=== 音声正規化モード（音声/動画 → $($AudioOutputFormat.ToUpperInvariant())）==="
    } else {
        & $Logger '=== 動画正規化モード（全トラック・字幕・チャプター・メタデータ保持）==='
    }
    & $Logger ''

    if ([string]::IsNullOrWhiteSpace($InputDir) -and
        (-not $InputPaths -or $InputPaths.Count -eq 0)) {
        & $Logger '[ERROR] 入力ファイル/フォルダパスが空です。'
        return (Complete-MediaNormalizerRunEarly $EventSink $RunId @{ Success = 0; Fail = 1; Cancelled = 0; Skipped = 0 })
    }
    if ((-not $InputPaths -or $InputPaths.Count -eq 0) -and
        -not (Test-Path -LiteralPath $InputDir)) {
        & $Logger "[ERROR] 入力ファイル/フォルダが見つかりません: $InputDir"
        return (Complete-MediaNormalizerRunEarly $EventSink $RunId @{ Success = 0; Fail = 1; Cancelled = 0; Skipped = 0 })
    }
    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        & $Logger '[ERROR] 出力フォルダパスが空です。'
        return (Complete-MediaNormalizerRunEarly $EventSink $RunId @{ Success = 0; Fail = 1; Cancelled = 0; Skipped = 0 })
    }

    $preflight = Get-MediaNormalizerRuntimePreflight -AnalyzeOnly:$AnalyzeOnly -Logger $Logger
    if (-not $preflight.Available) {
        return (Complete-MediaNormalizerRunEarly $EventSink $RunId @{ Success = 0; Fail = 1; Cancelled = 0; Skipped = 0 })
    }
    $ffnorm = $preflight.FfmpegNormalize

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        try {
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDir))
            & $Logger "[INFO ] 出力フォルダを作成しました: $OutputDir"
        } catch {
            & $Logger "[ERROR] 出力フォルダを作成できません: $OutputDir"
            & $Logger "        $($_.Exception.Message)"
            return (Complete-MediaNormalizerRunEarly $EventSink $RunId @{ Success = 0; Fail = 1; Cancelled = 0; Skipped = 0 })
        }
    }
    if ([string]::IsNullOrWhiteSpace($ReportPath)) {
        if ($State.ReportPath) {
            $ReportPath = $State.ReportPath
        } else {
            $ReportPath = Join-Path $OutputDir (
                'media-normalizer-report-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        }
    }
    $State.ReportPath = [IO.Path]::GetFullPath($ReportPath)

    $files = @(Get-NormalizationRunFiles `
            -State $State `
            -Mode $Mode `
            -InputDir $InputDir `
            -InputPaths $InputPaths `
            -TargetFiles $TargetFiles `
            -Recurse:$Recurse `
            -GetTargetExtensions $GetTargetExtensions)

    if ($files.Count -eq 0) {
        if ($Mode -eq 'audio') {
            & $Logger '[INFO ] 対象の音声/動画ファイルが見つかりません。'
        } else {
            & $Logger '[INFO ] 対象の動画ファイルが見つかりません。'
        }
        return (Complete-MediaNormalizerRunEarly $EventSink $RunId @{ Success = 0; Fail = 0; Cancelled = 0; Skipped = 0 })
    }

    & $Logger "[INFO ] 入力 : $InputDir"
    & $Logger "[INFO ] 出力 : $OutputDir"
    & $Logger "[INFO ] 対象ファイル: $($files.Count) 件"
    & $Logger "[INFO ] 再帰検索: $Recurse / 階層維持: $PreserveHierarchy"
    & $Logger "[INFO ] 解析のみ: $([bool]$AnalyzeOnly) / 正規化不要スキップ: $SkipIfNormalized (許容差 $NormalizationTolerance LU)"
    $defaultSpeedPercent = ConvertTo-SpeedPercent -Value $SpeedPercent
    if ($SpeedPercentByPath -and $SpeedPercentByPath.Count -gt 0) {
        & $Logger "[INFO ] 再生速度: ファイル別指定あり (50-200%)"
    } else {
        & $Logger "[INFO ] 再生速度: $defaultSpeedPercent%"
    }
    & $Logger "[INFO ] 処理開始... (policy=$CollisionPolicy)"
    & $Logger ''

    $ok = 0; $fail = 0; $cancelled = 0; $skipped = 0; $analyzed = 0
    $reportSucceeded = $true
    $reportError = $null
    $fileIndex = 0
    foreach ($f in $files) {
        $fileIndex++
        $activeFileContext.InputPath = $f.FullName
        if ($EventSink) { Send-MediaNormalizerFileStartEvent -EventSink $EventSink -RunId $RunId -File $f -Index $fileIndex -Total $files.Count }
        if (Test-MediaNormalizerCancellationRequested -State $State -CancellationToken $CancellationToken) {
            & $Logger "[CANCEL] $($f.Name) -- ユーザー要求によりスキップ"
            $cancelled++
            if ($EventSink) {
                Send-MediaNormalizerFileDoneEvent -EventSink $EventSink -RunId $RunId -InputPath $f.FullName `
                    -Status 'cancelled' -Message 'User cancellation requested before file processing.'
            }
            continue
        }

        & $Logger "[PROCESS] $($f.FullName)"
        $speedTemp = $null
        $workingOutPath = $null
        $record = New-NormalizationReportRecord `
            -File $f `
            -Mode $Mode `
            -AudioOutputFormat $AudioOutputFormat

        try {
            $currentSpeedPercent = Get-NormalizationCurrentSpeedPercent `
                -File $f `
                -DefaultSpeedPercent $defaultSpeedPercent `
                -SpeedPercentByPath $SpeedPercentByPath
            & $Logger "  [INFO ] 再生速度: $currentSpeedPercent%"

            $currentDur = Get-NormalizationCurrentDuration -State $State -File $f

            $inputInventory = $null
            if ($Mode -eq 'video' -and $currentSpeedPercent -ne 100) {
                $inputInventory = Get-MediaInventory -FilePath $f.FullName `
                    -State $State -Logger $Logger -Progress $Progress -PumpEvents $PumpEvents -CliMode:$CliMode `
                    -CancellationToken $CancellationToken
                $speedSafety = Test-VideoSpeedChangeSafety -Inventory $inputInventory
                if (-not $speedSafety.IsSafe) {
                    throw (
                        'HDR・10bit以上または広色域の映像は、色情報を保持できないため速度変更できません。' +
                        ' 速度100%で処理するか、対応する外部映像処理を使用してください。 ' +
                        ($speedSafety.Reasons -join '; '))
                }
                if ($inputInventory.StreamCounts.subtitle -gt 0 -or
                    $inputInventory.ChapterCount -gt 0) {
                    throw (
                        '字幕またはチャプターを含む動画は、時刻情報を正確に保持するため ' +
                        '再生速度100%で処理してください。')
                }
            }

            $beforeAnalysis = if ($Analyzer) {
                & $Analyzer $f.FullName $Target $TruePeak
            } else {
                Get-MediaLoudnessAnalysis -FilePath $f.FullName -Target $Target -TruePeak $TruePeak `
                    -State $State -Logger $Logger -Progress $Progress -PumpEvents $PumpEvents -CliMode:$CliMode `
                    -CancellationToken $CancellationToken `
                    -CurrentFileDurationSec $currentDur -PhaseLabel '解析中'
            }
            $record.before = $beforeAnalysis
            foreach ($stream in @($beforeAnalysis.Streams)) {
                & $Logger (
                    "  [ANALYZE] audio[$($stream.AudioStreamIndex)] " +
                    "$($stream.IntegratedLufs) LUFS / $($stream.TruePeakDbtp) dBTP")
            }

            if ($AnalyzeOnly) {
                $record.action = 'analyzed'
                $analyzed++
                & $Logger "[ANALYZED] $($f.Name)"
            } else {
                $audioProfile = if ($Mode -eq 'audio') {
                    Get-AudioOutputProfile `
                        -Format $AudioOutputFormat `
                        -Bitrate $Bitrate `
                        -SampleRate $SampleRate
                } else { $null }
                $outExt = if ($Mode -eq 'audio') { $audioProfile.Extension } else { $f.Extension.ToLowerInvariant() }
                $inputRoot = if (Test-Path -LiteralPath $InputDir -PathType Container) {
                    $InputDir
                } elseif (Test-Path -LiteralPath $InputDir -PathType Leaf) {
                    Split-Path -Parent $InputDir
                } else {
                    Split-Path -Parent $f.FullName
                }
                $fileOutputDir = Resolve-MediaOutputDirectory `
                    -InputRoot $inputRoot `
                    -InputFilePath $f.FullName `
                    -OutputRoot $OutputDir `
                    -PreserveHierarchy:$PreserveHierarchy
                if (-not (Test-Path -LiteralPath $fileOutputDir -PathType Container)) {
                    [void][IO.Directory]::CreateDirectory($fileOutputDir)
                }

                $baseName = [IO.Path]::GetFileNameWithoutExtension($f.Name)
                $expectedOutPath = Resolve-UniqueOutputPath `
                    -State $State `
                    -Directory $fileOutputDir `
                    -BaseName $baseName `
                    -Extension $outExt `
                    -Policy $CollisionPolicy `
                    -Logger $Logger
                $record.outputPath = $expectedOutPath

                if (-not $expectedOutPath) {
                    $record.action = 'skipped'
                    $record.reason = '既存出力ファイルとの衝突 (policy=skip)'
                    $skipped++
                    & $Logger "  [SKIP  ] $($record.reason)"
                } else {
                    $workingOutPath = New-SafeOutputPath -FinalPath $expectedOutPath -RunId $RunId
                    Register-NormalizationTemporaryOutputIfSupported $State $RunId $f.FullName $workingOutPath $expectedOutPath primary $PumpEvents
                    if (-not $inputInventory) {
                        $inputInventory = Get-MediaInventory -FilePath $f.FullName `
                            -State $State -Logger $Logger -Progress $Progress -PumpEvents $PumpEvents -CliMode:$CliMode `
                            -CancellationToken $CancellationToken
                    }
                    if ($Mode -eq 'audio' -and
                        $inputInventory.StreamCounts.audio -gt 1) {
                        & $Logger (
                            "  [WARN ] 入力に $($inputInventory.StreamCounts.audio) 個の音声トラックがあります。" +
                            "$($AudioOutputFormat.ToUpperInvariant()) 出力では形式やエンコーダーの制約により " +
                            'トラックが減る場合があります。処理後の検証結果をレポートへ記録します。')
                    }
                    $needResult = Test-NormalizationNeeded `
                        -Analysis $beforeAnalysis `
                        -Target $Target `
                        -TruePeak $TruePeak `
                        -Tolerance $NormalizationTolerance
                    $sameFormat = [string]::Equals(
                        $f.Extension,
                        $outExt,
                        [StringComparison]::OrdinalIgnoreCase)
                    $canCopyWithoutEncoding = (
                        $SkipIfNormalized -and
                        -not $needResult.Needed -and
                        $sameFormat -and
                        $currentSpeedPercent -eq 100)

                    if ($canCopyWithoutEncoding) {
                        Copy-Item -LiteralPath $f.FullName -Destination $workingOutPath
                        $record.action = 'skipped'
                        $record.reason = "目標値との差が $NormalizationTolerance LU 以内かつ True Peak 上限内"
                        & $Logger "  [SKIP  ] 正規化不要: $($record.reason)"
                    } else {
                        $sourcePath = $f.FullName
                        $intermediateProfile = $null

                        if ($currentSpeedPercent -ne 100) {
                            $intermediateProfile = Get-SpeedIntermediateProfile `
                                -Mode $Mode `
                                -InputExtension $f.Extension `
                                -Inventory $inputInventory
                            $record.speedIntermediateProfile = $intermediateProfile
                            & $Logger (
                                "  [INFO ] 中間形式: $($intermediateProfile.ProfileId) " +
                                "($($intermediateProfile.Codec)$($intermediateProfile.ContainerExtension)) " +
                                "- $($intermediateProfile.SelectionReason)")
                            if ($intermediateProfile.AncillaryFallback -eq 'DropWithWarning') {
                                & $Logger (
                                    '  [WARN ] 速度変更のため timecode / attachment 等の data ストリームを除外しました。' +
                                    ' 再生速度100%であれば保持できます。')
                            }
                            $speedTempExt = $intermediateProfile.ContainerExtension
                            $speedTemp = Join-Path ([IO.Path]::GetTempPath()) (
                                "media-normalizer-$RunId-speed-$([guid]::NewGuid().ToString('N'))$speedTempExt")
                            Register-NormalizationTemporaryOutputIfSupported $State $RunId $f.FullName $speedTemp $expectedOutPath speed $PumpEvents
                            $speedArgs = New-FfmpegSpeedArguments `
                                -Mode $Mode `
                                -InputPath $f.FullName `
                                -OutputPath $speedTemp `
                                -SpeedPercent $currentSpeedPercent `
                                -IntermediateProfile $intermediateProfile
                            & $Logger "  [CMD] ffmpeg $(ConvertTo-DisplayCommandArguments -Arguments $speedArgs)"
                            $speedResult = Invoke-MediaNormalizerProcess `
                                -FilePath (Resolve-MediaNormalizerExecutable -Name FFmpeg) `
                                -Arguments $speedArgs `
                                -State $State `
                                -PhaseLabel '速度変更中' `
                                -Logger $Logger `
                                -Progress $Progress `
                                -PumpEvents $PumpEvents `
                                -CliMode:$CliMode `
                                -CancellationToken $CancellationToken `
                                -CurrentFileDurationSec $currentDur `
                                -LongRunningMessage '速度変更前処理が長時間実行中です。' `
                                -TrackElapsedForEta $true `
                                -TrackPhaseProgress $true `
                                -ProgressSpeedFactor ([double]$currentSpeedPercent / 100.0) `
                                -ProgressScale 0.5 `
                                -WriteProgressFile
                            if ($speedResult.ExitCode -ne 0 -or
                                -not (Test-Path -LiteralPath $speedTemp -PathType Leaf)) {
                                throw "速度変更に失敗しました (exit=$($speedResult.ExitCode)): $($speedResult.StderrText)"
                            }
                            $sourcePath = $speedTemp
                        }

                        $ffArgs = New-FfmpegNormalizeArguments `
                            -Mode $Mode `
                            -InputPath $sourcePath `
                            -OutputPath $workingOutPath `
                            -Target $Target `
                            -TruePeak $TruePeak `
                            -Bitrate $Bitrate `
                            -SampleRate $SampleRate `
                            -AudioOutputFormat $AudioOutputFormat
                        $allArgs = @($ffnorm.Args) + $ffArgs
                        & $Logger "  [CMD] $($ffnorm.Cmd) $(ConvertTo-DisplayCommandArguments -Arguments $allArgs)"
                        $normalizeResult = Invoke-MediaNormalizerProcess `
                            -FilePath $ffnorm.Cmd `
                            -Arguments $allArgs `
                            -State $State `
                            -PhaseLabel '正規化中' `
                            -Logger $Logger `
                            -Progress $Progress `
                            -PumpEvents $PumpEvents `
                            -CliMode:$CliMode `
                            -CancellationToken $CancellationToken `
                            -CurrentFileDurationSec $currentDur `
                            -LongRunningMessage '正規化処理が長時間実行中です。' `
                            -TrackElapsedForEta $true `
                            -TrackPhaseProgress $true `
                            -ProgressSpeedFactor ([double]$currentSpeedPercent / 100.0)
                        $exitCode = $normalizeResult.ExitCode
                        foreach ($line in (($normalizeResult.StdoutText -replace "`r", "`n") -split "`n")) {
                            $clean = $line.Trim()
                            if ($clean) { & $Logger "  $clean" }
                        }
                        foreach ($line in (($normalizeResult.StderrText -replace "`r", "`n") -split "`n")) {
                            $clean = $line.Trim()
                            if ($clean -and -not ($clean -match '^(File:|Stream \d+/\d+:|Second Pass:)')) {
                                & $Logger "  $clean"
                            }
                        }
                        if ($exitCode -ne 0 -or
                            -not (Test-Path -LiteralPath $workingOutPath -PathType Leaf)) {
                            throw "正規化に失敗しました (exit=$exitCode)"
                        }
                        $record.action = 'normalized'
                    }

                    $outputInventory = Get-MediaInventory -FilePath $workingOutPath `
                        -State $State -Logger $Logger -Progress $Progress -PumpEvents $PumpEvents -CliMode:$CliMode `
                        -CancellationToken $CancellationToken
                    $integrity = Compare-MediaInventory `
                        -InputInventory $inputInventory `
                        -OutputInventory $outputInventory `
                        -Mode $Mode `
                        -AllowAncillaryStreamDrop:($Mode -eq 'video' -and $currentSpeedPercent -ne 100)
                    $record.validation = $integrity
                    $record.droppedAudioStreams = [int]$integrity.DroppedAudioStreams
                    foreach ($warning in @($integrity.Warnings)) {
                        & $Logger "  [WARN ] $warning"
                    }
                    if (-not $integrity.IsValid) {
                        throw "出力検証に失敗しました: $($integrity.Errors -join '; ')"
                    }
                    $record.after = if ($Analyzer) {
                        & $Analyzer $workingOutPath $Target $TruePeak
                    } else {
                        Get-MediaLoudnessAnalysis `
                            -FilePath $workingOutPath `
                            -Target $Target `
                            -TruePeak $TruePeak `
                            -State $State -Logger $Logger -Progress $Progress -PumpEvents $PumpEvents -CliMode:$CliMode `
                            -CancellationToken $CancellationToken `
                            -CurrentFileDurationSec $currentDur -PhaseLabel '検証解析中'
                    }
                    Complete-SafeOutput `
                        -TemporaryPath $workingOutPath `
                        -FinalPath $expectedOutPath
                    $workingOutPath = $null

                    if ($record.action -eq 'skipped') {
                        $skipped++
                        & $Logger "[SKIP OK] $($f.Name) → $expectedOutPath"
                    } else {
                        $ok++
                        & $Logger "[  OK  ] $($f.Name) → $expectedOutPath"
                    }
                }
            }
        } catch {
            $record.error = $_.Exception.Message
            if (Test-MediaNormalizerCancellationRequested -State $State -CancellationToken $CancellationToken) {
                $record.action = 'cancelled'
                & $Logger "[CANCEL] $($f.Name) -- 実行中にキャンセルされました"
                $cancelled++
            } else {
                $record.action = 'failed'
                & $Logger "[FAIL  ] $($f.Name) -- $($_.Exception.Message)"
                if ($EventSink) { Send-MediaNormalizerFileErrorEvent -EventSink $EventSink -RunId $RunId -InputPath $f.FullName -Message $_.Exception.Message }
                $fail++
            }
        } finally {
            foreach ($temporaryPath in @($speedTemp, $workingOutPath)) {
                if ($temporaryPath -and
                    -not (Remove-MediaNormalizerTemporaryFile -LiteralPath $temporaryPath)) {
                    & $Logger "  [WARN ] 一時ファイルを削除できませんでした: $temporaryPath"
                }
            }
            $State.RunningProcess = $null
            $record.completedAt = (Get-Date).ToString('o')
            $State.ReportRecords.Add([pscustomobject]$record)
        }

        if ($EventSink) {
            Send-MediaNormalizerFileDoneEvent -EventSink $EventSink -RunId $RunId -InputPath $f.FullName `
                -OutputPath $record.outputPath -Status $record.action `
                -Measurements @{ before = $record.before; after = $record.after } -Message $record.error
        }
        $activeFileContext.InputPath = $null
        $State.CurrentFileElapsedSec = 0.0
        if ($State.DurationMap.ContainsKey($f.FullName)) {
            $fileDur = $State.DurationMap[$f.FullName]
            if ($fileDur -and $fileDur -gt 0) {
                $State.ProcessedDurationSec += $fileDur
            }
        }
        $State.ProgressCurrent++
        if ($Progress) { & $Progress $State.ProgressCurrent $State.ProgressTotal }
        & $Logger ''
    }

    & $Logger '============================================'
    & $Logger "[SUMMARY] success=$ok  analyzed=$analyzed  fail=$fail  cancelled=$cancelled  skipped=$skipped"
    & $Logger "[INFO ] 出力フォルダ: $OutputDir"
    if ($fail -gt 0) { & $Logger "[WARN ] $fail 件のファイル処理に失敗しました。" }
    if ($cancelled -gt 0) { & $Logger "[INFO ] $cancelled 件のファイル処理がキャンセルされました。" }
    if ($skipped -gt 0) { & $Logger "[INFO ] $skipped 件のファイルが衝突回避または正規化不要判定でスキップされました。" }
    try {
        $reportModes = @($State.ReportRecords |
            ForEach-Object { $_.mode } |
            Select-Object -Unique)
        $reportMode = if (-not [string]::IsNullOrWhiteSpace($ReportMode)) {
            $ReportMode
        } elseif ($reportModes.Count -gt 1) {
            'both'
        } elseif ($reportModes.Count -eq 1) {
            [string]$reportModes[0]
        } else {
            $Mode
        }
        $writtenReport = Write-NormalizationReport `
            -Path $State.ReportPath `
            -Records $State.ReportRecords.ToArray() `
            -Configuration @{
                mode                   = $reportMode
                targetLufs             = $Target
                truePeakDbtp           = $TruePeak
                bitrate               = $Bitrate
                sampleRate            = $SampleRate
                audioOutputFormat      = $AudioOutputFormat
                analyzeOnly            = [bool]$AnalyzeOnly
                skipIfNormalized       = $SkipIfNormalized
                normalizationTolerance = $NormalizationTolerance
                recurse                = $Recurse
                preserveHierarchy      = $PreserveHierarchy
            }
        & $Logger "[REPORT] $writtenReport"
    } catch {
        $reportSucceeded = $false
        $reportError = $_.Exception.Message
        & $Logger "[WARN ] レポートの保存に失敗しました: $($_.Exception.Message)"
    }

    $finalResult = @{
        Success   = $ok
        Analyzed  = $analyzed
        Fail      = $fail
        Cancelled = $cancelled
        Skipped   = $skipped
        ReportPath = $State.ReportPath
        ReportSucceeded = $reportSucceeded
        ReportError = $reportError
    }
    Send-MediaNormalizerRunDoneEvent -EventSink $EventSink -RunId $RunId -Result $finalResult
    return $finalResult
}

function Invoke-NormalizeCli {
    [CmdletBinding()]
    param(
        [string]$InputDir,
        [string[]]$InputPath,
        [Parameter(Mandatory)][string]$OutputDir,
        [ValidateSet('audio', 'video', 'both')][string]$Mode = 'audio',
        [string]$Preset = 'デフォルト',
        [int]$SpeedPercent = 100,
        [ValidateSet('mp3', 'm4a', 'aac', 'flac', 'wav', 'opus', 'ogg')]
        [string]$AudioOutputFormat = 'mp3',
        [switch]$AnalyzeOnly,
        [bool]$SkipIfNormalized = $true,
        [ValidateRange(0.0, 10.0)][double]$NormalizationTolerance = 0.5,
        [bool]$Recurse = $true,
        [bool]$PreserveHierarchy = $true,
        [ValidateSet('rename', 'skip', 'overwrite')]
        [string]$CollisionPolicy = 'rename',
        [string]$ReportPath
    )

    $state = $null
    $handler = $null
    $cliExitCode = 2
    try {
        $presetsPath = Join-Path $PSScriptRoot '..\assets\presets.json'
        $target = -16.0; $tp = -1.0; $br = '192k'; $sr = '48000'
        if (-not (Test-Path -LiteralPath $presetsPath -PathType Leaf)) {
            throw "プリセット定義が見つかりません: $presetsPath"
        }
        try {
            $presetJson = Get-Content -LiteralPath $presetsPath -Raw -Encoding UTF8 |
                ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "プリセット定義を解析できません: $($_.Exception.Message)"
        }
        $selectedPreset = @($presetJson.presets | Where-Object { [string]$_.name -eq $Preset })
        if ($selectedPreset.Count -ne 1) {
            $validNames = @($presetJson.presets | ForEach-Object { [string]$_.name }) -join ', '
            throw "プリセット名が不正です: $Preset。選択可能: $validNames"
        }
        $target = [double]$selectedPreset[0].target
        $tp = [double]$selectedPreset[0].truePeak
        $br = [string]$selectedPreset[0].bitrate
        $sr = [string]$selectedPreset[0].sampleRate
        if (-not $PSBoundParameters.ContainsKey('AudioOutputFormat') -and
            $selectedPreset[0].PSObject.Properties['outputFormat']) {
            $AudioOutputFormat = [string]$selectedPreset[0].outputFormat
        }

        $rangeCheck = Test-LoudnessParameter -Target $target -TruePeak $tp
        if (-not $rangeCheck.IsValid) {
            throw "プリセット '$Preset' のパラメータが範囲外です: $($rangeCheck.Errors -join '; ')"
        }

        $state = New-MediaNormalizerState
        $handler = [ConsoleCancelEventHandler]{
            param($sender, $eventArgs)
            $eventArgs.Cancel = $true
            $state.CancelRequested = $true
        }
        [Console]::add_CancelKeyPress($handler)

        [string[]]$effectiveInputPaths = @(
            if ($InputPath -and $InputPath.Count -gt 0) {
                $InputPath
            } elseif (-not [string]::IsNullOrWhiteSpace($InputDir)) {
                $InputDir
            } else {
                throw '-InputPath または -InputDir を指定してください。'
            })
        foreach ($candidate in $effectiveInputPaths) {
            if (-not (Test-Path -LiteralPath $candidate)) {
                throw "入力パスが見つかりません: $candidate"
            }
        }
        if ([string]::IsNullOrWhiteSpace($InputDir)) {
            $InputDir = Get-MediaInputRoot -InputPath $effectiveInputPaths
        }

        $audioExts = Get-AudioInputExtensions
        $videoExts = Get-VideoInputExtensions
        $allFiles = Get-MediaInputFiles -InputPath $effectiveInputPaths -Recurse:$Recurse
        $files = @($allFiles | Where-Object {
            $_.Extension.ToLowerInvariant() -in @($audioExts + $videoExts)
        })
        $state.CachedFiles = $files
        $state.FileIndex = @{}
        foreach ($f in $files) {
            $state.FileIndex[$f.FullName] = $f
            $state.DurationMap[$f.FullName] = Get-MediaDuration -State $state -FilePath $f.FullName
        }

        $state.ProgressCurrent = 0
        $state.ProgressTotal = 0
        $state.TotalDurationSec = 0.0
        foreach ($d in $state.DurationMap.Values) { if ($d -gt 0) { $state.TotalDurationSec += $d } }
        $state.ProcessingStartTime = Get-Date

        $speedPercent = ConvertTo-SpeedPercent -Value $SpeedPercent

        $results = @()
        if ($Mode -in @('audio', 'both')) {
            $audioFiles = @($files | Where-Object { $_.Extension.ToLower() -in $audioExts })
            $state.ProgressTotal += $audioFiles.Count
            $results += Invoke-Normalize `
                -State $state `
                -Mode audio `
                -InputDir $InputDir `
                -InputPaths $effectiveInputPaths `
                -OutputDir $OutputDir `
                -Target $target `
                -TruePeak $tp `
                -Bitrate $br `
                -SampleRate $sr `
                -CollisionPolicy $CollisionPolicy `
                -TargetFiles $audioFiles `
                -Logger { param($m) Write-Host $m } `
                -SpeedPercent $speedPercent `
                -AudioOutputFormat $AudioOutputFormat `
                -AnalyzeOnly:$AnalyzeOnly `
                -SkipIfNormalized:$SkipIfNormalized `
                -NormalizationTolerance $NormalizationTolerance `
                -Recurse:$Recurse `
                -PreserveHierarchy:$PreserveHierarchy `
                -ReportPath $ReportPath `
                -ReportMode $Mode `
                -CliMode
        }
        if ($Mode -in @('video', 'both') -and -not ($AnalyzeOnly -and $Mode -eq 'both')) {
            $videoFiles = @($files | Where-Object { $_.Extension.ToLower() -in $videoExts })
            $state.ProgressTotal += $videoFiles.Count
            $results += Invoke-Normalize `
                -State $state `
                -Mode video `
                -InputDir $InputDir `
                -InputPaths $effectiveInputPaths `
                -OutputDir $OutputDir `
                -Target $target `
                -TruePeak $tp `
                -Bitrate $br `
                -SampleRate $sr `
                -CollisionPolicy $CollisionPolicy `
                -TargetFiles $videoFiles `
                -Logger { param($m) Write-Host $m } `
                -SpeedPercent $speedPercent `
                -AnalyzeOnly:$AnalyzeOnly `
                -SkipIfNormalized:$SkipIfNormalized `
                -NormalizationTolerance $NormalizationTolerance `
                -Recurse:$Recurse `
                -PreserveHierarchy:$PreserveHierarchy `
                -ReportPath $ReportPath `
                -ReportMode $Mode `
                -CliMode
        }

        $hasFail = $false
        $hasCancel = $false
        foreach ($r in $results) {
            if ($r.Fail -gt 0) { $hasFail = $true }
            if ($r.Cancelled -gt 0) { $hasCancel = $true }
            if ($r -is [hashtable] -and $r.ContainsKey('ReportSucceeded') -and $r.ReportSucceeded -eq $false) {
                $hasFail = $true
            }
        }

        if ($hasFail) { $cliExitCode = 1 }
        elseif ($hasCancel) { $cliExitCode = 1 }
        else { $cliExitCode = 0 }
    } catch {
        Write-Error $_
        $cliExitCode = if ([string]$_.Exception.Message -match '\[RECOVERY_REQUIRED\]') { 4 } else { 2 }
    } finally {
        if ($handler) {
            [Console]::remove_CancelKeyPress($handler)
        }
        if ($state -and $state.RunningProcess -and -not $state.RunningProcess.HasExited) {
            if ((Get-MediaNormalizerPlatform) -eq 'Windows') {
                & taskkill.exe /T /F /PID $state.RunningProcess.Id 2>&1 | Out-Null
            } else {
                $stopResult = Stop-MediaNormalizerProcessTree -RootProcessId $state.RunningProcess.Id -GracePeriodSeconds 5
                if (-not $stopResult.Stopped) {
                    Write-Error "[RECOVERY_REQUIRED] 外部process treeを停止できません: $($stopResult.RemainingProcessIds -join ',')"
                    $cliExitCode = 4
                }
            }
        }
        if ($state) {
            $state.ReservedOutPaths.Clear()
        }
    }
    $global:LASTEXITCODE = $cliExitCode
}

Export-ModuleMember -Function New-MediaNormalizerState, Find-FfmpegNormalize, Resolve-UniqueOutputPath, Invoke-Normalize, Invoke-NormalizeCli, Get-AudioInputExtensions, Get-VideoInputExtensions, Get-AudioOutputFormats, Get-AudioOutputProfile, Get-MediaInputFiles, Get-MediaInputRoot, Get-RelativeMediaPath, Resolve-MediaOutputDirectory, New-SafeOutputPath, Get-MediaInventory, Compare-MediaInventory, Complete-SafeOutput, Get-MediaLoudnessAnalysis, Test-NormalizationNeeded, Write-NormalizationReport, ConvertTo-SpeedPercent, Get-LoudnessParameterRange, Test-LoudnessParameter, Get-SpeedIntermediateProfile, Test-VideoSpeedChangeSafety
