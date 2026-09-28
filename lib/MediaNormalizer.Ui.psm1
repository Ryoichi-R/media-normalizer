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




Import-Module (Join-Path $PSScriptRoot 'MediaNormalizer.UiLogic.psm1') -Force -Scope Local -DisableNameChecking

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


# === Settings 永続化 ===
# Read-Settings/Save-Settings は GUI (Windows 確定) からも、Linux ランナーを
# 含むユニットテストからも呼ばれる。-SettingsPath を明示注入した呼び出しは
# Get-SettingsPath や旧自動フォルダのプラットフォーム依存関数を呼ばない。
# v2 以降は新規起動時の入力・出力を空欄にし、保存済みの値だけを復元する。














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
    Add-Member -InputObject $State -NotePropertyName 'SettingsExtensionFields' -NotePropertyValue ([ordered]@{}) -Force
    Add-Member -InputObject $State -NotePropertyName 'InputSelectionPaths' -NotePropertyValue @() -Force
    Add-Member -InputObject $State -NotePropertyName 'ApplyingInputSelection' -NotePropertyValue $false -Force
    Add-Member -InputObject $State -NotePropertyName 'FileRowState' -NotePropertyValue @{} -Force
    Add-Member -InputObject $State -NotePropertyName 'InputScopeKey' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'FileGridUpdateDepth' -NotePropertyValue 0 -Force
    Add-Member -InputObject $State -NotePropertyName 'FileGridModeRefreshPending' -NotePropertyValue $false -Force
    Add-Member -InputObject $State -NotePropertyName 'OperationId' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'LastOperationId' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'OperationState' -NotePropertyValue 'Idle' -Force
    Add-Member -InputObject $State -NotePropertyName 'OperationStartedAt' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'WorkerHandle' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'ActiveChildPid' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'CurrentPhase' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'LastHeartbeatAt' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'LastOutputGrowthAt' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'CompletionHandled' -NotePropertyValue $false -Force
    Add-Member -InputObject $State -NotePropertyName 'FinalizationStarted' -NotePropertyValue $false -Force
    Add-Member -InputObject $State -NotePropertyName 'LastCompletionReason' -NotePropertyValue 'None' -Force
    Add-Member -InputObject $State -NotePropertyName 'OperationCancellation' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'OperationEvents' -NotePropertyValue $null -Force
    Add-Member -InputObject $State -NotePropertyName 'OrphanTimeoutSeconds' -NotePropertyValue 15 -Force

    # HasThreadJob は Core State 既存。Initialize-ThreadJob の結果を代入する。
    $State.HasThreadJob = Initialize-ThreadJob -State $State

    return $State
}

# === ログ ===








# === 進捗 ===






# === ファイル一覧 ===
















$script:UiNormalizeWorker = {
    param($coreModulePath, $probeModulePath, $progressModulePath, $operationId, $dto, $cancellationSource, $events)
    $ErrorActionPreference = 'Stop'
    Import-Module $coreModulePath -Force
    Import-Module $probeModulePath -Force
    Import-Module $progressModulePath -Force
    $coreState = New-MediaNormalizerState
    $coreState.DurationMap = @{}
    foreach ($entry in $dto.DurationMap.GetEnumerator()) { $coreState.DurationMap[[string]$entry.Key] = [double]$entry.Value }
    $logger = {
        param($message)
        $text = [string]$message
        [void]$events.Enqueue([pscustomobject]@{ Type = 'Log'; OperationId = $operationId; Message = $text; At = [DateTime]::UtcNow })
        if ($text -match '\[DEBUG\].*ログ増加') {
            [void]$events.Enqueue([pscustomobject]@{ Type = 'OutputGrowth'; OperationId = $operationId; At = [DateTime]::UtcNow })
        }
        if ($text -match '\[DEBUG\]') {
            [void]$events.Enqueue([pscustomobject]@{ Type = 'Heartbeat'; OperationId = $operationId; At = [DateTime]::UtcNow })
        }
    }.GetNewClosure()
    $lastChildPid = $null
    $overallTotal = if ($dto.PSObject.Properties['TotalItems']) { [int]$dto.TotalItems } else { 0 }
    if ($overallTotal -le 0) {
        $overallTotal = [int](@($dto.Stages | ForEach-Object { @($_.TargetFiles).Count } | Measure-Object -Sum).Sum)
    }
    $progressContext = [pscustomobject]@{ StageOffset = 0; OverallTotal = $overallTotal }
    $progress = {
        param($current, $total)
        $stageCurrent = [math]::Max(0, [int]$current - [int]$progressContext.StageOffset)
        $overallCurrent = [math]::Min([int]$progressContext.OverallTotal,
            [int]$progressContext.StageOffset + $stageCurrent)
        $childPid = if ($coreState.RunningProcess) { [int]$coreState.RunningProcess.Id } else { $null }
        if ($childPid -ne $lastChildPid) {
            if ($lastChildPid) {
                [void]$events.Enqueue([pscustomobject]@{
                        Type = 'ChildExited'; OperationId = $operationId; ChildPid = $lastChildPid
                        At = [DateTime]::UtcNow
                    })
            }
            if ($childPid) {
                [void]$events.Enqueue([pscustomobject]@{
                        Type = 'ChildStarted'; OperationId = $operationId; ChildPid = $childPid
                        Phase = [string]$coreState.CurrentPhase; At = [DateTime]::UtcNow
                    })
            }
            $lastChildPid = $childPid
        }
        [void]$events.Enqueue([pscustomobject]@{
                Type = 'Progress'; OperationId = $operationId; Current = $overallCurrent
                Total = [int]$progressContext.OverallTotal
                Phase = [string]$coreState.CurrentPhase; PhasePercent = [double]$coreState.PhaseProgressPercent
                ChildPid = $childPid
                At = [DateTime]::UtcNow
            })
    }.GetNewClosure()
    $extensions = { @{ Audio = @(Get-AudioInputExtensions); Video = @(Get-VideoInputExtensions) } }
    $stageResults = [Collections.Generic.List[object]]::new()
    function Test-StageReportFailure {
        param([Parameter(Mandatory)]$Result)
        if ($Result -is [System.Collections.IDictionary]) {
            return ($Result.Contains('ReportSucceeded') -and $Result.ReportSucceeded -eq $false)
        }
        return ($Result.PSObject.Properties['ReportSucceeded'] -and -not [bool]$Result.ReportSucceeded)
    }
    $stageOffset = 0
    try {
        foreach ($stage in @($dto.Stages)) {
            if ($cancellationSource.Token.IsCancellationRequested) { break }
            $stageItemCount = @($stage.TargetFiles).Count
            $progressContext.StageOffset = $stageOffset
            $stageResult = Invoke-Normalize `
                -State $coreState -Mode ([string]$stage.Mode) `
                -InputDir ([string]$dto.InputDir) -InputPaths @($dto.InputPaths) `
                -OutputDir ([string]$dto.OutputDir) -Target ([double]$dto.Target) `
                -TruePeak ([double]$dto.TruePeak) -Bitrate ([string]$dto.Bitrate) `
                -SampleRate ([string]$dto.SampleRate) -CollisionPolicy ([string]$dto.CollisionPolicy) `
                -TargetFiles @($stage.TargetFiles | ForEach-Object { [IO.FileInfo]$_ }) `
                -Logger $logger -Progress $progress -GetTargetExtensions $extensions `
                -SpeedPercentByPath $dto.SpeedPercentByPath -AudioOutputFormat ([string]$dto.AudioOutputFormat) `
                -AnalyzeOnly:([bool]$dto.AnalyzeOnly) -SkipIfNormalized:([bool]$dto.SkipIfNormalized) `
                -Recurse:([bool]$dto.Recurse) -PreserveHierarchy:([bool]$dto.PreserveHierarchy) `
                -ReportPath ([string]$dto.ReportPath) -ReportMode ([string]$dto.ReportMode) `
                -CancellationToken $cancellationSource.Token
            $stageResults.Add($stageResult)
            $stageOffset += $stageItemCount
            if ([int]$stageResult.Fail -gt 0 -or [int]$stageResult.Cancelled -gt 0 -or
                (Test-StageReportFailure -Result $stageResult)) { break }
        }
        $reason = if ($cancellationSource.Token.IsCancellationRequested) { 'Cancelled' }
        elseif (@($stageResults | Where-Object {
                $_.Fail -gt 0 -or
                    (Test-StageReportFailure -Result $_)
                }).Count -gt 0) { 'Failed' }
        else { 'Succeeded' }
        [void]$events.Enqueue([pscustomobject]@{ Type = 'Completed'; OperationId = $operationId; Reason = $reason; Result = $stageResults.ToArray(); At = [DateTime]::UtcNow })
    } catch {
        [void]$events.Enqueue([pscustomobject]@{ Type = 'Completed'; OperationId = $operationId; Reason = 'Failed'; Detail = $_.Exception.Message; At = [DateTime]::UtcNow })
    }
}

function Start-UiOperation {
    param([Parameter(Mandatory)][pscustomobject]$State, [Parameter(Mandatory)][pscustomobject]$Dto)
    if ([string]$State.OperationState -ne 'Idle') { return $false }
    $operationId = [guid]::NewGuid().ToString('N')
    $State.OperationId = $operationId
    $State.LastOperationId = $operationId
    $State.OperationStartedAt = Get-Date
    $State.CompletionHandled = $false
    $State.FinalizationStarted = $false
    $State.LastCompletionReason = 'None'
    $State.OperationEvents = [Collections.Concurrent.ConcurrentQueue[object]]::new()
    $State.OperationCancellation = [Threading.CancellationTokenSource]::new()
    Write-UiOperationLog -State $State -Message 'operation開始'
    try { Write-LogBuffer -State $State } catch { }
    Set-UiOperationState -State $State -OperationState 'Starting'
    $runspace = $null
    $powerShell = $null
    try {
        $runspace = [RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = 'STA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()
        $powerShell = [PowerShell]::Create()
        $powerShell.Runspace = $runspace
        [void]$powerShell.AddScript($script:UiNormalizeWorker)
        [void]$powerShell.AddArgument((Join-Path $PSScriptRoot 'MediaNormalizer.Core.psm1'))
        [void]$powerShell.AddArgument((Join-Path $PSScriptRoot 'MediaNormalizer.Probe.psm1'))
        [void]$powerShell.AddArgument((Join-Path $PSScriptRoot 'MediaNormalizer.Progress.psm1'))
        [void]$powerShell.AddArgument($operationId)
        [void]$powerShell.AddArgument($Dto)
        [void]$powerShell.AddArgument($State.OperationCancellation)
        [void]$powerShell.AddArgument($State.OperationEvents)
        $async = $powerShell.BeginInvoke()
        $State.WorkerHandle = [pscustomobject]@{ PowerShell = $powerShell; Runspace = $runspace; Async = $async; OperationId = $operationId }
        Set-UiOperationState -State $State -OperationState 'Running'
        return $true
    } catch {
        if ($powerShell) { try { $powerShell.Dispose() } catch { } }
        if ($runspace) { try { $runspace.Close() } catch { }; try { $runspace.Dispose() } catch { } }
        Complete-UiOperation -State $State -OperationId $operationId -Reason 'Failed' -Detail "worker起動失敗: $($_.Exception.Message)" | Out-Null
        return $false
    }
}

function Receive-UiOperationEvents {
    param([Parameter(Mandatory)][pscustomobject]$State)
    if (-not $State.OperationEvents -or -not $State.OperationId) { return }
    $events = $State.OperationEvents
    $event = $null
    while ($events.TryDequeue([ref]$event)) {
        if ([string]$event.OperationId -ne [string]$State.OperationId) { continue }
        switch ([string]$event.Type) {
            'Log' { Write-UiOperationLog -State $State -Message ([string]$event.Message) }
            'Heartbeat' { $State.LastHeartbeatAt = [datetime]$event.At }
            'OutputGrowth' { $State.LastOutputGrowthAt = [datetime]$event.At }
            'ChildStarted' {
                $State.ActiveChildPid = [int]$event.ChildPid
                Write-UiOperationLog -State $State -Message (
                    'child開始 pid={0} phase={1}' -f $event.ChildPid, $event.Phase)
            }
            'ChildExited' {
                if ([int]$State.ActiveChildPid -eq [int]$event.ChildPid) {
                    $State.ActiveChildPid = $null
                }
                Write-UiOperationLog -State $State -Message ('child終了 pid={0}' -f $event.ChildPid)
            }
            'Progress' {
                $nextPhase = [string]$event.Phase
                if ($nextPhase -and $nextPhase -ne [string]$State.CurrentPhase) {
                    Write-UiOperationLog -State $State -Message ('phase={0}' -f $nextPhase)
                }
                $State.CurrentPhase = $nextPhase
                $State.ActiveChildPid = $event.ChildPid
                $State.LastHeartbeatAt = [datetime]$event.At
                if ($State.Controls.ContainsKey('PnlProgressBg')) {
                    Update-Progress -State $State -Current ([int]$event.Current) -Total ([int]$event.Total)
                }
            }
            'Completed' {
                $detail = if ($event.PSObject.Properties['Detail']) { [string]$event.Detail } else { $null }
                Complete-UiOperation -State $State -OperationId ([string]$event.OperationId) `
                    -Reason ([string]$event.Reason) -Detail $detail | Out-Null
            }
        }
    }
    if ($State.WorkerHandle -and $State.WorkerHandle.Async.IsCompleted -and -not $State.CompletionHandled) {
        try { $null = @($State.WorkerHandle.PowerShell.EndInvoke($State.WorkerHandle.Async)) } catch {
            Complete-UiOperation -State $State -OperationId ([string]$State.OperationId) -Reason 'Failed' `
                -Detail "worker完了取得失敗: $($_.Exception.Message)" | Out-Null
        }
    }
    if ($State.OperationState -ne 'Idle' -and $State.OperationStartedAt) {
        $lastSignal = @($State.LastHeartbeatAt, $State.LastOutputGrowthAt, $State.OperationStartedAt) |
            Where-Object { $_ } | ForEach-Object { [datetime]$_ } | Sort-Object | Select-Object -Last 1
        if ($lastSignal -and ((Get-Date) - $lastSignal).TotalSeconds -ge [double]$State.OrphanTimeoutSeconds -and
            (-not $State.WorkerHandle -or $State.WorkerHandle.Async.IsCompleted) -and
            -not (Test-UiActiveChildProcess -State $State) -and
            $events.IsEmpty) {
            Complete-UiOperation -State $State -OperationId ([string]$State.OperationId) -Reason 'Orphaned' `
                -Detail 'worker、外部処理、completion通知が失われたため孤立状態として復帰しました。' | Out-Null
        }
    }
}

















function Clear-FileListWithError {
    param([Parameter(Mandatory)][pscustomobject]$State, [string]$Message)
    Initialize-FileGridSelectionState -State $State | Out-Null
    Stop-PendingProbeJobs -State $State
    $State.Controls.Dgv.Rows.Clear()
    $State.Controls.LblSummary.Text = "[エラー] $Message"
    $State.ScanValid = $false
    $State.CachedFiles = @()
    $State.FileRowState = @{}
    $State.InputScopeKey = $null
    if ($State.PSObject.Properties['ProbeSummary']) {
        $State.ProbeSummary = $null
    } else {
        Add-Member -InputObject $State -NotePropertyName 'ProbeSummary' -NotePropertyValue $null
    }
    Write-Log -State $State -Message "[ERROR] $Message"
}

function Stop-PendingProbeJobs {
    param([Parameter(Mandatory)][pscustomobject]$State)
    if ($State.PSObject.Properties['ProbeTimer'] -and $State.ProbeTimer) {
        try { $State.ProbeTimer.Stop() } catch { }
        try { $State.ProbeTimer.Dispose() } catch { }
        $State.ProbeTimer = $null
    }
    if ($State.PSObject.Properties['PendingProbeJobs'] -and
        $State.PendingProbeJobs -and $State.PendingProbeJobs.Count -gt 0) {
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [AllowNull()][string]$InputScopeKey
    )

    Initialize-FileGridSelectionState -State $State | Out-Null
    $hasExplicitScope = $PSBoundParameters.ContainsKey('InputScopeKey')
    $scopeChanged = $hasExplicitScope -and
        -not [string]::Equals([string]$State.InputScopeKey, [string]$InputScopeKey, [StringComparison]::Ordinal)
    $dgv = $State.Controls.Dgv
    if ($dgv.PSObject.Methods['EndEdit']) { [void]$dgv.EndEdit() }
    if ($scopeChanged) {
        $State.FileRowState = @{}
        $State.InputScopeKey = $InputScopeKey
    } else {
        Save-FileGridSelectionStateFromGrid -State $State
        if ($hasExplicitScope) { $State.InputScopeKey = $InputScopeKey }
    }

    $State.FileGridUpdateDepth++
    $completed = $false
    try {
        Stop-PendingProbeJobs -State $State
        $dgv.Rows.Clear()
        $State.DurationMap = @{}
        $State.FileIndex = @{}            # FullName -> FileInfo の O(1) 索引
        $State.FullNameToRow = @{}        # FullName -> DataGridViewRow の O(1) 索引（ProbeTimer 用）
        $formatMap = Get-InputFormatExtensions
        $audioMode = $false
        $videoMode = $false
        if ($State.Controls.ContainsKey('ChkAudio')) { $audioMode = [bool]$State.Controls.ChkAudio.Checked }
        if ($State.Controls.ContainsKey('ChkVideo')) { $videoMode = [bool]$State.Controls.ChkVideo.Checked }
        $fileCount = @($State.CachedFiles).Count
        $useAsync = [bool]$State.HasThreadJob
        $defaultSpeed = 100
        if ($State.Controls.ContainsKey('NumSpeed')) { $defaultSpeed = [int]$State.Controls.NumSpeed.Value }

        for ($i = 0; $i -lt $fileCount; $i++) {
            $f = $State.CachedFiles[$i]
            $key = Get-FileRowStateKey -Path $f.FullName
            $ext = $f.Extension.ToLowerInvariant()
            $supportsAudio = $ext -in $formatMap.Audio
            $supportsVideo = $ext -in $formatMap.Video
            $saved = if ($State.FileRowState.ContainsKey($key)) { $State.FileRowState[$key] } else { $null }
            $rowState = if ($saved) {
                [pscustomobject]@{
                    SupportsAudio = $supportsAudio
                    SupportsVideo = $supportsVideo
                    DesiredAudio  = [bool]$saved.DesiredAudio
                    DesiredVideo  = [bool]$saved.DesiredVideo
                    SpeedPercent  = $saved.SpeedPercent
                }
            } else {
                [pscustomobject]@{
                    SupportsAudio = $supportsAudio
                    SupportsVideo = $supportsVideo
                    DesiredAudio  = $supportsAudio
                    DesiredVideo  = $supportsVideo
                    SpeedPercent  = $defaultSpeed
                }
            }
            $State.FileRowState[$key] = $rowState
            $chkA = $audioMode -and $supportsAudio -and $rowState.DesiredAudio
            $chkV = $videoMode -and $supportsVideo -and $rowState.DesiredVideo

            $State.FileIndex[$f.FullName] = $f
            $initialDurStr = if ($useAsync) { '取得中...' } else {
                $dur = MediaNormalizer.Probe\Get-MediaDuration -State $State -FilePath $f.FullName
                $State.DurationMap[$f.FullName] = $dur
                MediaNormalizer.Probe\Format-Duration -Seconds $dur
            }

            $sizeStr = MediaNormalizer.Probe\Format-FileSize -Bytes $f.Length
            $displayName = $f.Name
            $inputRoot = $State.Controls.TxtInput.Text.Trim()
            if (Test-Path -LiteralPath $inputRoot -PathType Container) {
                $relativeName = MediaNormalizer.Core\Get-RelativeMediaPath `
                    -BasePath $inputRoot `
                    -Path $f.FullName
                if ($relativeName) { $displayName = $relativeName }
            }
            $rowIdx = $dgv.Rows.Add(
                $chkA, $chkV, $displayName, $ext, $sizeStr, $initialDurStr,
                $rowState.SpeedPercent, $f.FullName)
            $row = $dgv.Rows[$rowIdx]
            $State.FullNameToRow[$f.FullName] = $row
            $row.Cells['Audio'].ReadOnly = -not ($audioMode -and $supportsAudio)
            $row.Cells['Video'].ReadOnly = -not ($videoMode -and $supportsVideo)
            if (-not $supportsAudio -and -not $supportsVideo) {
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
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
                        -ScriptBlock ([scriptblock]::Create($script:ProbeBatchScriptBlock.ToString())) `
                        -ArgumentList ([scriptblock]::Create($State.ProbeScript.ToString())), @($batch) `
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
                    }
                }
            }
        }

        $State.ProbeSummary = $null
        if ($useAsync -and $State.PendingProbeJobs.Count -gt 0) {
            if ($State.Controls.BtnRun) { $State.Controls.BtnRun.Enabled = $false }
            Start-ProbeTimer -State $State
        } else {
            if ($State.Controls.BtnRun -and
                (-not $State.PSObject.Properties['OperationState'] -or $State.OperationState -eq 'Idle')) {
                $State.Controls.BtnRun.Enabled = $true
            }
        }
        $completed = $true
    } finally {
        $State.FileGridUpdateDepth = [math]::Max(0, [int]$State.FileGridUpdateDepth - 1)
        if (-not $completed) { $State.FileGridModeRefreshPending = $false }
    }

    if ($completed -and $State.FileGridUpdateDepth -eq 0) {
        if ($State.FileGridModeRefreshPending) {
            $State.FileGridModeRefreshPending = $false
            Update-FileGridModeState -State $State
        } else {
            Update-FileGridSummary -State $State
        }
    }
}

function Update-FileGridModeState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$State)

    Initialize-FileGridSelectionState -State $State | Out-Null
    if ($State.FileGridUpdateDepth -gt 0) {
        $State.FileGridModeRefreshPending = $true
        return
    }

    $State.FileGridUpdateDepth++
    $completed = $false
    try {
        $formatMap = Get-InputFormatExtensions
        $audioMode = [bool]$State.Controls.ChkAudio.Checked
        $videoMode = [bool]$State.Controls.ChkVideo.Checked
        foreach ($row in $State.Controls.Dgv.Rows) {
            if ($row.PSObject.Properties['IsNewRow'] -and $row.IsNewRow) { continue }
            $fullName = [string]$row.Cells['FullName'].Value
            if ([string]::IsNullOrWhiteSpace($fullName)) { continue }
            $key = Get-FileRowStateKey -Path $fullName
            $saved = if ($State.FileRowState.ContainsKey($key)) { $State.FileRowState[$key] } else { $null }
            $file = if ($State.PSObject.Properties['FileIndex'] -and $State.FileIndex.ContainsKey($fullName)) {
                $State.FileIndex[$fullName]
            } else { $null }
            $ext = if ($file) { $file.Extension.ToLowerInvariant() } else { [IO.Path]::GetExtension($fullName).ToLowerInvariant() }
            $supportsAudio = if ($saved) { [bool]$saved.SupportsAudio } else { $ext -in $formatMap.Audio }
            $supportsVideo = if ($saved) { [bool]$saved.SupportsVideo } else { $ext -in $formatMap.Video }
            $desiredAudio = if ($saved) { [bool]$saved.DesiredAudio } else { $supportsAudio }
            $desiredVideo = if ($saved) { [bool]$saved.DesiredVideo } else { $supportsVideo }
            $speed = if ($saved) { $saved.SpeedPercent } else { 100 }
            $State.FileRowState[$key] = [pscustomobject]@{
                SupportsAudio = $supportsAudio
                SupportsVideo = $supportsVideo
                DesiredAudio  = $desiredAudio
                DesiredVideo  = $desiredVideo
                SpeedPercent  = $speed
            }
            $row.Cells['Audio'].Value = $audioMode -and $supportsAudio -and $desiredAudio
            $row.Cells['Video'].Value = $videoMode -and $supportsVideo -and $desiredVideo
            $row.Cells['Audio'].ReadOnly = -not ($audioMode -and $supportsAudio)
            $row.Cells['Video'].ReadOnly = -not ($videoMode -and $supportsVideo)
            if (-not $supportsAudio -and -not $supportsVideo) {
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
            } else {
                $row.DefaultCellStyle.ForeColor = [System.Drawing.SystemColors]::ControlText
            }
        }
        $completed = $true
    } finally {
        $State.FileGridUpdateDepth = [math]::Max(0, [int]$State.FileGridUpdateDepth - 1)
    }
    if ($completed -and $State.FileGridUpdateDepth -eq 0) {
        Update-FileGridSummary -State $State
    }
}









function Receive-ProbeJobResult {
    param([Parameter(Mandatory)]$Job)

    return @(Receive-Job -Job $Job -ErrorAction Stop)
}

function Update-PendingProbeJobs {
    param([Parameter(Mandatory)][pscustomobject]$State)

    $dgv = $State.Controls.Dgv
    $completedIds = @()
    foreach ($jobId in @($State.PendingProbeJobs.Keys)) {
        $job = Get-Job -Id $jobId -ErrorAction SilentlyContinue
        if (-not $job) { $completedIds += $jobId; continue }
        if ($job.State -in @('Completed', 'Failed', 'Stopped')) {
            $expectedPaths = @($State.PendingProbeJobs[$jobId])
            $results = @()
            if ($job.State -eq 'Completed') {
                try {
                    $results = @(Receive-ProbeJobResult -Job $job)
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
                $State.DurationMap[$fullName] = $dur
                if ($State.FullNameToRow.ContainsKey($fullName)) {
                    $row = $State.FullNameToRow[$fullName]
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
    foreach ($id in $completedIds) { [void]$State.PendingProbeJobs.Remove($id) }

    if ($State.PendingProbeJobs.Count -eq 0) {
        try { $State.ProbeTimer.Stop() } catch { }
        try { $State.ProbeTimer.Dispose() } catch { }
        $State.ProbeTimer = $null

        $scanValid = -not $State.PSObject.Properties['ScanValid'] -or [bool]$State.ScanValid
        $hasSnapshotInputs = $State.PSObject.Properties['FileIndex'] -and
            $State.Controls.ContainsKey('ChkAudio') -and $State.Controls.ContainsKey('ChkVideo')
        if ($scanValid -and $hasSnapshotInputs) {
            Update-FileGridSummary -State $State
        }
        $State.ProbeSummary = $null

        # プローブ完了で「実行」を再有効化。ただし実行中（CancelRequested を待っている状態）は触らない
        if ($scanValid -and $State.Controls.BtnRun -and
            (-not $State.PSObject.Properties['OperationState'] -or $State.OperationState -eq 'Idle')) {
            $State.Controls.BtnRun.Enabled = $true
        }
    }
}

function Start-ProbeTimer {
    param([Parameter(Mandatory)][pscustomobject]$State)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $stateRef = $State
    [scriptblock]$updatePendingProbeJobsFn = ${function:Update-PendingProbeJobs}
    $timer.Add_Tick({ & $updatePendingProbeJobsFn -State $stateRef }.GetNewClosure())
    $State.ProbeTimer = $timer
    $timer.Start()
}

function Update-FileList {
    param([Parameter(Mandatory)][pscustomobject]$State)
    Initialize-FileGridSelectionState -State $State | Out-Null
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

    $normalizedSelectionPaths = @($selectedPaths | ForEach-Object { [IO.Path]::GetFullPath($_) })
    $State.InputSelectionPaths = $normalizedSelectionPaths
    $scopeKey = Get-InputScopeKey -Paths $normalizedSelectionPaths
    $State.ScanValid = $true
    $State.CachedFiles = @($files)
    Update-FileGrid -State $State -InputScopeKey $scopeKey
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
    $pumpSb     = { }

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

function Register-FileGridSelectionEventHandlers {
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)]$DataGridView
    )

    $stateRef = $State
    $dgv = $DataGridView
    [scriptblock]$saveSelectionFn = ${function:Save-FileGridSelectionStateFromGrid}
    [scriptblock]$updateSummaryFn = ${function:Update-FileGridSummary}
    $dgv.Add_CurrentCellDirtyStateChanged({
        if (-not $dgv.IsCurrentCellDirty -or $null -eq $dgv.CurrentCell) { return }
        $columnName = [string]$dgv.Columns[$dgv.CurrentCell.ColumnIndex].Name
        if ($columnName -in @('Audio', 'Video')) {
            [void]$dgv.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    }.GetNewClosure())
    $dgv.Add_CellValueChanged({
        param($sender, $eventArgs)
        if ($stateRef.FileGridUpdateDepth -gt 0 -or $eventArgs.RowIndex -lt 0) { return }
        $columnName = [string]$dgv.Columns[$eventArgs.ColumnIndex].Name
        if ($columnName -notin @('Audio', 'Video', 'SpeedPercent')) { return }
        & $saveSelectionFn -State $stateRef
        if ($columnName -in @('Audio', 'Video')) {
            & $updateSummaryFn -State $stateRef
        }
    }.GetNewClosure())
    $dgv.Add_CellEndEdit({
        param($sender, $eventArgs)
        if ($stateRef.FileGridUpdateDepth -gt 0 -or $eventArgs.RowIndex -lt 0) { return }
        if ([string]$dgv.Columns[$eventArgs.ColumnIndex].Name -eq 'SpeedPercent') {
            & $saveSelectionFn -State $stateRef
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
    [scriptblock]$getFileGridSelectionSnapshotFn = ${function:Get-FileGridSelectionSnapshot}
    [scriptblock]$getSpeedPercentMapFromGridFn = ${function:Get-SpeedPercentMapFromGrid}
    [scriptblock]$resetProgressFn = ${function:Reset-Progress}
    [scriptblock]$saveFileGridSelectionStateFn = ${function:Save-FileGridSelectionStateFromGrid}
    [scriptblock]$saveSettingsFn = ${function:Save-Settings}
    [scriptblock]$requestCancellationFn = ${function:Request-UiOperationCancellation}
    [scriptblock]$startOperationFn = ${function:Start-UiOperation}
    [scriptblock]$stopPendingProbeJobsFn = ${function:Stop-PendingProbeJobs}
    [scriptblock]$testPresetConfigurationMatchesFn = ${function:Test-PresetConfigurationMatches}
    [scriptblock]$updateProgressFn = ${function:Update-Progress}
    [scriptblock]$writeLogFn = ${function:Write-Log}
    [scriptblock]$writeLogBufferFn = ${function:Write-LogBuffer}

    $c.BtnCancel.Add_Click({
        & $requestCancellationFn -State $stateRef | Out-Null
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

        & $saveFileGridSelectionStateFn -State $stateRef
        if (-not $stateRef.ScanValid -or $cc.Dgv.Rows.Count -eq 0) {
            & $writeLogFn -State $stateRef -Message '[ERROR] 実行前に [確認] を押して対象をスキャンしてください。未確認のまま処理は開始しません。'
            return
        }
        if (-not $cc.ChkAudio.Checked -and -not $cc.ChkVideo.Checked) {
            & $writeLogFn -State $stateRef -Message '[ERROR] 処理モードが選択されていません。少なくとも1つチェックしてください。'
            return
        }
        $snapshot = & $getFileGridSelectionSnapshotFn -State $stateRef
        if ($snapshot.Errors.Count -gt 0) {
            & $writeLogFn -State $stateRef -Message '[ERROR] ファイル一覧の状態が不整合です。実行を中止しました。'
            foreach ($err in $snapshot.Errors) {
                & $writeLogFn -State $stateRef -Message "        $err"
            }
            & $writeLogBufferFn -State $stateRef
            return
        }
        if ($snapshot.ExecutionCount -eq 0) {
            & $writeLogFn -State $stateRef -Message '[ERROR] チェックされたファイルがありません。音声・動画列にチェックを入れてください。'
            return
        }

        $policyMap = @{ '連番付与' = 'rename'; 'スキップ' = 'skip'; '上書き' = 'overwrite' }
        $policy = $policyMap[[string]$cc.CmbCollision.SelectedItem]
        if (-not $policy) { $policy = 'rename' }

        $speedResult = & $getSpeedPercentMapFromGridFn `
            -State $stateRef -EffectiveTargetPaths $snapshot.ExecutionPaths
        if ($speedResult.Errors.Count -gt 0) {
            & $writeLogFn -State $stateRef -Message '[ERROR] 速度(%) の指定が不正です。50 から 200 の整数で入力してください。'
            foreach ($err in $speedResult.Errors) {
                & $writeLogFn -State $stateRef -Message "        $err"
            }
            & $writeLogBufferFn -State $stateRef
            return
        }

        $stateRef.ProgressCurrent = 0
        $stateRef.ProgressTotal = $snapshot.ExecutionCount
        $stateRef.TotalDurationSec = [double]$snapshot.SelectedDurationSec
        $stateRef.ProcessedDurationSec = 0.0
        $stateRef.ProcessingStartTime = Get-Date
        & $updateProgressFn -State $stateRef -Current 0 -Total $stateRef.ProgressTotal
        $stageList = [Collections.Generic.List[object]]::new()
        if ($snapshot.ExecutionAudioFiles.Count -gt 0) {
            $stageList.Add([pscustomobject]@{
                    Mode = 'audio'
                    TargetFiles = @($snapshot.ExecutionAudioFiles | ForEach-Object FullName)
                })
        }
        if ($snapshot.ExecutionVideoFiles.Count -gt 0) {
            $stageList.Add([pscustomobject]@{
                    Mode = 'video'
                    TargetFiles = @($snapshot.ExecutionVideoFiles | ForEach-Object FullName)
                })
        }
        $dto = [pscustomobject]@{
            InputDir = $cc.TxtInput.Text.Trim()
            InputPaths = @($stateRef.InputSelectionPaths)
            OutputDir = $cc.TxtOutput.Text.Trim()
            Target = [double]$cc.NumTarget.Value
            TruePeak = [double]$cc.NumTP.Value
            Bitrate = [string]$cc.CmbBR.SelectedItem
            SampleRate = [string]$cc.CmbSR.SelectedItem
            CollisionPolicy = $policy
            Stages = $stageList.ToArray()
            DurationMap = @{}
            SpeedPercentByPath = $speedResult.Values
            AudioOutputFormat = [string]$cc.CmbAudioFormat.SelectedItem
            AnalyzeOnly = [bool]$cc.ChkAnalyzeOnly.Checked
            SkipIfNormalized = [bool]$cc.ChkSkipNormalized.Checked
            Recurse = [bool]$cc.ChkRecurse.Checked
            PreserveHierarchy = [bool]$cc.ChkPreserveHierarchy.Checked
            ReportPath = $stateRef.ReportPath
            ReportMode = if ($stageList.Count -gt 1) { 'both' } else { [string]$stageList[0].Mode }
            TotalItems = [int]$snapshot.ExecutionCount
        }
        foreach ($key in $stateRef.DurationMap.Keys) { $dto.DurationMap[[string]$key] = [double]$stateRef.DurationMap[$key] }
        & $startOperationFn -State $stateRef -Dto $dto | Out-Null
    }.GetNewClosure())

    # === FormClosing: request cancellation before closing & persist settings ===
    # Save-Settings は LogTimer Dispose と最終 Write-LogBuffer より前に呼ぶ。
    $Form.Add_FormClosing({
        param($sender, $eventArgs)
        if ([string]$stateRef.OperationState -ne 'Idle') {
            $eventArgs.Cancel = $true
            if ([string]$stateRef.OperationState -ne 'Cancelling') {
                $answer = [System.Windows.Forms.MessageBox]::Show(
                    '処理をキャンセルして終了しますか？',
                    'Media Normalizer',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning)
                if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                    & $requestCancellationFn -State $stateRef | Out-Null
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
            -ExtensionFields $stateRef.SettingsExtensionFields `
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
    $provenance = Get-BuildProvenance
    if ($provenance) {
        Write-Log -State $State -Message (
            '[INFO ] build provenance: buildId={0} runtime={1} output={2}' -f
            $provenance.BuildId, $provenance.Runtime, $provenance.OutputName)
    } else {
        Write-Log -State $State -Message '[INFO ] build provenance: source tree or provenance未配置'
    }
    $presetNames = @($presets.Keys)
    $State.Presets = $presets

    $c = $State.Controls
    $stateRef = $State
    # GetNewClosure preserves local UI state by creating a dynamic module. Capture
    # private helper ScriptBlocks explicitly so delayed .NET callbacks do not rely
    # on those helpers being exported into the caller's session state.
    [scriptblock]$getPresetRationaleTextFn = ${function:Get-PresetRationaleText}
    [scriptblock]$initializeFileGridSelectionStateFn = ${function:Initialize-FileGridSelectionState}
    [scriptblock]$setFileGridColumnLayoutFn = ${function:Set-FileGridColumnLayout}
    [scriptblock]$setUiInputSelectionFn = ${function:Set-UiInputSelection}
    [scriptblock]$updateFileGridModeStateFn = ${function:Update-FileGridModeState}
    [scriptblock]$updateFileListFn = ${function:Update-FileList}
    [scriptblock]$saveFileGridSelectionStateFn = ${function:Save-FileGridSelectionStateFromGrid}
    [scriptblock]$updateFileGridSummaryFn = ${function:Update-FileGridSummary}
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
    Register-FileGridSelectionEventHandlers -State $stateRef -DataGridView $dgv
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
    $lblOperationStatus = New-Object System.Windows.Forms.Label
    $lblOperationStatus.Text = '待機中'
    $lblOperationStatus.Location = New-Object System.Drawing.Point(86, $y)
    $lblOperationStatus.AutoSize = $false
    $lblOperationStatus.Size = New-Object System.Drawing.Size(490, 18)
    $lblOperationStatus.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $form.Controls.Add($lblOperationStatus)
    $c.LblOperationStatus = $lblOperationStatus
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
        & $saveFileGridSelectionStateFn -State $stateRef
        & $updateFileGridSummaryFn -State $stateRef
    }.GetNewClosure())

    $chkAudio.Add_CheckedChanged({
        $ck = $stateRef.Controls.ChkAudio
        if ($ck.Checked) {
            $ck.ForeColor = [System.Drawing.Color]::White
        } else {
            $ck.ForeColor = [System.Drawing.SystemColors]::ControlText
        }
        if ($stateRef.ScanValid) { & $updateFileGridModeStateFn -State $stateRef }
    }.GetNewClosure())

    $chkVideo.Add_CheckedChanged({
        $ck = $stateRef.Controls.ChkVideo
        if ($ck.Checked) {
            $ck.ForeColor = [System.Drawing.Color]::White
        } else {
            $ck.ForeColor = [System.Drawing.SystemColors]::ControlText
        }
        if ($stateRef.ScanValid) { & $updateFileGridModeStateFn -State $stateRef }
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
        & $initializeFileGridSelectionStateFn -State $stateRef | Out-Null
        $stateRef.FileRowState = @{}
        $stateRef.InputScopeKey = $null
        $stateRef.Controls.Dgv.Rows.Clear()
        $stateRef.Controls.LblSummary.Text = '入力パスが変更されました。[確認] を押してください'
        $stateRef.ScanValid = $false
        $stateRef.CachedFiles = @()
    }.GetNewClosure())

    Register-MainFormEventHandlers -State $State -Form $form
    # === Apply persisted settings ===
    # フォーム生成後・ShowDialog 前に settings.json を反映する。
    $loadedSettings = Read-Settings
    $State.SettingsExtensionFields = if ($loadedSettings.PSObject.Properties['ExtensionFields']) {
        $loadedSettings.ExtensionFields
    } else {
        [ordered]@{}
    }
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
        $stateRef.Form.Activate()
    }.GetNewClosure())
    [void]$State.Form.ShowDialog()
}

# GetNewClosureを使う遅延callbackはprivate helperのScriptBlockを明示的にcaptureする。
# これにより.NET delegate経由でも内部関数を解決でき、製品public surfaceをGUI
# entrypoint 4関数へ限定できる。private helperのunit testはInModuleScopeを使う。
Export-ModuleMember -Function Initialize-UiState, New-MainForm, Set-ConsoleWindowHidden, Show-MainForm
