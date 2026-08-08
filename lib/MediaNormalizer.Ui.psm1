Set-StrictMode -Version Latest

<#
.SYNOPSIS
    メディア音量正規化ツール (GUI)
.DESCRIPTION
    ffmpeg-normalize を使用してメディアファイルのラウドネスを正規化する WinForms GUI。
    モジュールスコープの責務分割:
      - Initialize-UiState: Core State に UI 用フィールドを追加し ThreadJob を初期化
      - New-MainForm:        Form/Controls の構築とイベント結線
      - Show-MainForm:       ShowDialog 呼び出し
      - Set-ConsoleWindowHidden: ランチャーから呼ぶコンソール窓非表示
#>

# === WinForms / Win32 初期化（GUI エントリポイントからの遅延ロード） ===
# Linux runner（PowerShell 7）には System.Windows.Forms / System.Drawing が無く、
# モジュールロード時に Add-Type すると ItemNotFoundException で死ぬ。GUI を実際に
# 起動する関数（Set-ConsoleWindowHidden / New-MainForm / Initialize-UiState）の冒頭で
# Initialize-UiAssemblies を呼ぶことで、Linux 側ではテスト対象の純粋ロジック関数
# のみがモジュールロードに成功する。
function Initialize-UiAssemblies {
    [CmdletBinding()]
    param()
    if (-not $IsWindows) {
        throw 'MediaNormalizer.Ui の GUI 機能は Windows でのみ利用可能です。'
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (-not ('Native.Win32' -as [type])) {
        Add-Type -Name Win32 -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    }
}

# === モジュール定数 ===
# [Environment]::GetFolderPath('MyVideos') / 'ApplicationData' は Linux/macOS
# では空文字を返し、Join-Path に渡すと ParameterBindingValidationException で
# Import-Module ごと throw する。GUI 起動経路は Windows 確定だが、モジュール
# ロードは Linux 単体テストランナーでも成功させる必要があるため、これらの
# パス計算は「関数化」かつ「Windows 以外では明確な業務例外」とし、トップ
# レベル副作用を一切持たせない。
#
# LegacyAuto* は v1 の設定ファイルへ自動保存されていた旧既定値を識別する
# 移行処理専用。新規起動時の入力・出力欄には使用しない。
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
    $base = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrEmpty($base)) {
        throw 'MediaNormalizer.Ui の設定ファイルパスは Windows でのみ解決できます。'
    }
    Join-Path $base 'media-normalizer\settings.json'
}

$script:SettingsSchemaVersion = 2

# ThreadJob 内で実行されるため self-contained。State には ProbeScript として再配布する。
$script:ProbeScriptBlock = {
    param([string]$FilePath)
    try {
        $ffprobeArgs = @('-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',$FilePath)
        $result = & ffprobe @ffprobeArgs 2>$null
        $resultStr = (@($result) -join '').Trim()
        if ([string]::IsNullOrWhiteSpace($resultStr)) { return -1.0 }
        $dur = 0.0
        $parsed = [double]::TryParse(
            $resultStr,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$dur)
        if ($parsed -and $dur -gt 0) { return $dur }
        return -1.0
    } catch {
        return -1.0
    }
}
function Get-LogPath {
    $base = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrEmpty($base)) {
        throw 'MediaNormalizer.Ui のログファイルパスは Windows でのみ解決できます。'
    }
    Join-Path $base 'media-normalizer\media-normalizer.log'
}
$script:ProbeBatchSize = 25
$script:ProbeBatchScriptBlock = {
    param([scriptblock]$ProbeScript, [string[]]$FilePaths)
    foreach ($filePath in $FilePaths) {
        [pscustomobject]@{
            FullName = $filePath
            Duration = & $ProbeScript $filePath
        }
    }
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

# === モノスペースフォント生成（順次フォールバック） ===
function Test-FontInstalled {
    param([string]$Name)
    try {
        $fam = New-Object System.Drawing.FontFamily($Name)
        try { return ($fam.Name -eq $Name) } finally { $fam.Dispose() }
    } catch {
        return $false
    }
}

function New-MonospaceFont {
    param(
        [float]$Size = 9,
        [string[]]$Candidates = @('Cascadia Code', 'Consolas', 'Courier New')
    )
    foreach ($name in $Candidates) {
        if (Test-FontInstalled -Name $name) {
            return New-Object System.Drawing.Font($name, $Size)
        }
    }
    return New-Object System.Drawing.Font([System.Drawing.FontFamily]::GenericMonospace, $Size)
}

# === コンソール窓非表示 ===
function Set-ConsoleWindowHidden {
    Initialize-UiAssemblies
    $consoleHwnd = [Native.Win32]::GetConsoleWindow()
    if ($consoleHwnd -ne [IntPtr]::Zero) {
        [Native.Win32]::ShowWindow($consoleHwnd, 0) | Out-Null  # SW_HIDE
    }
}

# === ThreadJob 初期化 ===
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

# === Settings 永続化 ===
# Read-Settings/Save-Settings は GUI (Windows 確定) からも、Linux ランナーを
# 含むユニットテストからも呼ばれる。-SettingsPath を明示注入した呼び出しは
# Get-SettingsPath や旧自動フォルダのプラットフォーム依存関数を呼ばない。
# v2 以降は新規起動時の入力・出力を空欄にし、保存済みの値だけを復元する。
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
        return [pscustomobject]@{ Values = $values; Warnings = $warnings.ToArray() }
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $warnings.Add("[WARN ] settings.json の解析に失敗しました。既定値で起動します: $($_.Exception.Message)")
        return [pscustomobject]@{ Values = $values; Warnings = $warnings.ToArray() }
    }

    $propNames = @($json.PSObject.Properties.Name)
    if ($propNames -notcontains 'version') {
        $warnings.Add('[WARN ] settings.json に version が無いため既定値で起動します')
        return [pscustomobject]@{ Values = $values; Warnings = $warnings.ToArray() }
    }
    $verNum = 0
    if (-not [int]::TryParse([string]$json.version, [ref]$verNum)) {
        $warnings.Add("[WARN ] settings.json の version が不正です。既定値で起動します")
        return [pscustomobject]@{ Values = $values; Warnings = $warnings.ToArray() }
    }
    if ($verNum -gt $script:SettingsSchemaVersion) {
        $warnings.Add("[WARN ] settings.json の version=$verNum は未知のため既定値で起動します")
        return [pscustomobject]@{ Values = $values; Warnings = $warnings.ToArray() }
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

    return [pscustomobject]@{ Values = $values; Warnings = $warnings.ToArray() }
}

function Save-Settings {
    param(
        [string]$InputDir,
        [string]$OutputDir,
        [string]$LastPreset,
        [string]$LastMode,
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
    $payload = [pscustomobject]@{
        version    = $script:SettingsSchemaVersion
        inputDir   = $InputDir
        outputDir  = $OutputDir
        lastPreset = $LastPreset
        lastMode   = $LastMode
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
    $basePath = Join-Path $PSScriptRoot '..\assets\presets.json'
    $userPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'media-normalizer\presets.user.json'
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

# === Initialize-UiState ===
function Initialize-UiState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$State)

    Initialize-UiAssemblies

    # 既存 Form / Timer の Dispose（再実行耐性 — Add-Member -Force による参照喪失で
    # ハンドルが GC 待ちになるのを防ぐ）
    if ($State.PSObject.Properties['Form']) {
        $existingForm = $State.Form
        if ($existingForm -is [System.Windows.Forms.Form] -and -not $existingForm.IsDisposed) {
            try { $existingForm.Close() } catch { }
            try { $existingForm.Dispose() } catch { }
        }
    }
    if ($State.PSObject.Properties['LogTimer']) {
        $existingLogTimer = $State.LogTimer
        if ($existingLogTimer -is [System.Windows.Forms.Timer]) {
            try { $existingLogTimer.Stop() } catch { }
            try { $existingLogTimer.Dispose() } catch { }
        }
    }
    if ($State.PSObject.Properties['ProbeTimer']) {
        $existingProbeTimer = $State.ProbeTimer
        if ($existingProbeTimer -is [System.Windows.Forms.Timer]) {
            try { $existingProbeTimer.Stop() } catch { }
            try { $existingProbeTimer.Dispose() } catch { }
        }
    }

    Add-Member -InputObject $State -NotePropertyName 'ThreadJobSetupWarning' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'ProbeScript' -NotePropertyValue $script:ProbeScriptBlock -Force
    Add-Member -InputObject $State -NotePropertyName 'LogBuffer' -NotePropertyValue (New-Object System.Text.StringBuilder) -Force
    Add-Member -InputObject $State -NotePropertyName 'LogPath' -NotePropertyValue (Get-LogPath) -Force
    Add-Member -InputObject $State -NotePropertyName 'LogPersistenceWarningIssued' -NotePropertyValue $false -Force
    Add-Member -InputObject $State -NotePropertyName 'LogTimer' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'PendingProbeJobs' -NotePropertyValue @{} -Force
    Add-Member -InputObject $State -NotePropertyName 'FullNameToRow' -NotePropertyValue @{} -Force
    Add-Member -InputObject $State -NotePropertyName 'ProbeTimer' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'ProbeSummary' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'Form' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'Controls' -NotePropertyValue @{} -Force
    Add-Member -InputObject $State -NotePropertyName 'Presets' -NotePropertyValue @{} -Force
    Add-Member -InputObject $State -NotePropertyName 'InputSelectionPaths' -NotePropertyValue @() -Force
    Add-Member -InputObject $State -NotePropertyName 'ApplyingInputSelection' -NotePropertyValue $false -Force

    # HasThreadJob は Core State 既存。Initialize-ThreadJob の結果を代入する。
    $State.HasThreadJob = Initialize-ThreadJob -State $State

    return $State
}

# === ログ ===
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
    $timer.Add_Tick({ & $writeLogBufferFn -State $stateRef }.GetNewClosure())
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

# === 進捗 ===
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
    [System.Windows.Forms.Application]::DoEvents()
}

function Reset-Progress {
    param([Parameter(Mandatory)][pscustomobject]$State)
    $State.Controls.PnlProgressFill.Width = 0
    $State.Controls.LblProgress.Text = ''
    $State.ProcessedDurationSec = 0.0
    $State.TotalDurationSec = 0.0
    $State.ProcessingStartTime = $null
    $State.CurrentFileElapsedSec = 0.0
    [System.Windows.Forms.Application]::DoEvents()
}

# === ファイル一覧 ===
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

function Clear-FileListWithError {
    param([Parameter(Mandatory)][pscustomobject]$State, [string]$Message)
    $State.Controls.Dgv.Rows.Clear()
    $State.Controls.LblSummary.Text = "[エラー] $Message"
    $State.ScanValid = $false
    $State.CachedFiles = @()
    Write-Log -State $State -Message "[ERROR] $Message"
}

function Stop-PendingProbeJobs {
    param([Parameter(Mandatory)][pscustomobject]$State)
    if ($State.ProbeTimer) {
        try { $State.ProbeTimer.Stop() } catch { }
        try { $State.ProbeTimer.Dispose() } catch { }
        $State.ProbeTimer = $null
    }
    if ($State.PendingProbeJobs -and $State.PendingProbeJobs.Count -gt 0) {
        foreach ($jobId in @($State.PendingProbeJobs.Keys)) {
            $job = Get-Job -Id $jobId -ErrorAction SilentlyContinue
            if ($job) {
                try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch { }
                try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
        $State.PendingProbeJobs.Clear()
    }
}

function Update-FileGrid {
    param([Parameter(Mandatory)][pscustomobject]$State)
    # 既存の probe を停止してから再構築する（チェックボックス切替・再スキャン時）
    Stop-PendingProbeJobs -State $State

    $dgv = $State.Controls.Dgv
    $dgv.Rows.Clear()
    $State.DurationMap = @{}
    $State.FileIndex = @{}            # FullName -> FileInfo の O(1) 索引
    $State.FullNameToRow = @{}        # FullName -> DataGridViewRow の O(1) 索引（ProbeTimer 用）
    $extMap = Get-TargetExtensions -State $State
    $audioCount = 0; $videoCount = 0; $targetSize = 0L; $totalSize = 0L
    $totalDur = 0.0
    $fileCount = $State.CachedFiles.Count
    $useAsync = [bool]$State.HasThreadJob

    for ($i = 0; $i -lt $fileCount; $i++) {
        $f = $State.CachedFiles[$i]
        $cls = Get-FileClassification -File $f -ExtMap $extMap
        $chkA = ($cls -eq 'audio' -or $cls -eq 'both')
        $chkV = ($cls -eq 'video' -or $cls -eq 'both')

        $State.FileIndex[$f.FullName] = $f
        $totalSize += $f.Length
        if ($cls -ne 'none') { $targetSize += $f.Length }
        if ($chkA) { $audioCount++ }
        if ($chkV) { $videoCount++ }

        $initialDurStr = if ($useAsync) { '取得中...' } else {
            $dur = MediaNormalizer.Probe\Get-MediaDuration -State $State -FilePath $f.FullName
            $State.DurationMap[$f.FullName] = $dur
            if ($dur -gt 0) { $totalDur += $dur }
            MediaNormalizer.Probe\Format-Duration -Seconds $dur
        }

        $sizeStr = MediaNormalizer.Probe\Format-FileSize -Bytes $f.Length
        $speedPercent = 100
        if ($State.Controls.ContainsKey('NumSpeed')) { $speedPercent = [int]$State.Controls.NumSpeed.Value }
        $displayName = $f.Name
        $inputRoot = $State.Controls.TxtInput.Text.Trim()
        if (Test-Path -LiteralPath $inputRoot -PathType Container) {
            $relativeName = MediaNormalizer.Core\Get-RelativeMediaPath `
                -BasePath $inputRoot `
                -Path $f.FullName
            if ($relativeName) { $displayName = $relativeName }
        }
        $rowIdx = $dgv.Rows.Add($chkA, $chkV, $displayName, $f.Extension.ToLower(), $sizeStr, $initialDurStr, $speedPercent, $f.FullName)
        $row = $dgv.Rows[$rowIdx]
        $State.FullNameToRow[$f.FullName] = $row
        if ($cls -eq 'none') {
            $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
            $row.Cells['Audio'].ReadOnly = $true
            $row.Cells['Video'].ReadOnly = $true
        }

        if (-not $useAsync -or ($i + 1) % 5 -eq 0) {
            $State.Controls.LblSummary.Text = "スキャン中... $($i + 1) / $fileCount"
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    if ($useAsync -and $fileCount -gt 0) {
        $probePaths = @($State.CachedFiles | ForEach-Object FullName)
        foreach ($batch in @(Split-ProbePathBatch -FilePath $probePaths -BatchSize $script:ProbeBatchSize)) {
            try {
                $job = Start-ThreadJob `
                    -ScriptBlock $script:ProbeBatchScriptBlock `
                    -ArgumentList $State.ProbeScript, @($batch) `
                    -ThrottleLimit 4
                $State.PendingProbeJobs[$job.Id] = @($batch)
            } catch {
                foreach ($fullName in @($batch)) {
                    $dur = MediaNormalizer.Probe\Get-MediaDuration -State $State -FilePath $fullName
                    $State.DurationMap[$fullName] = $dur
                    if ($State.FullNameToRow.ContainsKey($fullName)) {
                        $State.FullNameToRow[$fullName].Cells['Duration'].Value =
                            MediaNormalizer.Probe\Format-Duration -Seconds $dur
                    }
                    if ($dur -gt 0) { $totalDur += $dur }
                }
            }
        }
    }

    $total = $fileCount
    $sizeText = "対象合計 $(MediaNormalizer.Probe\Format-FileSize -Bytes $targetSize) / 全体 $(MediaNormalizer.Probe\Format-FileSize -Bytes $totalSize)"
    if ($useAsync -and $State.PendingProbeJobs.Count -gt 0) {
        $State.Controls.LblSummary.Text = "音声: ${audioCount}件 / 動画: ${videoCount}件 / 全 ${total}件 ($sizeText / 再生時間 計算中...)"
        $State.ProbeSummary = [pscustomobject]@{
            AudioCount = $audioCount
            VideoCount = $videoCount
            Total      = $total
            SizeText   = $sizeText
        }
        # プローブ完了までは「実行」を無効化（残時間 ETA を確定 Duration ベースで計算するため）
        if ($State.Controls.BtnRun) { $State.Controls.BtnRun.Enabled = $false }
        Start-ProbeTimer -State $State
    } else {
        $durDisplay = if ($totalDur -gt 0) { " / 合計再生時間 $(MediaNormalizer.Probe\Format-Duration -Seconds $totalDur)" } else { '' }
        $State.Controls.LblSummary.Text = "音声: ${audioCount}件 / 動画: ${videoCount}件 / 全 ${total}件 ($sizeText$durDisplay)"
        # 前回の非同期プローブで無効化された可能性があるため、Duration が同期で揃っているなら明示的に再有効化
        if ($State.Controls.BtnRun -and -not $State.RunningProcess) {
            $State.Controls.BtnRun.Enabled = $true
        }
    }
}

function Start-ProbeTimer {
    param([Parameter(Mandatory)][pscustomobject]$State)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $stateRef = $State
    $timer.Add_Tick({
        $st = $stateRef
        $dgv = $st.Controls.Dgv
        $completedIds = @()
        foreach ($jobId in @($st.PendingProbeJobs.Keys)) {
            $job = Get-Job -Id $jobId -ErrorAction SilentlyContinue
            if (-not $job) { $completedIds += $jobId; continue }
            if ($job.State -in @('Completed','Failed','Stopped')) {
                $expectedPaths = @($st.PendingProbeJobs[$jobId])
                $results = @()
                if ($job.State -eq 'Completed') {
                    try {
                        $results = @(Receive-Job -Job $job -ErrorAction Stop)
                    } catch { $results = @() }
                }
                try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }
                $resultMap = @{}
                foreach ($result in $results) {
                    if ($result -and $result.PSObject.Properties['FullName']) {
                        $resultMap[[string]$result.FullName] = [double]$result.Duration
                    }
                }
                foreach ($fullName in $expectedPaths) {
                    $dur = if ($resultMap.ContainsKey($fullName)) { $resultMap[$fullName] } else { -1.0 }
                    $st.DurationMap[$fullName] = $dur
                    if ($st.FullNameToRow.ContainsKey($fullName)) {
                        $row = $st.FullNameToRow[$fullName]
                        # 行が DataGridView から外されていないか防衛（Rows.Clear / 再構築直後の競合対策）
                        if ($row -and -not $row.IsNewRow -and $row.DataGridView -eq $dgv) {
                            try {
                                $row.Cells['Duration'].Value = MediaNormalizer.Probe\Format-Duration -Seconds $dur
                            } catch {
                                # 行 Dispose 等で書き込みに失敗した場合は無視
                            }
                        }
                    }
                }
                $completedIds += $jobId
            }
        }
        foreach ($id in $completedIds) { [void]$st.PendingProbeJobs.Remove($id) }

        if ($st.PendingProbeJobs.Count -eq 0) {
            try { $st.ProbeTimer.Stop() } catch { }
            try { $st.ProbeTimer.Dispose() } catch { }
            $st.ProbeTimer = $null

            if ($st.ProbeSummary) {
                $totalDur = 0.0
                foreach ($d in $st.DurationMap.Values) { if ($d -gt 0) { $totalDur += $d } }
                $durDisplay = if ($totalDur -gt 0) { " / 合計再生時間 $(MediaNormalizer.Probe\Format-Duration -Seconds $totalDur)" } else { '' }
                $s = $st.ProbeSummary
                $st.Controls.LblSummary.Text = "音声: $($s.AudioCount)件 / 動画: $($s.VideoCount)件 / 全 $($s.Total)件 ($($s.SizeText)$durDisplay)"
            }

            # プローブ完了で「実行」を再有効化。ただし実行中（CancelRequested を待っている状態）は触らない
            if ($st.Controls.BtnRun -and -not $st.RunningProcess) {
                $st.Controls.BtnRun.Enabled = $true
            }
        }
    }.GetNewClosure())
    $State.ProbeTimer = $timer
    $timer.Start()
}

function Update-FileList {
    param([Parameter(Mandatory)][pscustomobject]$State)
    $inputDir = $State.Controls.TxtInput.Text.Trim()

    $selectedPaths = @(
        if ($State.InputSelectionPaths -and $State.InputSelectionPaths.Count -gt 0) {
            $State.InputSelectionPaths
        } else {
            $inputDir
        }
    )
    if ($selectedPaths.Count -eq 0 -or
        ($selectedPaths.Count -eq 1 -and [string]::IsNullOrWhiteSpace($selectedPaths[0]))) {
        Clear-FileListWithError -State $State -Message '入力ファイル/フォルダパスが空です。'
        return
    }
    foreach ($selectedPath in $selectedPaths) {
        if (-not (Test-Path -LiteralPath $selectedPath)) {
            Clear-FileListWithError -State $State -Message "入力パスが見つかりません: $selectedPath"
            return
        }
    }

    try {
        $recurse = $true
        if ($State.Controls.ContainsKey('ChkRecurse')) {
            $recurse = [bool]$State.Controls.ChkRecurse.Checked
        }
        $files = Get-InputFiles `
            -InputDir $inputDir `
            -InputPaths $selectedPaths `
            -Recurse:$recurse
    } catch {
        Clear-FileListWithError -State $State -Message "ファイル列挙に失敗: $($_.Exception.Message)"
        return
    }

    $State.ScanValid = $true
    $State.CachedFiles = @($files)
    Update-FileGrid -State $State
}

function Get-SpeedPercentMapFromGrid {
    param([Parameter(Mandatory)][pscustomobject]$State)

    $map = @{}
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($row in $State.Controls.Dgv.Rows) {
        $fullName = $row.Cells['FullName'].Value
        if (-not $fullName) { continue }
        $selected = ($row.Cells['Audio'].Value -eq $true) -or ($row.Cells['Video'].Value -eq $true)
        if (-not $selected) { continue }

        try {
            $map[[string]$fullName] = MediaNormalizer.Core\ConvertTo-SpeedPercent -Value $row.Cells['SpeedPercent'].Value -Default ([int]$State.Controls.NumSpeed.Value)
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

# === Normalize 呼び出しアダプタ ===
function Invoke-NormalizeUi {
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][ValidateSet('audio','video')][string]$Mode,
        [System.IO.FileInfo[]]$TargetFiles,
        [hashtable]$SpeedPercentByPath
    )

    $policyMap = @{ '連番付与' = 'rename'; 'スキップ' = 'skip'; '上書き' = 'overwrite' }
    $policy = $policyMap[[string]$State.Controls.CmbCollision.SelectedItem]
    if (-not $policy) { $policy = 'rename' }

    $stateRef = $State
    [scriptblock]$writeLogFn = ${function:Write-Log}
    [scriptblock]$updateProgressFn = ${function:Update-Progress}
    [scriptblock]$getTargetExtensionsFn = ${function:Get-TargetExtensions}
    $loggerSb   = { param($m) & $writeLogFn -State $stateRef -Message $m }.GetNewClosure()
    $progressSb = { param($current, $total) & $updateProgressFn -State $stateRef -Current $current -Total $total }.GetNewClosure()
    $extSb      = { & $getTargetExtensionsFn -State $stateRef }.GetNewClosure()
    $pumpSb     = { [System.Windows.Forms.Application]::DoEvents() }

    $params = @{
        State               = $State
        Mode                = $Mode
        InputDir            = $State.Controls.TxtInput.Text.Trim()
        OutputDir           = $State.Controls.TxtOutput.Text.Trim()
        Target              = [double]$State.Controls.NumTarget.Value
        TruePeak            = [double]$State.Controls.NumTP.Value
        Bitrate             = [string]$State.Controls.CmbBR.SelectedItem
        SampleRate          = [string]$State.Controls.CmbSR.SelectedItem
        CollisionPolicy     = $policy
        Logger              = $loggerSb
        Progress            = $progressSb
        GetTargetExtensions = $extSb
        PumpEvents          = $pumpSb
        SpeedPercent        = [int]$State.Controls.NumSpeed.Value
        AudioOutputFormat   = [string]$State.Controls.CmbAudioFormat.SelectedItem
        AnalyzeOnly         = [bool]$State.Controls.ChkAnalyzeOnly.Checked
        SkipIfNormalized    = [bool]$State.Controls.ChkSkipNormalized.Checked
        Recurse             = [bool]$State.Controls.ChkRecurse.Checked
        PreserveHierarchy   = [bool]$State.Controls.ChkPreserveHierarchy.Checked
        InputPaths          = @($State.InputSelectionPaths)
        ReportPath          = $State.ReportPath
    }
    if ($TargetFiles) { $params.TargetFiles = $TargetFiles }
    if ($SpeedPercentByPath) { $params.SpeedPercentByPath = $SpeedPercentByPath }
    return MediaNormalizer.Core\Invoke-Normalize @params
}

# === DPI / screen layout ===
function Get-ConstrainedFormBounds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DesiredSize,
        [Parameter(Mandatory)]$WorkingArea,
        [ValidateRange(0, 2147483647)][int]$Margin = 24
    )

    $areaWidth = [int]$WorkingArea.Width
    $areaHeight = [int]$WorkingArea.Height
    if ($areaWidth -le 0 -or $areaHeight -le 0) {
        throw 'WorkingArea の幅と高さは正の値である必要があります。'
    }

    # Margin は作業領域より小さい場合だけ差し引く。極小の作業領域でも
    # 320px等の固定下限へ戻さず、最終サイズが必ず領域内に収まるようにする。
    $availableWidth = [math]::Max(1, $areaWidth - [math]::Min($Margin, $areaWidth - 1))
    $availableHeight = [math]::Max(1, $areaHeight - [math]::Min($Margin, $areaHeight - 1))
    $width = [math]::Min([math]::Max(1, [int]$DesiredSize.Width), $availableWidth)
    $height = [math]::Min([math]::Max(1, [int]$DesiredSize.Height), $availableHeight)

    return [pscustomobject]@{
        X      = [int]$WorkingArea.Left + [math]::Floor(($areaWidth - $width) / 2)
        Y      = [int]$WorkingArea.Top + [math]::Floor(($areaHeight - $height) / 2)
        Width  = $width
        Height = $height
    }
}

function Set-FileGridColumnLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DataGridView,
        [ValidateRange(1, 2147483647)][int]$Dpi
    )

    $scale = [double]$Dpi / 96.0
    $fixedLogicalWidths = [ordered]@{
        Audio        = 42
        Video        = 42
        Ext          = 55
        Size         = 70
        Duration     = 62
        SpeedPercent = 70
    }

    foreach ($entry in $fixedLogicalWidths.GetEnumerator()) {
        $column = $DataGridView.Columns[[string]$entry.Key]
        if ($null -eq $column) {
            throw "ファイル一覧の列が見つかりません: $($entry.Key)"
        }
        $column.AutoSizeMode = 'None'
        $column.Width = [math]::Max(1, [int][math]::Round([int]$entry.Value * $scale))
    }

    $fileNameColumn = $DataGridView.Columns['FileName']
    if ($null -eq $fileNameColumn) {
        throw 'ファイル一覧の列が見つかりません: FileName'
    }
    # DataGridViewColumn.Width はフォームのDPI自動スケール対象外なので、
    # 最低幅だけを明示的に倍率変換し、残りの表示領域はファイル名へ割り当てる。
    $fileNameColumn.MinimumWidth = [math]::Max(1, [int][math]::Round(190 * $scale))
    $fileNameColumn.AutoSizeMode = 'Fill'
    $fileNameColumn.FillWeight = 100
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

function Set-UiInputSelection {
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][string[]]$Paths
    )

    $validPaths = @($Paths | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_)
    } | ForEach-Object { [IO.Path]::GetFullPath($_) })
    if ($validPaths.Count -eq 0) { return }
    $State.InputSelectionPaths = $validPaths
    $displayPath = if ($validPaths.Count -eq 1) {
        $validPaths[0]
    } else {
        Get-CommonInputRoot -Paths $validPaths
    }
    $State.ApplyingInputSelection = $true
    try {
        $State.Controls.TxtInput.Text = $displayPath
    } finally {
        $State.ApplyingInputSelection = $false
    }
    Update-FileList -State $State
}

function Register-InputDropTarget {
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)]$Control
    )

    $Control.AllowDrop = $true
    $stateRef = $State
    [scriptblock]$setUiInputSelectionFn = ${function:Set-UiInputSelection}
    $Control.Add_DragEnter({
        param($sender, $eventArgs)
        if ($eventArgs.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        } else {
            $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::None
        }
    })
    $Control.Add_DragDrop({
        param($sender, $eventArgs)
        $paths = @($eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
        if ($paths.Count -gt 0) {
            & $setUiInputSelectionFn -State $stateRef -Paths $paths
        }
    }.GetNewClosure())
}

function Register-MainFormEventHandlers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][System.Windows.Forms.Form]$Form
    )

    $stateRef = $State
    $c = $State.Controls
    [scriptblock]$getPresetRationaleTextFn = ${function:Get-PresetRationaleText}
    [scriptblock]$getSpeedPercentMapFromGridFn = ${function:Get-SpeedPercentMapFromGrid}
    [scriptblock]$invokeNormalizeUiFn = ${function:Invoke-NormalizeUi}
    [scriptblock]$resetProgressFn = ${function:Reset-Progress}
    [scriptblock]$saveSettingsFn = ${function:Save-Settings}
    [scriptblock]$setUiEnabledFn = ${function:Set-UIEnabled}
    [scriptblock]$stopPendingProbeJobsFn = ${function:Stop-PendingProbeJobs}
    [scriptblock]$testPresetConfigurationMatchesFn = ${function:Test-PresetConfigurationMatches}
    [scriptblock]$updateProgressFn = ${function:Update-Progress}
    [scriptblock]$writeLogFn = ${function:Write-Log}
    [scriptblock]$writeLogBufferFn = ${function:Write-LogBuffer}

    # フラグを立てて Invoke-Normalize のループ先頭で中断させる。実行中プロセスの終了は
    # Invoke-MediaNormalizerProcess runner 側の CancelAction が一元的に担う。
    $c.BtnCancel.Add_Click({
        if ($stateRef.CancelRequested) { return }
        $stateRef.CancelRequested = $true
        & $writeLogFn -State $stateRef -Message '[INFO ] キャンセル要求を受け付けました。実行中のプロセスを終了します...'
        $stateRef.Controls.BtnCancel.Enabled = $false
    }.GetNewClosure())

    $c.BtnRun.Add_Click({
        $cc = $stateRef.Controls
        $cc.Dgv.EndEdit()
        $cc.TxtLog.Clear()
        [void]$stateRef.LogBuffer.Clear()
        $stateRef.ReportRecords.Clear()
        if ([string]::IsNullOrWhiteSpace($cc.TxtOutput.Text)) {
            & $writeLogFn -State $stateRef -Message '[ERROR] 出力フォルダを指定してください。'
            return
        }
        $stateRef.ReportPath = Join-Path $cc.TxtOutput.Text.Trim() (
            'media-normalizer-report-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $stateRef.CancelRequested = $false
        & $resetProgressFn -State $stateRef

        $selectedPreset = $stateRef.Presets[[string]$cc.CmbPreset.SelectedItem]
        if (-not $selectedPreset) {
            & $writeLogFn -State $stateRef -Message '[ERROR] 選択中のプリセットを解決できません。選び直してください。'
            return
        }
        $matchesPreset = & $testPresetConfigurationMatchesFn `
            -Preset $selectedPreset `
            -Target ([double]$cc.NumTarget.Value) `
            -TruePeak ([double]$cc.NumTP.Value) `
            -Bitrate ([string]$cc.CmbBR.SelectedItem) `
            -SampleRate ([string]$cc.CmbSR.SelectedItem) `
            -OutputFormat ([string]$cc.CmbAudioFormat.SelectedItem)
        $configurationWarning = if ($matchesPreset) {
            'プリセット値と現在値は一致しています。'
        } else {
            '警告: 現在値が選択プリセットから変更されています。'
        }
        $confirmation = @(
            "プリセット: $($cc.CmbPreset.SelectedItem)",
            "用途/根拠: $(& $getPresetRationaleTextFn -Preset $selectedPreset)",
            '',
            "現在値: $($cc.NumTarget.Value) LUFS / $($cc.NumTP.Value) dBTP / $($cc.CmbAudioFormat.SelectedItem)",
            $configurationWarning,
            '',
            'この設定で続行しますか？'
        ) -join "`r`n"
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $confirmation,
            '設定根拠の確認',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        if (-not $stateRef.ScanValid -or $cc.Dgv.Rows.Count -eq 0) {
            & $writeLogFn -State $stateRef -Message '[INFO ] 一覧が未確認状態です。実行前に [確認] で対象を確認できます。'
            if (-not $cc.ChkAudio.Checked -and -not $cc.ChkVideo.Checked) {
                & $writeLogFn -State $stateRef -Message '[ERROR] 処理モードが選択されていません。少なくとも1つチェックしてください。'
                return
            }
            & $setUiEnabledFn -State $stateRef -Enabled $false
            $stateRef.ProgressCurrent = 0
            $stateRef.ProgressTotal = 0
            $stateRef.TotalDurationSec = 0.0
            $stateRef.ProcessedDurationSec = 0.0
            $stateRef.ProcessingStartTime = Get-Date
            try {
                if ($cc.ChkAudio.Checked) {
                    & $invokeNormalizeUiFn -State $stateRef -Mode 'audio'
                }
                if ($cc.ChkVideo.Checked -and
                    -not ($cc.ChkAnalyzeOnly.Checked -and $cc.ChkAudio.Checked)) {
                    & $invokeNormalizeUiFn -State $stateRef -Mode 'video'
                }
            } finally {
                & $setUiEnabledFn -State $stateRef -Enabled $true
            }
            return
        }

        $audioFiles = @()
        $videoFiles = @()
        foreach ($row in $cc.Dgv.Rows) {
            $fullName = $row.Cells['FullName'].Value
            if (-not $fullName) { continue }
            $file = $stateRef.FileIndex[$fullName]
            if (-not $file) { continue }
            if ($row.Cells['Audio'].Value -eq $true) { $audioFiles += $file }
            if ($row.Cells['Video'].Value -eq $true) { $videoFiles += $file }
        }
        if ($audioFiles.Count -eq 0 -and $videoFiles.Count -eq 0) {
            & $writeLogFn -State $stateRef -Message '[ERROR] チェックされたファイルがありません。音声・動画列にチェックを入れてください。'
            return
        }

        $speedResult = & $getSpeedPercentMapFromGridFn -State $stateRef
        if ($speedResult.Errors.Count -gt 0) {
            & $writeLogFn -State $stateRef -Message '[ERROR] 速度(%) の指定が不正です。50 から 200 の整数で入力してください。'
            foreach ($err in $speedResult.Errors) {
                & $writeLogFn -State $stateRef -Message "        $err"
            }
            & $writeLogBufferFn -State $stateRef
            return
        }

        $stateRef.ProgressCurrent = 0
        $analyzeAudioOnly = ($cc.ChkAnalyzeOnly.Checked -and $audioFiles.Count -gt 0)
        $stateRef.ProgressTotal = if ($analyzeAudioOnly) {
            $audioFiles.Count
        } else {
            $audioFiles.Count + $videoFiles.Count
        }
        $stateRef.TotalDurationSec = 0.0
        $stateRef.ProcessedDurationSec = 0.0
        foreach ($audioFile in $audioFiles) {
            $duration = $stateRef.DurationMap[$audioFile.FullName]
            if ($duration -and $duration -gt 0) { $stateRef.TotalDurationSec += $duration }
        }
        if (-not $analyzeAudioOnly) {
            foreach ($videoFile in $videoFiles) {
                $duration = $stateRef.DurationMap[$videoFile.FullName]
                if ($duration -and $duration -gt 0) { $stateRef.TotalDurationSec += $duration }
            }
        }
        $stateRef.ProcessingStartTime = Get-Date
        & $updateProgressFn -State $stateRef -Current 0 -Total $stateRef.ProgressTotal

        & $setUiEnabledFn -State $stateRef -Enabled $false
        try {
            if ($audioFiles.Count -gt 0) {
                & $invokeNormalizeUiFn -State $stateRef -Mode 'audio' `
                    -TargetFiles $audioFiles -SpeedPercentByPath $speedResult.Values
            }
            if ($videoFiles.Count -gt 0 -and -not $analyzeAudioOnly) {
                & $invokeNormalizeUiFn -State $stateRef -Mode 'video' `
                    -TargetFiles $videoFiles -SpeedPercentByPath $speedResult.Values
            }
        } finally {
            & $setUiEnabledFn -State $stateRef -Enabled $true
        }
    }.GetNewClosure())

    # === FormClosing: request cancellation before closing & persist settings ===
    # Save-Settings は LogTimer Dispose と最終 Write-LogBuffer より前に呼ぶ。
    $Form.Add_FormClosing({
        param($sender, $eventArgs)
        if ($stateRef.RunningProcess -and -not $stateRef.RunningProcess.HasExited) {
            $eventArgs.Cancel = $true
            if (-not $stateRef.CancelRequested) {
                $answer = [System.Windows.Forms.MessageBox]::Show(
                    '処理をキャンセルして終了しますか？',
                    'Media Normalizer',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning)
                if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                    $stateRef.CancelRequested = $true
                    if ($stateRef.Controls.BtnCancel) { $stateRef.Controls.BtnCancel.Enabled = $false }
                    & $writeLogFn -State $stateRef -Message '[INFO ] 終了要求を受け付けました。プロセスツリーを安全に停止しています...'
                }
            }
            return
        }
        & $stopPendingProbeJobsFn -State $stateRef

        $cc = $stateRef.Controls
        $mode = if ($cc.ChkAudio.Checked -and $cc.ChkVideo.Checked) { 'both' }
        elseif ($cc.ChkAudio.Checked) { 'audio' }
        elseif ($cc.ChkVideo.Checked) { 'video' }
        else { 'audio' }
        & $saveSettingsFn -InputDir $cc.TxtInput.Text `
            -OutputDir $cc.TxtOutput.Text `
            -LastPreset ([string]$cc.CmbPreset.SelectedItem) `
            -LastMode $mode `
            -State $stateRef

        if ($stateRef.LogTimer) {
            try { $stateRef.LogTimer.Stop() } catch { }
            try { $stateRef.LogTimer.Dispose() } catch { }
            $stateRef.LogTimer = $null
        }
        & $writeLogBufferFn -State $stateRef
    }.GetNewClosure())
}

# === New-MainForm ===
function New-MainForm {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$State)

    Initialize-UiAssemblies

    if (-not $State.PSObject.Properties['Controls']) {
        throw 'State has not been initialized. Call Initialize-UiState first.'
    }

    $presetWarnings = [Collections.Generic.List[string]]::new()
    $presets = Import-Presets -Warnings ([ref]$presetWarnings)
    foreach ($presetWarning in $presetWarnings) {
        Write-Log -State $State -Message "  [WARN ] $presetWarning"
    }
    $presetNames = @($presets.Keys)
    $State.Presets = $presets

    $c = $State.Controls
    $stateRef = $State
    # GetNewClosure preserves local UI state by creating a dynamic module. Capture
    # private helper ScriptBlocks explicitly so delayed .NET callbacks do not rely
    # on those helpers being exported into the caller's session state.
    [scriptblock]$getPresetRationaleTextFn = ${function:Get-PresetRationaleText}
    [scriptblock]$setFileGridColumnLayoutFn = ${function:Set-FileGridColumnLayout}
    [scriptblock]$setUiInputSelectionFn = ${function:Set-UiInputSelection}
    [scriptblock]$updateFileGridFn = ${function:Update-FileGrid}
    [scriptblock]$updateFileListFn = ${function:Update-FileList}
    [scriptblock]$writeLogFn = ${function:Write-Log}
    [scriptblock]$writeLogBufferFn = ${function:Write-LogBuffer}

    $form = New-Object System.Windows.Forms.Form
    # PowerShell 7 はディスプレイの実 DPI を使用する。96 DPI を設計基準として
    # 初期化全体を SuspendLayout で囲み、固定座標・固定サイズのコントロールも
    # フォントと同じ倍率で一括スケールさせる。
    $form.SuspendLayout()
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.AutoScroll = $true
    $form.Text = 'メディア音量正規化ツール'
    $form.Size = New-Object System.Drawing.Size(620, 980)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Yu Gothic UI', 9)
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.AllowDrop = $true

    $y = 12

    # --- Input folder ---
    $lblInput = New-Object System.Windows.Forms.Label
    $lblInput.Text = '入力ファイル / フォルダ（この画面へドラッグ＆ドロップ可）'
    $lblInput.Location = New-Object System.Drawing.Point(12, $y)
    $lblInput.AutoSize = $true
    $form.Controls.Add($lblInput)
    $y += 20

    $txtInput = New-Object System.Windows.Forms.TextBox
    $txtInput.Text = ''
    $txtInput.Location = New-Object System.Drawing.Point(12, $y)
    $txtInput.Size = New-Object System.Drawing.Size(400, 24)
    $form.Controls.Add($txtInput)
    $c.TxtInput = $txtInput

    $btnBrowseInput = New-Object System.Windows.Forms.Button
    $btnBrowseInput.Text = '...'
    $btnBrowseInput.Location = New-Object System.Drawing.Point(418, ($y - 1))
    $btnBrowseInput.Size = New-Object System.Drawing.Size(50, 24)
    $btnBrowseInput.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.SelectedPath = $stateRef.Controls.TxtInput.Text
        if ($dlg.ShowDialog() -eq 'OK') {
            & $setUiInputSelectionFn -State $stateRef -Paths @($dlg.SelectedPath)
        }
    }.GetNewClosure())
    $form.Controls.Add($btnBrowseInput)
    $c.BtnBrowseInput = $btnBrowseInput

    $btnBrowseFiles = New-Object System.Windows.Forms.Button
    $btnBrowseFiles.Text = 'ファイル'
    $btnBrowseFiles.Location = New-Object System.Drawing.Point(474, ($y - 1))
    $btnBrowseFiles.Size = New-Object System.Drawing.Size(56, 24)
    $btnBrowseFiles.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Multiselect = $true
        $dlg.Filter = 'メディアファイル|*.aac;*.aif;*.aiff;*.flac;*.m4a;*.mp3;*.ogg;*.opus;*.wav;*.wma;*.mp4;*.mov;*.mkv;*.avi|すべてのファイル|*.*'
        if ($dlg.ShowDialog() -eq 'OK') {
            & $setUiInputSelectionFn -State $stateRef -Paths @($dlg.FileNames)
        }
    }.GetNewClosure())
    $form.Controls.Add($btnBrowseFiles)
    $c.BtnBrowseFiles = $btnBrowseFiles

    $btnOpenInput = New-Object System.Windows.Forms.Button
    $btnOpenInput.Text = '開く'
    $btnOpenInput.Location = New-Object System.Drawing.Point(534, ($y - 1))
    $btnOpenInput.Size = New-Object System.Drawing.Size(54, 24)
    $btnOpenInput.Add_Click({
        $dir = $stateRef.Controls.TxtInput.Text.Trim()
        if (Test-Path -LiteralPath $dir -PathType Container) {
            Invoke-Item -LiteralPath $dir
        }
    }.GetNewClosure())
    $form.Controls.Add($btnOpenInput)
    $c.BtnOpenInput = $btnOpenInput
    $y += 30

    # --- Output folder ---
    $lblOutput = New-Object System.Windows.Forms.Label
    $lblOutput.Text = '出力フォルダ'
    $lblOutput.Location = New-Object System.Drawing.Point(12, $y)
    $lblOutput.AutoSize = $true
    $form.Controls.Add($lblOutput)
    $y += 20

    $txtOutput = New-Object System.Windows.Forms.TextBox
    $txtOutput.Text = ''
    $txtOutput.Location = New-Object System.Drawing.Point(12, $y)
    $txtOutput.Size = New-Object System.Drawing.Size(460, 24)
    $form.Controls.Add($txtOutput)
    $c.TxtOutput = $txtOutput

    $btnBrowseOutput = New-Object System.Windows.Forms.Button
    $btnBrowseOutput.Text = '...'
    $btnBrowseOutput.Location = New-Object System.Drawing.Point(478, ($y - 1))
    $btnBrowseOutput.Size = New-Object System.Drawing.Size(50, 24)
    $btnBrowseOutput.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.SelectedPath = $stateRef.Controls.TxtOutput.Text
        if ($dlg.ShowDialog() -eq 'OK') { $stateRef.Controls.TxtOutput.Text = $dlg.SelectedPath }
    }.GetNewClosure())
    $form.Controls.Add($btnBrowseOutput)
    $c.BtnBrowseOutput = $btnBrowseOutput

    $btnOpenOutput = New-Object System.Windows.Forms.Button
    $btnOpenOutput.Text = '開く'
    $btnOpenOutput.Location = New-Object System.Drawing.Point(534, ($y - 1))
    $btnOpenOutput.Size = New-Object System.Drawing.Size(54, 24)
    $btnOpenOutput.Add_Click({
        $dir = $stateRef.Controls.TxtOutput.Text.Trim()
        if (Test-Path -LiteralPath $dir -PathType Container) {
            Invoke-Item -LiteralPath $dir
        }
    }.GetNewClosure())
    $form.Controls.Add($btnOpenOutput)
    $c.BtnOpenOutput = $btnOpenOutput
    $y += 36

    # --- Preset ---
    $lblPreset = New-Object System.Windows.Forms.Label
    $lblPreset.Text = 'プリセット'
    $lblPreset.Location = New-Object System.Drawing.Point(12, $y)
    $lblPreset.AutoSize = $true
    $form.Controls.Add($lblPreset)

    $cmbPreset = New-Object System.Windows.Forms.ComboBox
    $cmbPreset.DropDownStyle = 'DropDownList'
    $cmbPreset.Location = New-Object System.Drawing.Point(90, ($y - 2))
    $cmbPreset.Size = New-Object System.Drawing.Size(140, 24)
    $cmbPreset.Items.AddRange($presetNames)
    if ($cmbPreset.Items.Count -gt 0) {
        $cmbPreset.SelectedIndex = 0
    }
    $form.Controls.Add($cmbPreset)
    $c.CmbPreset = $cmbPreset

    # --- Collision policy ---
    $lblCollision = New-Object System.Windows.Forms.Label
    $lblCollision.Text = '衝突時:'
    $lblCollision.Location = New-Object System.Drawing.Point(260, $y)
    $lblCollision.AutoSize = $true
    $form.Controls.Add($lblCollision)

    $cmbCollision = New-Object System.Windows.Forms.ComboBox
    $cmbCollision.DropDownStyle = 'DropDownList'
    $cmbCollision.Location = New-Object System.Drawing.Point(320, ($y - 2))
    $cmbCollision.Size = New-Object System.Drawing.Size(120, 24)
    $cmbCollision.Items.AddRange(@('連番付与', 'スキップ', '上書き'))
    $cmbCollision.SelectedIndex = 0
    $form.Controls.Add($cmbCollision)
    $c.CmbCollision = $cmbCollision
    $y += 32

    $lblPresetRationale = New-Object System.Windows.Forms.Label
    $lblPresetRationale.Text = 'プリセットを選択すると、用途・根拠・注意点を表示します。'
    $lblPresetRationale.Location = New-Object System.Drawing.Point(12, $y)
    $lblPresetRationale.Size = New-Object System.Drawing.Size(576, 42)
    $lblPresetRationale.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $form.Controls.Add($lblPresetRationale)
    $c.LblPresetRationale = $lblPresetRationale
    $y += 46

    # --- Parameters grid ---
    $paramY = $y

    $lblTarget = New-Object System.Windows.Forms.Label
    $lblTarget.Text = 'ターゲット (LUFS)'
    $lblTarget.Location = New-Object System.Drawing.Point(12, $paramY)
    $lblTarget.AutoSize = $true
    $form.Controls.Add($lblTarget)

    $targetRange = MediaNormalizer.Core\Get-LoudnessParameterRange -Name 'Target'
    $numTarget = New-Object System.Windows.Forms.NumericUpDown
    $numTarget.Location = New-Object System.Drawing.Point(150, ($paramY - 2))
    $numTarget.Size = New-Object System.Drawing.Size(80, 24)
    $numTarget.Minimum = [decimal]$targetRange.Min; $numTarget.Maximum = [decimal]$targetRange.Max; $numTarget.DecimalPlaces = 1; $numTarget.Increment = 0.5
    $numTarget.Value = -16
    $form.Controls.Add($numTarget)
    $c.NumTarget = $numTarget

    $lblTP = New-Object System.Windows.Forms.Label
    $lblTP.Text = 'True Peak (dBTP)'
    $lblTP.Location = New-Object System.Drawing.Point(300, $paramY)
    $lblTP.AutoSize = $true
    $form.Controls.Add($lblTP)

    $truePeakRange = MediaNormalizer.Core\Get-LoudnessParameterRange -Name 'TruePeak'
    $numTP = New-Object System.Windows.Forms.NumericUpDown
    $numTP.Location = New-Object System.Drawing.Point(440, ($paramY - 2))
    $numTP.Size = New-Object System.Drawing.Size(80, 24)
    $numTP.Minimum = [decimal]$truePeakRange.Min; $numTP.Maximum = [decimal]$truePeakRange.Max; $numTP.DecimalPlaces = 1; $numTP.Increment = 0.1
    $numTP.Value = -1.0
    $form.Controls.Add($numTP)
    $c.NumTP = $numTP
    $paramY += 30

    $lblBR = New-Object System.Windows.Forms.Label
    $lblBR.Text = 'ビットレート'
    $lblBR.Location = New-Object System.Drawing.Point(12, $paramY)
    $lblBR.AutoSize = $true
    $form.Controls.Add($lblBR)

    $cmbBR = New-Object System.Windows.Forms.ComboBox
    $cmbBR.DropDownStyle = 'DropDownList'
    $cmbBR.Location = New-Object System.Drawing.Point(150, ($paramY - 2))
    $cmbBR.Size = New-Object System.Drawing.Size(80, 24)
    $cmbBR.Items.AddRange(@('128k', '192k', '256k', '320k'))
    $cmbBR.SelectedItem = '192k'
    $form.Controls.Add($cmbBR)
    $c.CmbBR = $cmbBR

    $lblSR = New-Object System.Windows.Forms.Label
    $lblSR.Text = 'サンプルレート'
    $lblSR.Location = New-Object System.Drawing.Point(300, $paramY)
    $lblSR.AutoSize = $true
    $form.Controls.Add($lblSR)

    $cmbSR = New-Object System.Windows.Forms.ComboBox
    $cmbSR.DropDownStyle = 'DropDownList'
    $cmbSR.Location = New-Object System.Drawing.Point(440, ($paramY - 2))
    $cmbSR.Size = New-Object System.Drawing.Size(80, 24)
    $cmbSR.Items.AddRange(@('44100', '48000'))
    $cmbSR.SelectedItem = '48000'
    $form.Controls.Add($cmbSR)
    $c.CmbSR = $cmbSR
    $paramY += 30

    $lblAudioFormat = New-Object System.Windows.Forms.Label
    $lblAudioFormat.Text = '音声出力形式'
    $lblAudioFormat.Location = New-Object System.Drawing.Point(12, $paramY)
    $lblAudioFormat.AutoSize = $true
    $form.Controls.Add($lblAudioFormat)

    $cmbAudioFormat = New-Object System.Windows.Forms.ComboBox
    $cmbAudioFormat.DropDownStyle = 'DropDownList'
    $cmbAudioFormat.Location = New-Object System.Drawing.Point(150, ($paramY - 2))
    $cmbAudioFormat.Size = New-Object System.Drawing.Size(100, 24)
    $cmbAudioFormat.Items.AddRange(@('mp3', 'm4a', 'aac', 'flac', 'wav', 'opus', 'ogg'))
    $cmbAudioFormat.SelectedItem = 'mp3'
    $form.Controls.Add($cmbAudioFormat)
    $c.CmbAudioFormat = $cmbAudioFormat
    $paramY += 36

    # --- Preset change handler ---
    $cmbPreset.Add_SelectedIndexChanged({
        $p = $stateRef.Presets[[string]$stateRef.Controls.CmbPreset.SelectedItem]
        if (-not $p) { return }
        $stateRef.Controls.NumTarget.Value = $p.Target
        $stateRef.Controls.NumTP.Value     = $p.TruePeak
        $stateRef.Controls.CmbBR.SelectedItem = $p.Bitrate
        $stateRef.Controls.CmbSR.SelectedItem = $p.SampleRate
        if ($stateRef.Controls.CmbAudioFormat.Items.Contains($p.OutputFormat)) {
            $stateRef.Controls.CmbAudioFormat.SelectedItem = $p.OutputFormat
        }
        $stateRef.Controls.LblPresetRationale.Text = & $getPresetRationaleTextFn -Preset $p
    }.GetNewClosure())

    # --- Mode toggle buttons ---
    $y = $paramY

    $chkAudio = New-Object System.Windows.Forms.CheckBox
    $chkAudio.Text = '音声正規化（音声/動画 → 選択形式）'
    $chkAudio.Location = New-Object System.Drawing.Point(12, $y)
    $chkAudio.Size = New-Object System.Drawing.Size(280, 30)
    $chkAudio.Appearance = 'Button'
    $chkAudio.TextAlign = 'MiddleCenter'
    $chkAudio.FlatStyle = 'Flat'
    $chkAudio.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
    $chkAudio.FlatAppearance.CheckedBackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $chkAudio.Checked = $false
    $chkAudio.Font = New-Object System.Drawing.Font('Yu Gothic UI', 9.5)
    $form.Controls.Add($chkAudio)
    $c.ChkAudio = $chkAudio

    $chkVideo = New-Object System.Windows.Forms.CheckBox
    $chkVideo.Text = '動画正規化（映像コピー / 音声のみ再エンコード）'
    $chkVideo.Location = New-Object System.Drawing.Point(300, $y)
    $chkVideo.Size = New-Object System.Drawing.Size(288, 30)
    $chkVideo.Appearance = 'Button'
    $chkVideo.TextAlign = 'MiddleCenter'
    $chkVideo.FlatStyle = 'Flat'
    $chkVideo.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
    $chkVideo.FlatAppearance.CheckedBackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $chkVideo.Checked = $false
    $chkVideo.Font = New-Object System.Drawing.Font('Yu Gothic UI', 9.5)
    $form.Controls.Add($chkVideo)
    $c.ChkVideo = $chkVideo
    $y += 36

    $chkRecurse = New-Object System.Windows.Forms.CheckBox
    $chkRecurse.Text = 'サブフォルダも再帰検索'
    $chkRecurse.Location = New-Object System.Drawing.Point(12, $y)
    $chkRecurse.Size = New-Object System.Drawing.Size(220, 24)
    $chkRecurse.Checked = $true
    $form.Controls.Add($chkRecurse)
    $c.ChkRecurse = $chkRecurse

    $chkPreserveHierarchy = New-Object System.Windows.Forms.CheckBox
    $chkPreserveHierarchy.Text = '出力に入力階層を維持'
    $chkPreserveHierarchy.Location = New-Object System.Drawing.Point(300, $y)
    $chkPreserveHierarchy.Size = New-Object System.Drawing.Size(220, 24)
    $chkPreserveHierarchy.Checked = $true
    $form.Controls.Add($chkPreserveHierarchy)
    $c.ChkPreserveHierarchy = $chkPreserveHierarchy
    $y += 26

    $chkAnalyzeOnly = New-Object System.Windows.Forms.CheckBox
    $chkAnalyzeOnly.Text = '解析のみ（メディア出力なし）'
    $chkAnalyzeOnly.Location = New-Object System.Drawing.Point(12, $y)
    $chkAnalyzeOnly.Size = New-Object System.Drawing.Size(260, 24)
    $form.Controls.Add($chkAnalyzeOnly)
    $c.ChkAnalyzeOnly = $chkAnalyzeOnly

    $chkSkipNormalized = New-Object System.Windows.Forms.CheckBox
    $chkSkipNormalized.Text = '目標±0.5 LU以内かつPeak上限内なら再圧縮しない'
    $chkSkipNormalized.Location = New-Object System.Drawing.Point(300, $y)
    $chkSkipNormalized.Size = New-Object System.Drawing.Size(288, 24)
    $chkSkipNormalized.Checked = $true
    $form.Controls.Add($chkSkipNormalized)
    $c.ChkSkipNormalized = $chkSkipNormalized
    $y += 30

    # --- Playback speed ---
    $lblSpeed = New-Object System.Windows.Forms.Label
    $lblSpeed.Text = '一括速度(%)'
    $lblSpeed.Location = New-Object System.Drawing.Point(12, ($y + 4))
    $lblSpeed.AutoSize = $true
    $form.Controls.Add($lblSpeed)

    $numSpeed = New-Object System.Windows.Forms.NumericUpDown
    $numSpeed.Location = New-Object System.Drawing.Point(100, ($y + 1))
    $numSpeed.Size = New-Object System.Drawing.Size(80, 24)
    $numSpeed.Minimum = 50
    $numSpeed.Maximum = 200
    $numSpeed.Increment = 5
    $numSpeed.Value = 100
    $form.Controls.Add($numSpeed)
    $c.NumSpeed = $numSpeed

    $btnApplySpeed = New-Object System.Windows.Forms.Button
    $btnApplySpeed.Text = '一覧へ適用'
    $btnApplySpeed.Location = New-Object System.Drawing.Point(190, $y)
    $btnApplySpeed.Size = New-Object System.Drawing.Size(100, 26)
    $form.Controls.Add($btnApplySpeed)
    $c.BtnApplySpeed = $btnApplySpeed
    $y += 34

    # --- File list section ---
    $btnScanFiles = New-Object System.Windows.Forms.Button
    $btnScanFiles.Text = '確認'
    $btnScanFiles.Location = New-Object System.Drawing.Point(12, $y)
    $btnScanFiles.Size = New-Object System.Drawing.Size(80, 26)
    $form.Controls.Add($btnScanFiles)
    $c.BtnScanFiles = $btnScanFiles

    $lblSummary = New-Object System.Windows.Forms.Label
    $lblSummary.Text = '[確認] を押してファイル一覧を取得'
    $lblSummary.Location = New-Object System.Drawing.Point(100, ($y + 4))
    $lblSummary.Size = New-Object System.Drawing.Size(488, 20)
    $form.Controls.Add($lblSummary)
    $c.LblSummary = $lblSummary
    $y += 28

    $dgv = New-Object System.Windows.Forms.DataGridView
    $dgv.Location = New-Object System.Drawing.Point(12, $y)
    $dgv.Size = New-Object System.Drawing.Size(576, 150)
    $dgv.AllowUserToAddRows = $false
    $dgv.AllowUserToDeleteRows = $false
    $dgv.AllowUserToResizeRows = $false
    $dgv.RowHeadersVisible = $false
    $dgv.SelectionMode = 'FullRowSelect'
    $dgv.BackgroundColor = [System.Drawing.SystemColors]::Window
    $dgv.DefaultCellStyle.SelectionBackColor = [System.Drawing.SystemColors]::Window
    $dgv.DefaultCellStyle.SelectionForeColor = [System.Drawing.SystemColors]::ControlText

    $colAudio = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colAudio.HeaderText = '音声'
    $colAudio.Width = 42
    $colAudio.Name = 'Audio'
    $dgv.Columns.Add($colAudio) | Out-Null

    $colVideo = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colVideo.HeaderText = '動画'
    $colVideo.Width = 42
    $colVideo.Name = 'Video'
    $dgv.Columns.Add($colVideo) | Out-Null

    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.HeaderText = 'ファイル名'
    $colName.Width = 190
    $colName.Name = 'FileName'
    $colName.ReadOnly = $true
    $dgv.Columns.Add($colName) | Out-Null

    $colExt = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colExt.HeaderText = '拡張子'
    $colExt.Width = 55
    $colExt.Name = 'Ext'
    $colExt.ReadOnly = $true
    $dgv.Columns.Add($colExt) | Out-Null

    $colSize = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colSize.HeaderText = 'サイズ'
    $colSize.Width = 70
    $colSize.Name = 'Size'
    $colSize.ReadOnly = $true
    $dgv.Columns.Add($colSize) | Out-Null

    $colDuration = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDuration.HeaderText = '長さ'
    $colDuration.Width = 62
    $colDuration.Name = 'Duration'
    $colDuration.ReadOnly = $true
    $colDuration.DefaultCellStyle.Alignment = 'MiddleRight'
    $dgv.Columns.Add($colDuration) | Out-Null

    $colSpeed = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colSpeed.HeaderText = '速度(%)'
    $colSpeed.Width = 70
    $colSpeed.Name = 'SpeedPercent'
    $colSpeed.DefaultCellStyle.Alignment = 'MiddleRight'
    $dgv.Columns.Add($colSpeed) | Out-Null

    # ソート操作後も実ファイル参照を保持するための非表示列
    $colFullName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colFullName.HeaderText = 'FullName'
    $colFullName.Name = 'FullName'
    $colFullName.ReadOnly = $true
    $colFullName.Visible = $false
    $dgv.Columns.Add($colFullName) | Out-Null

    $form.Controls.Add($dgv)
    $c.Dgv = $dgv
    $form.Add_DpiChanged({
        param($sender, $eventArgs)
        if ($stateRef.Controls.ContainsKey('Dgv')) {
            & $setFileGridColumnLayoutFn `
                -DataGridView $stateRef.Controls.Dgv `
                -Dpi ([int]$eventArgs.DeviceDpiNew)
        }
    }.GetNewClosure())
    $y += 156

    # --- Execute / Cancel buttons ---
    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = '実行'
    $btnRun.Location = New-Object System.Drawing.Point(12, $y)
    $btnRun.Size = New-Object System.Drawing.Size(456, 40)
    $btnRun.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $btnRun.ForeColor = [System.Drawing.Color]::White
    $btnRun.FlatStyle = 'Flat'
    $btnRun.Font = New-Object System.Drawing.Font('Yu Gothic UI', 11, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnRun)
    $c.BtnRun = $btnRun

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'キャンセル'
    $btnCancel.Location = New-Object System.Drawing.Point(472, $y)
    $btnCancel.Size = New-Object System.Drawing.Size(116, 40)
    $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
    $btnCancel.ForeColor = [System.Drawing.Color]::White
    $btnCancel.FlatStyle = 'Flat'
    $btnCancel.Font = New-Object System.Drawing.Font('Yu Gothic UI', 10, [System.Drawing.FontStyle]::Bold)
    $btnCancel.Enabled = $false
    $form.Controls.Add($btnCancel)
    $c.BtnCancel = $btnCancel
    $y += 50

    # --- Progress bar ---
    $lblProgressTitle = New-Object System.Windows.Forms.Label
    $lblProgressTitle.Text = '進捗'
    $lblProgressTitle.Location = New-Object System.Drawing.Point(12, $y)
    $lblProgressTitle.AutoSize = $true
    $form.Controls.Add($lblProgressTitle)
    $y += 18

    $pnlProgressBg = New-Object System.Windows.Forms.Panel
    $pnlProgressBg.Location = New-Object System.Drawing.Point(12, $y)
    $pnlProgressBg.Size = New-Object System.Drawing.Size(576, 26)
    $pnlProgressBg.BackColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
    $pnlProgressBg.BorderStyle = 'None'
    $form.Controls.Add($pnlProgressBg)
    $c.PnlProgressBg = $pnlProgressBg

    $pnlProgressFill = New-Object System.Windows.Forms.Panel
    $pnlProgressFill.Location = New-Object System.Drawing.Point(0, 0)
    $pnlProgressFill.Size = New-Object System.Drawing.Size(0, 26)
    $pnlProgressFill.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $pnlProgressBg.Controls.Add($pnlProgressFill)
    $c.PnlProgressFill = $pnlProgressFill

    $lblProgress = New-Object System.Windows.Forms.Label
    $lblProgress.Text = ''
    $lblProgress.Location = New-Object System.Drawing.Point(0, 0)
    $lblProgress.Size = New-Object System.Drawing.Size(576, 26)
    $lblProgress.TextAlign = 'MiddleCenter'
    $lblProgress.ForeColor = [System.Drawing.Color]::White
    $lblProgress.BackColor = [System.Drawing.Color]::Transparent
    $lblProgress.Font = New-Object System.Drawing.Font('Yu Gothic UI', 9, [System.Drawing.FontStyle]::Bold)
    $pnlProgressBg.Controls.Add($lblProgress)
    $lblProgress.BringToFront()
    $c.LblProgress = $lblProgress

    $y += 32

    # --- Log area ---
    $lblLog = New-Object System.Windows.Forms.Label
    $lblLog.Text = 'ログ'
    $lblLog.Location = New-Object System.Drawing.Point(12, $y)
    $lblLog.AutoSize = $true
    $form.Controls.Add($lblLog)
    $y += 18

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Multiline = $true
    $txtLog.ScrollBars = 'Vertical'
    $txtLog.ReadOnly = $true
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $txtLog.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $txtLog.Font = New-MonospaceFont -Size 9
    $txtLog.Location = New-Object System.Drawing.Point(12, $y)
    $txtLog.Size = New-Object System.Drawing.Size(576, 120)
    $form.Controls.Add($txtLog)
    $c.TxtLog = $txtLog

    # === Event handlers ===

    Register-InputDropTarget -State $stateRef -Control $form
    Register-InputDropTarget -State $stateRef -Control $txtInput
    Register-InputDropTarget -State $stateRef -Control $dgv

    $btnScanFiles.Add_Click({
        try {
            & $updateFileListFn -State $stateRef
        } catch {
            $errMsg = "確認処理で例外: $($_.Exception.Message)"
            if ($stateRef.Controls.LblSummary) {
                $stateRef.Controls.LblSummary.Text = "[エラー] $errMsg"
            }
            & $writeLogFn -State $stateRef -Message "[ERROR] $errMsg"
            & $writeLogFn -State $stateRef -Message "[ERROR] StackTrace: $($_.ScriptStackTrace)"
            & $writeLogBufferFn -State $stateRef
        }
    }.GetNewClosure())

    $btnApplySpeed.Add_Click({
        $value = [int]$stateRef.Controls.NumSpeed.Value
        foreach ($row in $stateRef.Controls.Dgv.Rows) {
            if ($row.IsNewRow) { continue }
            if ($row.Cells['SpeedPercent']) {
                $row.Cells['SpeedPercent'].Value = $value
            }
        }
    }.GetNewClosure())

    $chkAudio.Add_CheckedChanged({
        $ck = $stateRef.Controls.ChkAudio
        if ($ck.Checked) {
            $ck.ForeColor = [System.Drawing.Color]::White
        } else {
            $ck.ForeColor = [System.Drawing.SystemColors]::ControlText
        }
        if ($stateRef.ScanValid) { & $updateFileGridFn -State $stateRef }
    }.GetNewClosure())

    $chkVideo.Add_CheckedChanged({
        $ck = $stateRef.Controls.ChkVideo
        if ($ck.Checked) {
            $ck.ForeColor = [System.Drawing.Color]::White
        } else {
            $ck.ForeColor = [System.Drawing.SystemColors]::ControlText
        }
        if ($stateRef.ScanValid) { & $updateFileGridFn -State $stateRef }
    }.GetNewClosure())

    $chkRecurse.Add_CheckedChanged({
        if ($stateRef.ScanValid) { & $updateFileListFn -State $stateRef }
    }.GetNewClosure())

    $chkAnalyzeOnly.Add_CheckedChanged({
        $isAnalysis = $stateRef.Controls.ChkAnalyzeOnly.Checked
        $stateRef.Controls.BtnRun.Text = if ($isAnalysis) { '解析してレポート作成' } else { '実行' }
        $stateRef.Controls.ChkSkipNormalized.Enabled = -not $isAnalysis
    }.GetNewClosure())

    $txtInput.Add_TextChanged({
        if ($stateRef.ApplyingInputSelection) { return }
        $stateRef.InputSelectionPaths = @()
        $stateRef.Controls.Dgv.Rows.Clear()
        $stateRef.Controls.LblSummary.Text = '入力パスが変更されました。[確認] を押してください'
        $stateRef.ScanValid = $false
        $stateRef.CachedFiles = @()
    }.GetNewClosure())

    Register-MainFormEventHandlers -State $State -Form $form
    # === Apply persisted settings ===
    # フォーム生成後・ShowDialog 前に settings.json を反映する。
    $loadedSettings = Read-Settings
    $txtInput.Text  = $loadedSettings.Values.InputDir
    $txtOutput.Text = $loadedSettings.Values.OutputDir
    if ($cmbPreset.Items.Contains($loadedSettings.Values.LastPreset)) {
        $cmbPreset.SelectedItem = $loadedSettings.Values.LastPreset
    }
    $activePreset = $State.Presets[[string]$cmbPreset.SelectedItem]
    if ($activePreset) {
        $lblPresetRationale.Text = Get-PresetRationaleText -Preset $activePreset
        if ($cmbAudioFormat.Items.Contains($activePreset.OutputFormat)) {
            $cmbAudioFormat.SelectedItem = $activePreset.OutputFormat
        }
    }
    switch ($loadedSettings.Values.LastMode) {
        'audio' { $chkAudio.Checked = $true }
        'video' { $chkVideo.Checked = $true }
        'both'  { $chkAudio.Checked = $true; $chkVideo.Checked = $true }
    }

    # === Start log buffer flush timer ===
    Start-LogTimer -State $State

    foreach ($w in $loadedSettings.Warnings) { Write-Log -State $State -Message $w }

    # ThreadJob 自動導入失敗時の警告は Write-Log が使える今のタイミングで表示する
    if ($State.ThreadJobSetupWarning) { Write-Log -State $State -Message $State.ThreadJobSetupWarning }

    # SuspendLayout 中に設定した 96 DPI 基準の座標・サイズを、現在の DPI へ
    # まとめてスケールする。先に ResumeLayout すると、後から追加したコントロールが
    # 基準 DPI のまま残るため、この処理は全コントロール生成後に行う。
    $form.ResumeLayout($false)
    $form.PerformLayout()

    # CenterScreen と同じくカーソルがある画面を表示先として選び、その作業領域へ
    # サイズを制限して中央配置する。PrimaryScreen 固定では、小さい副画面上で
    # フォームが画面外へはみ出すため、表示先画面を明示する。
    $targetScreen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
    if ($null -eq $targetScreen) { $targetScreen = [System.Windows.Forms.Screen]::PrimaryScreen }
    if ($null -ne $targetScreen) {
        $bounds = Get-ConstrainedFormBounds -DesiredSize $form.Size -WorkingArea $targetScreen.WorkingArea
        $form.StartPosition = 'Manual'
        $form.Size = [System.Drawing.Size]::new($bounds.Width, $bounds.Height)
        $form.Location = [System.Drawing.Point]::new($bounds.X, $bounds.Y)
        $form.PerformLayout()
    }

    # 対象画面へ配置した後にHandleを生成し、その画面の実DPIで列幅を確定する。
    # FileName列のFill計算もHandle生成後ならDataGridViewの実幅を使用できる。
    $null = $form.Handle
    $null = $dgv.Handle
    Set-FileGridColumnLayout -DataGridView $dgv -Dpi ([int]$form.DeviceDpi)

    $State.Form = $form
    return $form
}

# === Show-MainForm ===
function Show-MainForm {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$State)
    Initialize-UiAssemblies
    if (-not $State.PSObject.Properties['Form'] -or $null -eq $State.Form) {
        throw 'State.Form is null. Call New-MainForm first.'
    }
    if ($State.Form -isnot [System.Windows.Forms.Form]) {
        throw 'State.Form is not a System.Windows.Forms.Form instance.'
    }
    if ($State.Form.IsDisposed) {
        throw 'State.Form has been disposed.'
    }
    # ランチャー(MediaNormalizer.exe)は子pwshをCreateNoWindow=trueで起動する。この場合
    # STARTUPINFOのwShowWindowにSW_HIDEが設定され、ShowDialog()内部のウィンドウ表示が
    # 既定表示状態を継承して非表示のまま作成されることがある(実機で再現・確認済み)。
    # Shownイベントで明示的にSW_SHOWを発行して上書きする。
    $stateRef = $State
    $State.Form.Add_Shown({
        [void][Native.Win32]::ShowWindow($stateRef.Form.Handle, 5)  # SW_SHOW
    }.GetNewClosure())
    [void]$State.Form.ShowDialog()
}

# GetNewClosureを使う遅延callbackはprivate helperのScriptBlockを明示的にcaptureする。
# これにより.NET delegate経由でも内部関数を解決でき、製品public surfaceをGUI
# entrypoint 4関数へ限定できる。private helperのunit testはInModuleScopeを使う。
Export-ModuleMember -Function Initialize-UiState, New-MainForm, Set-ConsoleWindowHidden, Show-MainForm
