Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MediaNormalizer.Platform.psm1') -Scope Local -DisableNameChecking
$script:SettingsSchemaVersion = 2

function Get-LegacyAutoInputDir {
    $base = [Environment]::GetFolderPath('MyVideos')
    if ([string]::IsNullOrEmpty($base)) {
        throw 'MediaNormalizer.Ui の旧自動入力ディレクトリは Windows でのみ解決できます。'
    }
    Join-Path $base 'pre-normalization data'
}

function Get-LegacyAutoOutputDir {
    $base = [Environment]::GetFolderPath('MyVideos')
    if ([string]::IsNullOrEmpty($base)) {
        throw 'MediaNormalizer.Ui の旧自動出力ディレクトリは Windows でのみ解決できます。'
    }
    Join-Path $base 'normalization data'
}

function Get-SettingsPath {
    Get-MediaNormalizerStoragePath -Kind Settings
}

function Get-LogPath {
    Get-MediaNormalizerStoragePath -Kind Log
}

function Split-ProbePathBatch {
    param(
        [Parameter(Mandatory)][string[]]$FilePath,
        [ValidateRange(1, 1000)][int]$BatchSize = 25
    )

    for ($start = 0; $start -lt $FilePath.Count; $start += $BatchSize) {
        $end = [math]::Min($start + $BatchSize - 1, $FilePath.Count - 1)
        Write-Output -NoEnumerate ([string[]]@($FilePath[$start..$end]))
    }
}

function Initialize-ThreadJob {
    param([Parameter(Mandatory)][pscustomobject]$State)
    # PS 7.4+ は Microsoft.PowerShell.ThreadJob として本体同梱、
    # PS 5.1 / 旧 7.x は PSGallery 配布の ThreadJob を使う
    $candidates = @('Microsoft.PowerShell.ThreadJob', 'ThreadJob')
    foreach ($name in $candidates) {
        if (Get-Module -ListAvailable -Name $name) {
            try {
                Import-Module $name -ErrorAction Stop
                $State.ThreadJobSetupWarning = $null
                return $true
            } catch {
                $State.ThreadJobSetupWarning = "[WARN ] $name モジュールの読み込みに失敗: $($_.Exception.Message). 同期モードで動作します"
                return $false
            }
        }
    }
    # 自動 Install-Module は NuGet provider 同意プロンプトでハングし得るため行わない。
    $State.ThreadJobSetupWarning = "[WARN ] ThreadJob モジュール未導入のため同期モードで動作します (手動導入: Install-Module ThreadJob -Scope CurrentUser)"
    return $false
}

function Read-Settings {
    [CmdletBinding()]
    param(
        [string]$SettingsPath,
        [hashtable]$Defaults,
        [hashtable]$LegacyAutoDefaults
    )
    # フォーム生成前に呼ばれる可能性があるため Write-Log は使わず Warnings に蓄積
    if ($PSBoundParameters.ContainsKey('SettingsPath')) {
        $path = $SettingsPath
    } else {
        $path = Get-SettingsPath
    }
    $warnings = New-Object System.Collections.Generic.List[string]
    $extensionFields = [ordered]@{}
    if ($PSBoundParameters.ContainsKey('Defaults') -and $Defaults) {
        $values = @{
            InputDir   = if ($Defaults.ContainsKey('InputDir'))   { $Defaults.InputDir }   else { $null }
            OutputDir  = if ($Defaults.ContainsKey('OutputDir'))  { $Defaults.OutputDir }  else { $null }
            LastPreset = if ($Defaults.ContainsKey('LastPreset')) { $Defaults.LastPreset } else { 'デフォルト' }
            LastMode   = if ($Defaults.ContainsKey('LastMode'))   { $Defaults.LastMode }   else { 'audio' }
        }
    } else {
        $values = @{
            InputDir   = ''
            OutputDir  = ''
            LastPreset = 'デフォルト'
            LastMode   = 'audio'
        }
    }

    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ Values = $values; ExtensionFields = $extensionFields; Warnings = $warnings.ToArray() }
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $warnings.Add("[WARN ] settings.json の解析に失敗しました。既定値で起動します: $($_.Exception.Message)")
        return [pscustomobject]@{ Values = $values; ExtensionFields = $extensionFields; Warnings = $warnings.ToArray() }
    }

    $propNames = @($json.PSObject.Properties.Name)
    if ($propNames -notcontains 'version') {
        $warnings.Add('[WARN ] settings.json に version が無いため既定値で起動します')
        return [pscustomobject]@{ Values = $values; ExtensionFields = $extensionFields; Warnings = $warnings.ToArray() }
    }
    $verNum = 0
    if (-not [int]::TryParse([string]$json.version, [ref]$verNum)) {
        $warnings.Add("[WARN ] settings.json の version が不正です。既定値で起動します")
        return [pscustomobject]@{ Values = $values; ExtensionFields = $extensionFields; Warnings = $warnings.ToArray() }
    }
    if ($verNum -gt $script:SettingsSchemaVersion) {
        $warnings.Add("[WARN ] settings.json の version=$verNum は未知のため既定値で起動します")
        return [pscustomobject]@{ Values = $values; ExtensionFields = $extensionFields; Warnings = $warnings.ToArray() }
    }

    # Keep additive fields from schema-compatible settings files so an older frontend
    # can update known values without erasing fields written by another frontend/version.
    $knownPropertyNames = @('version', 'inputDir', 'outputDir', 'lastPreset', 'lastMode')
    foreach ($property in $json.PSObject.Properties) {
        if ($knownPropertyNames -notcontains $property.Name) {
            $extensionFields[$property.Name] = $property.Value
        }
    }

    $inputDir = if ($propNames -contains 'inputDir' -and $json.inputDir) {
        [string]$json.inputDir
    } else {
        $null
    }
    $outputDir = if ($propNames -contains 'outputDir' -and $json.outputDir) {
        [string]$json.outputDir
    } else {
        $null
    }

    # v1 は、ユーザーが何も選んでいなくても旧既定フォルダを終了時に保存していた。
    # 実アプリの v1 読み込み時だけその既知の値を未指定へ移行する。v2 では同じ
    # フォルダをユーザーが明示選択した可能性を尊重し、通常どおり復元する。
    if ($verNum -lt 2) {
        $legacyDefaults = if ($PSBoundParameters.ContainsKey('LegacyAutoDefaults') -and $LegacyAutoDefaults) {
            $LegacyAutoDefaults
        } elseif (-not $PSBoundParameters.ContainsKey('SettingsPath')) {
            @{
                InputDir  = Get-LegacyAutoInputDir
                OutputDir = Get-LegacyAutoOutputDir
            }
        } else {
            $null
        }
        if ($legacyDefaults) {
            if ($legacyDefaults.ContainsKey('InputDir') -and
                [string]::Equals($inputDir, [string]$legacyDefaults.InputDir, [StringComparison]::OrdinalIgnoreCase)) {
                $inputDir = $null
            }
            if ($legacyDefaults.ContainsKey('OutputDir') -and
                [string]::Equals($outputDir, [string]$legacyDefaults.OutputDir, [StringComparison]::OrdinalIgnoreCase)) {
                $outputDir = $null
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($inputDir))  { $values.InputDir  = $inputDir }
    if (-not [string]::IsNullOrWhiteSpace($outputDir)) { $values.OutputDir = $outputDir }
    if ($propNames -contains 'lastPreset' -and $json.lastPreset) { $values.LastPreset = [string]$json.lastPreset }
    if ($propNames -contains 'lastMode'   -and $json.lastMode) {
        $candidate = [string]$json.lastMode
        if ($candidate -in @('audio','video','both')) { $values.LastMode = $candidate }
    }

    return [pscustomobject]@{ Values = $values; ExtensionFields = $extensionFields; Warnings = $warnings.ToArray() }
}

function Save-Settings {
    param(
        [string]$InputDir,
        [string]$OutputDir,
        [string]$LastPreset,
        [string]$LastMode,
        [System.Collections.IDictionary]$ExtensionFields,
        [pscustomobject]$State,
        [string]$SettingsPath
    )
    if ($PSBoundParameters.ContainsKey('SettingsPath')) {
        $path = $SettingsPath
    } else {
        $path = Get-SettingsPath
    }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        # New-Item -ItemType Directory は -LiteralPath をサポートしないため -Path を使う
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        catch {
            if ($State) {
                Write-Log -State $State -Message "[WARN ] settings.json 保存ディレクトリ作成失敗: $($_.Exception.Message)"
                try { Write-LogBuffer -State $State } catch { }
            }
            return
        }
    }
    $payload = [ordered]@{
        version    = $script:SettingsSchemaVersion
        inputDir   = $InputDir
        outputDir  = $OutputDir
        lastPreset = $LastPreset
        lastMode   = $LastMode
    }
    if ($ExtensionFields) {
        $knownPropertyNames = @('version', 'inputDir', 'outputDir', 'lastPreset', 'lastMode')
        foreach ($field in $ExtensionFields.GetEnumerator()) {
            $fieldName = [string]$field.Key
            if (-not [string]::IsNullOrWhiteSpace($fieldName) -and $knownPropertyNames -notcontains $fieldName) {
                $payload[$fieldName] = $field.Value
            }
        }
    }
    try {
        $payload | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $path -Encoding UTF8
    } catch {
        if ($State) {
            Write-Log -State $State -Message "[WARN ] settings.json 保存失敗: $($_.Exception.Message)"
            try { Write-LogBuffer -State $State } catch { }
        }
    }
}

function ConvertTo-PresetMap {
    param(
        [object[]]$PresetList,
        # 省略可能。渡された場合のみ、除外したプリセットの理由を追記する（既存要素は消去しない）。
        [ref]$Warnings
    )
    $map = @{}
    foreach ($p in $PresetList) {
        if (-not $p) { continue }
        $name = ([string]$p.name).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $target = 0.0
        $truePeak = 0.0
        $targetOk = [double]::TryParse(
            [string]$p.target,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$target)
        $truePeakOk = [double]::TryParse(
            [string]$p.truePeak,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$truePeak)
        if (-not $targetOk -or -not $truePeakOk) {
            if ($null -ne $Warnings -and $null -ne $Warnings.Value) {
                $Warnings.Value.Add("プリセット '$name' の target/truePeak を数値として解釈できないため除外しました。")
            }
            continue
        }

        $rangeCheck = MediaNormalizer.Core\Test-LoudnessParameter -Target $target -TruePeak $truePeak
        if (-not $rangeCheck.IsValid) {
            if ($null -ne $Warnings -and $null -ne $Warnings.Value) {
                $Warnings.Value.Add("プリセット '$name' は範囲外のため除外しました: $($rangeCheck.Errors -join '; ')")
            }
            continue
        }

        $map[$name] = @{
            Target     = $target
            TruePeak   = $truePeak
            Bitrate    = [string]$p.bitrate
            SampleRate = [string]$p.sampleRate
            OutputFormat = if ($p.PSObject.Properties['outputFormat']) { [string]$p.outputFormat } else { 'mp3' }
            Purpose      = if ($p.PSObject.Properties['purpose']) { [string]$p.purpose } else { 'ユーザー定義プリセット' }
            Basis        = if ($p.PSObject.Properties['basis']) { [string]$p.basis } else { '根拠情報なし' }
            Warning      = if ($p.PSObject.Properties['warning']) { [string]$p.warning } else { '出力先の仕様を確認してください。' }
        }
    }
    return $map
}

function Join-Presets {
    param(
        [object[]]$BasePresets,
        [object[]]$UserPresets
    )
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($p in $BasePresets) { [void]$result.Add($p) }

    $indexMap = @{}
    for ($i = 0; $i -lt $result.Count; $i++) {
        $name = ([string]$result[$i].name).Trim().ToLowerInvariant()
        if (-not $indexMap.ContainsKey($name)) { $indexMap[$name] = $i }
    }
    foreach ($up in $UserPresets) {
        $name = ([string]$up.name).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($indexMap.ContainsKey($name)) {
            $idx = $indexMap[$name]
            $result[$idx] = $up
        } else {
            [void]$result.Add($up)
            $indexMap[$name] = $result.Count - 1
        }
    }
    return ,$result.ToArray()
}

function Import-Presets {
    param(
        # 省略可能。渡された場合のみ、除外理由・フォールバック理由を追記する（既存要素は消去しない）。
        [ref]$Warnings
    )
    $default = @(
        [pscustomobject]@{ name = 'デフォルト'; target = -16.0; truePeak = -1.0; bitrate = '192k'; sampleRate = 48000; outputFormat = 'mp3'; purpose = '会話中心の一般コンテンツ向け'; basis = '運用上の初期値'; warning = '納品先仕様を優先してください。' },
        [pscustomobject]@{ name = '放送（EBU R 128）'; target = -23.0; truePeak = -2.0; bitrate = '256k'; sampleRate = 48000; outputFormat = 'm4a'; purpose = 'EBU R 128採用ワークフロー向け'; basis = 'EBU R 128: -23 LUFS'; warning = '局別納品仕様を確認してください。' },
        [pscustomobject]@{ name = '動画配信（-14 LUFS目安）'; target = -14.0; truePeak = -1.0; bitrate = '192k'; sampleRate = 48000; outputFormat = 'm4a'; purpose = '一般的な動画配信向け'; basis = '実務上の目安（公式納品規格ではありません）'; warning = '配信先の最新仕様を確認してください。' },
        [pscustomobject]@{ name = 'ポッドキャスト'; target = -16.0; truePeak = -1.0; bitrate = '128k'; sampleRate = 44100; outputFormat = 'mp3'; purpose = '会話・ポッドキャスト向け'; basis = '広く使われる運用目安'; warning = '配信先仕様を確認してください。' }
    )
    $basePath = Join-Path (Join-Path $PSScriptRoot '..') 'assets/presets.json'
    $userPath = Get-MediaNormalizerStoragePath -Kind UserPresets
    try {
        if (Test-Path -LiteralPath $basePath) {
            $baseJson = Get-Content -LiteralPath $basePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($baseJson.presets) { $default = @($baseJson.presets) }
        }
    } catch { }
    $user = @()
    try {
        if (Test-Path -LiteralPath $userPath) {
            $userJson = Get-Content -LiteralPath $userPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($userJson.presets) { $user = @($userJson.presets) }
        }
    } catch { }

    $merged = Join-Presets -BasePresets $default -UserPresets $user
    # [ref] パラメータへ $null をそのまま渡すと型変換エラーになるため、
    # 未指定時は -Warnings 自体を渡さず ConvertTo-PresetMap の既定(警告を捨てる)に委ねる。
    $map = if ($null -ne $Warnings) {
        ConvertTo-PresetMap -PresetList $merged -Warnings $Warnings
    } else {
        ConvertTo-PresetMap -PresetList $merged
    }
    if ($map.Count -eq 0) {
        if ($null -ne $Warnings -and $null -ne $Warnings.Value) {
            $Warnings.Value.Add('有効なプリセットが1件もないため、組み込み既定プリセットへフォールバックしました。')
        }
        $map = @{
            'デフォルト' = @{ Target = -16; TruePeak = -1.0; Bitrate = '192k'; SampleRate = '48000'; OutputFormat = 'mp3'; Purpose = '一般向け'; Basis = '運用上の初期値'; Warning = '納品先仕様を優先してください。' }
        }
    }
    return $map
}

function Get-PresetRationaleText {
    param([hashtable]$Preset)
    if (-not $Preset) { return 'プリセットの根拠情報を取得できません。' }
    return "$($Preset.Purpose) / 根拠: $($Preset.Basis) / 注意: $($Preset.Warning)"
}

function Test-PresetConfigurationMatches {
    param(
        [Parameter(Mandatory)][hashtable]$Preset,
        [double]$Target,
        [double]$TruePeak,
        [string]$Bitrate,
        [string]$SampleRate,
        [string]$OutputFormat
    )
    return (
        [math]::Abs([double]$Preset.Target - $Target) -lt 0.001 -and
        [math]::Abs([double]$Preset.TruePeak - $TruePeak) -lt 0.001 -and
        [string]$Preset.Bitrate -eq $Bitrate -and
        [string]$Preset.SampleRate -eq $SampleRate -and
        [string]$Preset.OutputFormat -eq $OutputFormat
    )
}

function Write-Log {
    param([Parameter(Mandatory)][pscustomobject]$State, [string]$Message)
    [void]$State.LogBuffer.AppendLine($Message)
}

function Write-LogBuffer {
    param([Parameter(Mandatory)][pscustomobject]$State)
    if (-not $State.LogBuffer -or $State.LogBuffer.Length -eq 0) { return }
    $txt = $State.Controls.TxtLog
    $hasLogPath = $State.PSObject.Properties['LogPath'] -and
        -not [string]::IsNullOrWhiteSpace([string]$State.LogPath)
    if (-not $txt -and -not $hasLogPath) { return }

    $content = $State.LogBuffer.ToString()
    [void]$State.LogBuffer.Clear()
    if ($txt) {
        $txt.AppendText($content)
        $txt.SelectionStart = $txt.TextLength
        $txt.ScrollToCaret()
    }
    if ($hasLogPath) {
        try {
            $logDirectory = Split-Path -Parent $State.LogPath
            if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($logDirectory)
            }
            if ((Test-Path -LiteralPath $State.LogPath -PathType Leaf) -and
                (Get-Item -LiteralPath $State.LogPath).Length -ge 5MB) {
                $archivePath = "$($State.LogPath).1"
                if (Test-Path -LiteralPath $archivePath) {
                    Remove-Item -LiteralPath $archivePath -Force
                }
                Move-Item -LiteralPath $State.LogPath -Destination $archivePath
            }
            Add-Content -LiteralPath $State.LogPath -Value $content -Encoding UTF8
        } catch {
            if (-not $State.LogPersistenceWarningIssued) {
                $State.LogPersistenceWarningIssued = $true
                if ($txt) {
                    $txt.AppendText("[WARN ] GUIログをファイルへ保存できません: $($_.Exception.Message)`r`n")
                }
            }
        }
    }
}

function Start-LogTimer {
    param([Parameter(Mandatory)][pscustomobject]$State)
    if ($State.LogTimer) { return }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $stateRef = $State
    [scriptblock]$writeLogBufferFn = ${function:Write-LogBuffer}
    [scriptblock]$receiveOperationEventsFn = ${function:Receive-UiOperationEvents}
    $timer.Add_Tick({
        if ($stateRef.OperationState -ne 'Idle') {
            & $receiveOperationEventsFn -State $stateRef
        }
        & $writeLogBufferFn -State $stateRef
    }.GetNewClosure())
    $State.LogTimer = $timer
    $timer.Start()
}

function Write-ProcessOutputLog {
    param([Parameter(Mandatory)][pscustomobject]$State, [string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $ansi = [regex]::Escape([string][char]27) + '\[[0-9;?]*[ -/]*[@-~]'
    $normalized = ($Text -replace "`r", "`n")
    $lines = $normalized -split "`n"
    foreach ($line in $lines) {
        $clean = ($line -replace $ansi, '').Trim()
        if ([string]::IsNullOrWhiteSpace($clean)) { continue }
        if ($clean -match '^(File:|Stream \d+/\d+:|Second Pass:)') { continue }
        Write-Log -State $State -Message "  $clean"
    }
}

function Update-Progress {
    param([Parameter(Mandatory)][pscustomobject]$State, [int]$Current, [int]$Total)
    if ($Total -le 0) { return }
    $bg = $State.Controls.PnlProgressBg
    $fill = $State.Controls.PnlProgressFill
    $lbl = $State.Controls.LblProgress
    $pct = [math]::Min(100, [math]::Floor($Current * 100 / $Total))
    $fill.Width = [math]::Floor($bg.Width * $pct / 100)

    $base = "$Current / $Total 完了 ($pct%)"

    if ($Current -ge $Total) {
        if ($State.ProcessingStartTime) {
            $elapsed = (Get-Date) - $State.ProcessingStartTime
            $elapsedStr = MediaNormalizer.Probe\Format-Duration -Seconds $elapsed.TotalSeconds
            $text = "$base | 完了 (所要時間 $elapsedStr)"
        } else {
            $text = $base
        }
    } elseif ($State.ProcessingStartTime) {
        $elapsed = (Get-Date) - $State.ProcessingStartTime
        $remainPart = '計算中...'
        if ($elapsed.TotalSeconds -ge 3) {
            $effectiveProcessed = $State.ProcessedDurationSec + $State.CurrentFileElapsedSec
            if ($State.TotalDurationSec -gt 0 -and $effectiveProcessed -gt 0) {
                $speed = $effectiveProcessed / $elapsed.TotalSeconds
                $remainDur = $State.TotalDurationSec - $effectiveProcessed
                if ($speed -gt 0) {
                    $etaSec = [math]::Max(0, $remainDur / $speed)
                    $remainPart = "残り $(MediaNormalizer.Probe\Format-Duration -Seconds $etaSec)"
                }
            } elseif ($Current -gt 0) {
                $etaSec = [math]::Max(0, $elapsed.TotalSeconds / $Current * ($Total - $Current))
                $remainPart = "残り $(MediaNormalizer.Probe\Format-Duration -Seconds $etaSec)"
            }
        }
        $text = "$base | $remainPart"
    } else {
        $text = $base
    }

    # 解析・検証解析中は runner が State.CurrentPhase / PhaseProgressPercent を更新する。
    # PhaseProgressPercent が負値の間はフェーズ名のみ表示し、パーセントは出さない。
    $currentPhase = if ($State.PSObject.Properties['CurrentPhase']) { $State.CurrentPhase } else { $null }
    if ($currentPhase) {
        $phasePercent = if ($State.PSObject.Properties['PhaseProgressPercent']) { $State.PhaseProgressPercent } else { -1.0 }
        $phasePart = if ($phasePercent -ge 0) {
            "$currentPhase $([math]::Floor($phasePercent))%"
        } else {
            $currentPhase
        }
        $text = "$text | $phasePart"
    }

    $lbl.Text = $text
}

function Reset-Progress {
    param([Parameter(Mandatory)][pscustomobject]$State)
    $State.Controls.PnlProgressFill.Width = 0
    $State.Controls.LblProgress.Text = ''
    $State.ProcessedDurationSec = 0.0
    $State.TotalDurationSec = 0.0
    $State.ProcessingStartTime = $null
    $State.CurrentFileElapsedSec = 0.0
}

function Get-BuildProvenance {
    $packageRoot = Split-Path -Parent $PSScriptRoot
    $path = Join-Path $packageRoot 'build-provenance.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $provenance = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
        if ([int]$provenance.SchemaVersion -ne 1 -or
            [string]::IsNullOrWhiteSpace([string]$provenance.Runtime) -or
            [string]::IsNullOrWhiteSpace([string]$provenance.BuildId)) { return $null }
        return $provenance
    } catch { return $null }
}

function Get-TargetExtensions {
    param([Parameter(Mandatory)][pscustomobject]$State)
    $result = @{ Audio = @(); Video = @() }
    if ($State.Controls.ChkAudio.Checked) {
        $result.Audio = MediaNormalizer.Core\Get-AudioInputExtensions
    }
    if ($State.Controls.ChkVideo.Checked) {
        $result.Video = MediaNormalizer.Core\Get-VideoInputExtensions
    }
    return $result
}

function Initialize-FileGridSelectionState {
    param([Parameter(Mandatory)][pscustomobject]$State)

    $defaults = @{
        FileRowState               = @{}
        InputScopeKey              = $null
        FileGridUpdateDepth        = 0
        FileGridModeRefreshPending = $false
        InputSelectionPaths        = @()
    }
    foreach ($entry in $defaults.GetEnumerator()) {
        $property = $State.PSObject.Properties[[string]$entry.Key]
        if ($null -eq $property) {
            Add-Member -InputObject $State -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
        } elseif ($null -eq $property.Value -and $entry.Key -ne 'InputScopeKey') {
            $property.Value = $entry.Value
        }
    }
    return $State
}

function Set-UiOperationState {
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][ValidateSet('Idle', 'Starting', 'Running', 'Cancelling', 'Finalizing')][string]$OperationState
    )

    $previous = if ($State.PSObject.Properties['OperationState']) { [string]$State.OperationState } else { 'Idle' }
    $allowed = @{
        Idle       = @('Starting')
        Starting   = @('Running', 'Finalizing')
        Running    = @('Cancelling', 'Finalizing')
        Cancelling = @('Finalizing')
        Finalizing = @('Idle')
    }
    if ($previous -ne $OperationState -and
        (-not $allowed.ContainsKey($previous) -or -not $allowed[$previous].Contains($OperationState))) {
        throw "不正なoperation state遷移です: $previous -> $OperationState"
    }
    $State.OperationState = $OperationState
    if ($State.Controls -and $State.Controls.ContainsKey('LblOperationStatus')) {
        $State.Controls.LblOperationStatus.Text = switch ($OperationState) {
            'Idle' { '待機中' }
            'Starting' { '開始準備中...' }
            'Running' { '実行中（対象を固定しています。キャンセル完了後に変更できます）' }
            'Cancelling' { 'キャンセル処理中...' }
            'Finalizing' { '結果を確定中...' }
        }
    }
    if ($State.Controls -and $State.Controls.ContainsKey('BtnRun')) {
        Set-UIEnabled -State $State -Enabled:($OperationState -eq 'Idle')
    }
}

function Write-UiOperationLog {
    param([Parameter(Mandatory)][pscustomobject]$State, [Parameter(Mandatory)][string]$Message)
    $operationId = if ($State.PSObject.Properties['OperationId'] -and $State.OperationId) {
        [string]$State.OperationId
    } else { '-' }
    Write-Log -State $State -Message ('[{0}] [op:{1}] {2}' -f (Get-Date -Format 'o'), $operationId, $Message)
}

function Dispose-UiWorker {
    param([Parameter(Mandatory)][pscustomobject]$Worker)
    if ($Worker.PowerShell) {
        try { $Worker.PowerShell.Dispose() } catch { }
    }
    if ($Worker.Runspace) {
        try { $Worker.Runspace.Close() } catch { }
        try { $Worker.Runspace.Dispose() } catch { }
    }
}

function Test-UiActiveChildProcess {
    param([Parameter(Mandatory)][pscustomobject]$State)
    if (-not $State.PSObject.Properties['ActiveChildPid'] -or
        -not $State.ActiveChildPid) {
        return $false
    }
    try {
        $process = Get-Process -Id ([int]$State.ActiveChildPid) -ErrorAction Stop
        return -not $process.HasExited
    } catch {
        return $false
    }
}

function Complete-UiOperation {
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][string]$OperationId,
        [ValidateSet('Succeeded', 'Failed', 'Cancelled', 'Orphaned')][string]$Reason = 'Failed',
        [string]$Detail
    )

    if ([string]$State.OperationId -ne $OperationId -or
        [bool]$State.CompletionHandled -or [bool]$State.FinalizationStarted) {
        return $false
    }
    $State.FinalizationStarted = $true
    try { Set-UiOperationState -State $State -OperationState 'Finalizing' } catch { $State.OperationState = 'Finalizing' }
    $State.LastCompletionReason = $Reason
    try { if ($Detail) { Write-UiOperationLog -State $State -Message $Detail } } catch { }
    try { Write-UiOperationLog -State $State -Message "終了reason=$Reason" } catch { }
    try { Write-LogBuffer -State $State } catch { }
    try {
        if ($State.WorkerHandle) { Dispose-UiWorker -Worker $State.WorkerHandle }
    } catch { }
    $State.WorkerHandle = $null
    if ($State.OperationCancellation) {
        try { $State.OperationCancellation.Dispose() } catch { }
    }
    $State.OperationCancellation = $null
    $State.OperationEvents = $null
    $State.ActiveChildPid = $null
    $State.CurrentPhase = $null
    $State.OperationId = $null
    $State.CompletionHandled = $true
    try { Set-UiOperationState -State $State -OperationState 'Idle' } catch { $State.OperationState = 'Idle' }
    try { Write-LogBuffer -State $State } catch { }
    return $true
}

function Request-UiOperationCancellation {
    param([Parameter(Mandatory)][pscustomobject]$State)
    if ([string]$State.OperationState -notin @('Starting', 'Running')) { return $false }
    try { Set-UiOperationState -State $State -OperationState 'Cancelling' } catch { $State.OperationState = 'Cancelling' }
    if ($State.OperationCancellation) {
        try { $State.OperationCancellation.Cancel() } catch { }
    }
    Write-UiOperationLog -State $State -Message 'キャンセル要求を受け付けました。外部runnerのCancellationTokenを待機します。'
    return $true
}

function Get-FileRowStateKey {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $root.Length) {
        $fullPath = $fullPath.TrimEnd([char[]]@('\', '/'))
    }
    return $fullPath.ToUpperInvariant()
}

function Get-InputScopeKey {
    [CmdletBinding()]
    param([AllowNull()][string[]]$Paths)

    $unique = @{}
    foreach ($path in @($Paths)) {
        $key = Get-FileRowStateKey -Path ([string]$path)
        if ($key) { $unique[$key] = $true }
    }
    return (@($unique.Keys | Sort-Object) -join "`n")
}

function Get-InputFormatExtensions {
    return @{
        Audio = @(MediaNormalizer.Core\Get-AudioInputExtensions)
        Video = @(MediaNormalizer.Core\Get-VideoInputExtensions)
    }
}

function Get-FileClassification {
    # ExtMap のみで完結する純粋関数のため State 引数は不要。
    param(
        [System.IO.FileInfo]$File,
        [hashtable]$ExtMap
    )
    $ext = $File.Extension.ToLower()
    $isAudio = $ext -in $ExtMap.Audio
    $isVideo = $ext -in $ExtMap.Video
    if ($isAudio -and $isVideo) { return 'both' }
    if ($isAudio)               { return 'audio' }
    if ($isVideo)               { return 'video' }
    return 'none'
}

function Get-InputFiles {
    param(
        [string]$InputDir,
        [string[]]$InputPaths,
        [switch]$Recurse
    )
    $paths = @(
        if ($InputPaths -and $InputPaths.Count -gt 0) {
            $InputPaths
        } else {
            $InputDir
        }
    )
    return MediaNormalizer.Core\Get-MediaInputFiles -InputPath $paths -Recurse:$Recurse
}

function Set-UIEnabled {
    param([Parameter(Mandatory)][pscustomobject]$State, [bool]$Enabled)
    $c = $State.Controls
    $c.BtnRun.Enabled          = $Enabled
    $c.BtnScanFiles.Enabled    = $Enabled
    $c.TxtInput.Enabled        = $Enabled
    $c.BtnBrowseInput.Enabled  = $Enabled
    $c.TxtOutput.Enabled       = $Enabled
    $c.BtnBrowseOutput.Enabled = $Enabled
    $c.ChkAudio.Enabled        = $Enabled
    $c.ChkVideo.Enabled        = $Enabled
    $c.CmbPreset.Enabled       = $Enabled
    $c.CmbCollision.Enabled    = $Enabled
    if ($c.ContainsKey('NumSpeed'))      { $c.NumSpeed.Enabled = $Enabled }
    if ($c.ContainsKey('BtnApplySpeed')) { $c.BtnApplySpeed.Enabled = $Enabled }
    foreach ($key in @(
            'BtnBrowseFiles',
            'CmbAudioFormat',
            'ChkAnalyzeOnly',
            'ChkSkipNormalized',
            'ChkRecurse',
            'ChkPreserveHierarchy')) {
        if ($c.ContainsKey($key)) { $c[$key].Enabled = $Enabled }
    }
    if ($Enabled -and
        $c.ContainsKey('ChkAnalyzeOnly') -and
        $c.ChkAnalyzeOnly.Checked -and
        $c.ContainsKey('ChkSkipNormalized')) {
        $c.ChkSkipNormalized.Enabled = $false
    }
    $c.Dgv.Enabled             = $Enabled
    # キャンセルボタンは実行中（Enabled=$false）の間だけ有効化する
    $c.BtnCancel.Enabled       = -not $Enabled
}

function Save-FileGridSelectionStateFromGrid {
    param([Parameter(Mandatory)][pscustomobject]$State)

    Initialize-FileGridSelectionState -State $State | Out-Null
    $dgv = $State.Controls.Dgv
    $formatMap = Get-InputFormatExtensions
    $audioMode = $false
    $videoMode = $false
    if ($State.Controls.ContainsKey('ChkAudio')) { $audioMode = [bool]$State.Controls.ChkAudio.Checked }
    if ($State.Controls.ContainsKey('ChkVideo')) { $videoMode = [bool]$State.Controls.ChkVideo.Checked }

    foreach ($row in $dgv.Rows) {
        if ($row.PSObject.Properties['IsNewRow'] -and $row.IsNewRow) { continue }
        $fullName = [string]$row.Cells['FullName'].Value
        if ([string]::IsNullOrWhiteSpace($fullName)) { continue }
        $key = Get-FileRowStateKey -Path $fullName
        $existing = if ($State.FileRowState.ContainsKey($key)) { $State.FileRowState[$key] } else { $null }
        $supportsAudio = $false
        $supportsVideo = $false
        if ($existing) {
            $supportsAudio = [bool]$existing.SupportsAudio
            $supportsVideo = [bool]$existing.SupportsVideo
        } elseif ($State.PSObject.Properties['FileIndex'] -and $State.FileIndex.ContainsKey($fullName)) {
            $file = $State.FileIndex[$fullName]
            $ext = $file.Extension.ToLowerInvariant()
            $supportsAudio = $ext -in $formatMap.Audio
            $supportsVideo = $ext -in $formatMap.Video
        }

        $desiredAudio = if ($existing) { [bool]$existing.DesiredAudio } else { $supportsAudio }
        $desiredVideo = if ($existing) { [bool]$existing.DesiredVideo } else { $supportsVideo }
        if ($audioMode -and $supportsAudio) { $desiredAudio = ($row.Cells['Audio'].Value -eq $true) }
        if ($videoMode -and $supportsVideo) { $desiredVideo = ($row.Cells['Video'].Value -eq $true) }
        $speed = if ($existing) { $existing.SpeedPercent } else { 100 }
        if ($row.Cells['SpeedPercent'] -and $null -ne $row.Cells['SpeedPercent'].Value) {
            $speed = $row.Cells['SpeedPercent'].Value
        }
        $State.FileRowState[$key] = [pscustomobject]@{
            SupportsAudio = $supportsAudio
            SupportsVideo = $supportsVideo
            DesiredAudio  = $desiredAudio
            DesiredVideo  = $desiredVideo
            SpeedPercent  = $speed
        }
    }
}

function Save-FileGridSelectionStateFromRow {
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)]$Row
    )

    Initialize-FileGridSelectionState -State $State | Out-Null
    if ($Row.PSObject.Properties['IsNewRow'] -and $Row.IsNewRow) { return }
    $fullName = [string]$Row.Cells['FullName'].Value
    if ([string]::IsNullOrWhiteSpace($fullName)) { return }
    Save-FileGridSelectionStateFromGrid -State $State
}

function ConvertTo-FileGridSelectionRecord {
    param([Parameter(Mandatory)][pscustomobject]$State)

    Initialize-FileGridSelectionState -State $State | Out-Null
    $records = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $formatMap = Get-InputFormatExtensions
    foreach ($row in $State.Controls.Dgv.Rows) {
        if ($row.PSObject.Properties['IsNewRow'] -and $row.IsNewRow) { continue }
        $fullName = [string]$row.Cells['FullName'].Value
        if ([string]::IsNullOrWhiteSpace($fullName)) {
            $errors.Add('ファイル一覧の行にフルパスがありません。')
            continue
        }
        $fileIndex = if ($State.PSObject.Properties['FileIndex']) { $State.FileIndex } else { @{} }
        if (-not $fileIndex.ContainsKey($fullName)) {
            $errors.Add("ファイル一覧の索引にありません: $fullName")
            continue
        }
        $file = $fileIndex[$fullName]
        if (-not [string]::Equals(
                (Get-FileRowStateKey -Path $fullName),
                (Get-FileRowStateKey -Path $file.FullName),
                [StringComparison]::Ordinal)) {
            $errors.Add("ファイル一覧と索引のパスが一致しません: $fullName")
            continue
        }
        $key = Get-FileRowStateKey -Path $fullName
        $saved = if ($State.FileRowState.ContainsKey($key)) { $State.FileRowState[$key] } else { $null }
        $ext = $file.Extension.ToLowerInvariant()
        $supportsAudio = if ($saved) { [bool]$saved.SupportsAudio } else { $ext -in $formatMap.Audio }
        $supportsVideo = if ($saved) { [bool]$saved.SupportsVideo } else { $ext -in $formatMap.Video }
        $durationMap = if ($State.PSObject.Properties['DurationMap']) { $State.DurationMap } else { @{} }
        $duration = if ($durationMap.ContainsKey($fullName)) { [double]$durationMap[$fullName] } else { -1.0 }
        $records.Add([pscustomobject]@{
            FullName       = $fullName
            File           = $file
            SupportsAudio  = $supportsAudio
            SupportsVideo  = $supportsVideo
            AudioSelected  = ($row.Cells['Audio'].Value -eq $true)
            VideoSelected  = ($row.Cells['Video'].Value -eq $true)
            SpeedPercent   = $row.Cells['SpeedPercent'].Value
            Size           = [long]$file.Length
            Duration       = $duration
            DisplayName    = [string]$row.Cells['FileName'].Value
        })
    }
    return [pscustomobject]@{
        Records = @($records.ToArray())
        Errors  = @($errors.ToArray())
    }
}

function Get-FileSelectionSnapshotFromRecord {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Records,
        [bool]$AudioEnabled,
        [bool]$VideoEnabled,
        [bool]$AnalyzeOnly
    )

    $audioFiles = [Collections.Generic.List[object]]::new()
    $videoFiles = [Collections.Generic.List[object]]::new()
    $audioPaths = @{}
    $videoPaths = @{}
    $selectedFiles = @{}
    $allFiles = @{}
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        $path = [string]$record.FullName
        if ([string]::IsNullOrWhiteSpace($path)) {
            $errors.Add('選択レコードのフルパスが空です。')
            continue
        }
        $key = Get-FileRowStateKey -Path $path
        if (-not $allFiles.ContainsKey($key)) { $allFiles[$key] = $record }
        $selectAudio = $AudioEnabled -and [bool]$record.SupportsAudio -and [bool]$record.AudioSelected
        $selectVideo = $VideoEnabled -and [bool]$record.SupportsVideo -and [bool]$record.VideoSelected
        if ($selectAudio -and -not $audioPaths.ContainsKey($key)) {
            $audioPaths[$key] = $true
            [void]$audioFiles.Add($record.File)
        }
        if ($selectVideo -and -not $videoPaths.ContainsKey($key)) {
            $videoPaths[$key] = $true
            [void]$videoFiles.Add($record.File)
        }
        if (($selectAudio -or $selectVideo) -and -not $selectedFiles.ContainsKey($key)) {
            $selectedFiles[$key] = $record
        }
    }

    $executionVideoFiles = if ($AnalyzeOnly -and $audioFiles.Count -gt 0) { @() } else { @($videoFiles.ToArray()) }
    $executionPaths = @{}
    foreach ($file in @($audioFiles.ToArray()) + @($executionVideoFiles)) {
        if ($file) { $executionPaths[(Get-FileRowStateKey -Path $file.FullName)] = $true }
    }
    $selectedSize = 0L
    $selectedDuration = 0.0
    foreach ($record in $selectedFiles.Values) {
        $selectedSize += [long]$record.Size
        if ([double]$record.Duration -gt 0) { $selectedDuration += [double]$record.Duration }
    }
    $allSize = 0L
    foreach ($record in $allFiles.Values) { $allSize += [long]$record.Size }

    return [pscustomobject]@{
        AudioFiles          = @($audioFiles.ToArray())
        VideoFiles          = @($videoFiles.ToArray())
        ExecutionAudioFiles = @($audioFiles.ToArray())
        ExecutionVideoFiles = @($executionVideoFiles)
        AudioCount          = $audioFiles.Count
        VideoCount          = $videoFiles.Count
        ExecutionCount      = $audioFiles.Count + @($executionVideoFiles).Count
        SelectedPaths       = @($selectedFiles.Keys)
        ExecutionPaths      = @($executionPaths.Keys)
        SelectedSize        = $selectedSize
        AllSize             = $allSize
        SelectedDurationSec = $selectedDuration
        TotalFiles          = $allFiles.Count
        Errors              = @($errors.ToArray())
    }
}

function Get-FileGridSelectionSnapshot {
    param([Parameter(Mandatory)][pscustomobject]$State)

    Initialize-FileGridSelectionState -State $State | Out-Null
    $adapter = ConvertTo-FileGridSelectionRecord -State $State
    $audioEnabled = $false
    $videoEnabled = $false
    $analyzeOnly = $false
    if ($State.Controls.ContainsKey('ChkAudio')) { $audioEnabled = [bool]$State.Controls.ChkAudio.Checked }
    if ($State.Controls.ContainsKey('ChkVideo')) { $videoEnabled = [bool]$State.Controls.ChkVideo.Checked }
    if ($State.Controls.ContainsKey('ChkAnalyzeOnly')) { $analyzeOnly = [bool]$State.Controls.ChkAnalyzeOnly.Checked }
    $snapshot = Get-FileSelectionSnapshotFromRecord `
        -Records $adapter.Records `
        -AudioEnabled:$audioEnabled `
        -VideoEnabled:$videoEnabled `
        -AnalyzeOnly:$analyzeOnly
    $allErrors = @($adapter.Errors) + @($snapshot.Errors)
    $snapshot.Errors = @($allErrors)
    Add-Member -InputObject $snapshot -NotePropertyName 'HasPendingProbe' -NotePropertyValue (
        $State.PSObject.Properties['PendingProbeJobs'] -and
        $State.PendingProbeJobs -and $State.PendingProbeJobs.Count -gt 0) -Force
    return $snapshot
}

function Update-FileGridSummary {
    param([Parameter(Mandatory)][pscustomobject]$State)

    if (-not $State.Controls.ContainsKey('LblSummary')) { return }
    if ($State.PSObject.Properties['ScanValid'] -and -not $State.ScanValid) { return }
    $snapshot = Get-FileGridSelectionSnapshot -State $State
    if ($snapshot.Errors.Count -gt 0) {
        $State.Controls.LblSummary.Text = '[エラー] ファイル一覧の状態を検証できません'
        return
    }
    $sizeText = "対象合計 $(MediaNormalizer.Probe\Format-FileSize -Bytes $snapshot.SelectedSize) / 全体 $(MediaNormalizer.Probe\Format-FileSize -Bytes $snapshot.AllSize)"
    $durationText = if ($snapshot.HasPendingProbe) {
        ' / 再生時間 計算中...'
    } elseif ($snapshot.SelectedDurationSec -gt 0) {
        " / 合計再生時間 $(MediaNormalizer.Probe\Format-Duration -Seconds $snapshot.SelectedDurationSec)"
    } else { '' }
    $State.Controls.LblSummary.Text = "音声: $($snapshot.AudioCount)件 / 動画: $($snapshot.VideoCount)件 / 全 $($snapshot.TotalFiles)件 ($sizeText$durationText)"
}

function Get-SpeedPercentMapFromGrid {
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [AllowNull()][string[]]$EffectiveTargetPaths
    )

    $map = @{}
    $errors = New-Object System.Collections.Generic.List[string]
    $targetKeys = @{}
    $hasExplicitTargets = $PSBoundParameters.ContainsKey('EffectiveTargetPaths')
    foreach ($path in @($EffectiveTargetPaths)) {
        $key = Get-FileRowStateKey -Path ([string]$path)
        if ($key) { $targetKeys[$key] = $true }
    }
    foreach ($row in $State.Controls.Dgv.Rows) {
        $fullName = $row.Cells['FullName'].Value
        if (-not $fullName) { continue }
        $selected = if ($hasExplicitTargets) {
            $targetKeys.ContainsKey((Get-FileRowStateKey -Path ([string]$fullName)))
        } else {
            ($row.Cells['Audio'].Value -eq $true) -or ($row.Cells['Video'].Value -eq $true)
        }
        if (-not $selected) { continue }

        $defaultSpeed = 100
        if ($State.Controls.ContainsKey('NumSpeed')) { $defaultSpeed = [int]$State.Controls.NumSpeed.Value }
        try {
            $map[[string]$fullName] = MediaNormalizer.Core\ConvertTo-SpeedPercent -Value $row.Cells['SpeedPercent'].Value -Default $defaultSpeed
        } catch {
            $name = $row.Cells['FileName'].Value
            $errors.Add("${name}: $($_.Exception.Message)")
        }
    }
    return [pscustomobject]@{
        Values = $map
        Errors = $errors.ToArray()
    }
}

function Get-CommonInputRoot {
    param([Parameter(Mandatory)][string[]]$Paths)

    $directories = @($Paths | ForEach-Object {
        $full = [IO.Path]::GetFullPath($_)
        if (Test-Path -LiteralPath $full -PathType Container) {
            $full
        } else {
            Split-Path -Parent $full
        }
    })
    if ($directories.Count -eq 0) { return $null }
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
    return (Split-Path -Parent $directories[0])
}
Export-ModuleMember -Function Get-LegacyAutoInputDir, Get-LegacyAutoOutputDir, Get-SettingsPath, Get-LogPath, Split-ProbePathBatch, Initialize-ThreadJob, Read-Settings, Save-Settings, ConvertTo-PresetMap, Join-Presets, Import-Presets, Get-PresetRationaleText, Test-PresetConfigurationMatches, Write-Log, Write-LogBuffer, Start-LogTimer, Write-ProcessOutputLog, Update-Progress, Reset-Progress, Get-BuildProvenance, Get-TargetExtensions, Initialize-FileGridSelectionState, Set-UiOperationState, Set-UIEnabled, Write-UiOperationLog, Dispose-UiWorker, Test-UiActiveChildProcess, Complete-UiOperation, Request-UiOperationCancellation, Get-FileRowStateKey, Get-InputScopeKey, Get-InputFormatExtensions, Get-FileClassification, Get-InputFiles, Save-FileGridSelectionStateFromGrid, Save-FileGridSelectionStateFromRow, ConvertTo-FileGridSelectionRecord, Get-FileSelectionSnapshotFromRecord, Get-FileGridSelectionSnapshot, Update-FileGridSummary, Get-SpeedPercentMapFromGrid, Get-CommonInputRoot
