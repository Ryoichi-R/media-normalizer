#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:libRoot = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib')
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Core.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Probe.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Ui.psm1')) -Force

    function New-OperationTestControl {
        [pscustomobject]@{ Enabled = $true; Text = ''; Checked = $false; Value = 0 }
    }

    function New-OperationTestState {
        $keys = @(
            'BtnRun', 'BtnScanFiles', 'TxtInput', 'BtnBrowseInput', 'TxtOutput',
            'BtnBrowseOutput', 'ChkAudio', 'ChkVideo', 'CmbPreset', 'CmbCollision',
            'NumSpeed', 'BtnApplySpeed', 'BtnBrowseFiles', 'CmbAudioFormat',
            'ChkAnalyzeOnly', 'ChkSkipNormalized', 'ChkRecurse', 'ChkPreserveHierarchy',
            'Dgv', 'BtnCancel', 'LblOperationStatus')
        $controls = @{}
        foreach ($key in $keys) { $controls[$key] = New-OperationTestControl }
        $controls.TxtLog = $null
        [pscustomobject]@{
            Controls = $controls
            OperationId = 'op-test'
            LastOperationId = 'op-test'
            OperationState = 'Idle'
            OperationStartedAt = (Get-Date)
            WorkerHandle = $null
            ActiveChildPid = $null
            CurrentPhase = $null
            LastHeartbeatAt = $null
            LastOutputGrowthAt = $null
            CompletionHandled = $false
            FinalizationStarted = $false
            LastCompletionReason = 'None'
            OperationCancellation = $null
            OperationEvents = $null
            LogBuffer = [Text.StringBuilder]::new()
            LogPath = $null
            OrphanTimeoutSeconds = 15
        }
    }
}

Describe 'MediaNormalizer UI operation state' {
    It 'allows only the documented state transitions' {
        $state = New-OperationTestState
        InModuleScope MediaNormalizer.Ui -Parameters @{ state = $state } {
            param($state)
            Set-UiOperationState -State $state -OperationState Starting
            Set-UiOperationState -State $state -OperationState Running
            Set-UiOperationState -State $state -OperationState Cancelling
            Set-UiOperationState -State $state -OperationState Finalizing
            Set-UiOperationState -State $state -OperationState Idle
            $state.OperationState | Should -Be 'Idle'
            $state.Controls.LblOperationStatus.Text | Should -Be '待機中'
            { Set-UiOperationState -State $state -OperationState Finalizing } | Should -Throw
        }
    }

    It 'finalizes the same operation only once and restores controls' {
        $state = New-OperationTestState
        InModuleScope MediaNormalizer.Ui -Parameters @{ state = $state } {
            param($state)
            Set-UiOperationState -State $state -OperationState Starting
            Set-UiOperationState -State $state -OperationState Running
            Complete-UiOperation -State $state -OperationId 'op-test' -Reason Succeeded | Should -BeTrue
            Complete-UiOperation -State $state -OperationId 'op-test' -Reason Failed | Should -BeFalse
            $state.OperationState | Should -Be 'Idle'
            $state.CompletionHandled | Should -BeTrue
            $state.FinalizationStarted | Should -BeTrue
            $state.LastCompletionReason | Should -Be 'Succeeded'
            $state.Controls.BtnRun.Enabled | Should -BeTrue
        }
    }

    It 'ignores a completion event from an older operation' {
        $state = New-OperationTestState
        InModuleScope MediaNormalizer.Ui -Parameters @{ state = $state } {
            param($state)
            Complete-UiOperation -State $state -OperationId 'old-operation' -Reason Failed | Should -BeFalse
            $state.OperationState | Should -Be 'Idle'
            $state.CompletionHandled | Should -BeFalse
        }
    }

    It 'records phase and child lifecycle events with the operation id' {
        $state = New-OperationTestState
        $state.OperationEvents = [Collections.Concurrent.ConcurrentQueue[object]]::new()
        $state.OperationState = 'Running'
        $state.OperationEvents.Enqueue([pscustomobject]@{
                Type = 'ChildStarted'; OperationId = 'op-test'; ChildPid = 1234
                Phase = '正規化中'; At = [DateTime]::UtcNow
            })
        $state.OperationEvents.Enqueue([pscustomobject]@{
                Type = 'Progress'; OperationId = 'op-test'; Current = 1; Total = 2
                Phase = '正規化中'; ChildPid = 1234; At = [DateTime]::UtcNow
            })
        $state.OperationEvents.Enqueue([pscustomobject]@{
                Type = 'ChildExited'; OperationId = 'op-test'; ChildPid = 1234
                At = [DateTime]::UtcNow
            })

        InModuleScope MediaNormalizer.Ui -Parameters @{ state = $state } {
            param($state)
            Receive-UiOperationEvents -State $state
            $state.ActiveChildPid | Should -BeNullOrEmpty
            $state.CurrentPhase | Should -Be '正規化中'
            $state.LogBuffer.ToString() | Should -Match '\[op:op-test\].*child開始 pid=1234'
            $state.LogBuffer.ToString() | Should -Match '\[op:op-test\].*phase=正規化中'
            $state.LogBuffer.ToString() | Should -Match '\[op:op-test\].*child終了 pid=1234'
        }
    }

    It 'composes progress across audio and video stages and fails on report persistence failure' {
        $coreModule = Join-Path $TestDrive 'fake-core.psm1'
        $probeModule = Join-Path $TestDrive 'fake-probe.psm1'
        $progressModule = Join-Path $TestDrive 'fake-progress.psm1'
        Set-Content -LiteralPath $coreModule -Encoding utf8 -Value @'
function New-MediaNormalizerState { [pscustomobject]@{ DurationMap = @{}; RunningProcess = $null; CurrentPhase = $null; PhaseProgressPercent = -1; ProgressCurrent = 0; ProgressTotal = 0; ReportRecords = [Collections.Generic.List[object]]::new() } }
function Get-AudioInputExtensions { @('.mp3') }
function Get-VideoInputExtensions { @('.mp4') }
function Invoke-Normalize {
    param($State, $Mode, $Progress)
    $State.CurrentPhase = $Mode
    $start = [int]$State.ProgressCurrent
    & $Progress $start 1
    $State.ProgressCurrent = $start + 1
    & $Progress $State.ProgressCurrent 1
    [hashtable]@{ Success = 1; Fail = 0; Cancelled = 0; ReportSucceeded = ($Mode -ne 'video') }
}
Export-ModuleMember -Function *
'@
        Set-Content -LiteralPath $probeModule -Encoding utf8 -Value 'Export-ModuleMember -Function *'
        Set-Content -LiteralPath $progressModule -Encoding utf8 -Value 'Export-ModuleMember -Function *'
        $events = [Collections.Concurrent.ConcurrentQueue[object]]::new()
        $source = [Threading.CancellationTokenSource]::new()
        $dto = [pscustomobject]@{
            TotalItems = 2
            DurationMap = @{}
            Stages = @(
                [pscustomobject]@{ Mode = 'audio'; TargetFiles = @('a.mp3') }
                [pscustomobject]@{ Mode = 'video'; TargetFiles = @('v.mp4') }
            )
            InputDir = ''; InputPaths = @(); OutputDir = ''; Target = -14.0; TruePeak = -1.0
            Bitrate = '192k'; SampleRate = '48000'; CollisionPolicy = 'rename'; SpeedPercentByPath = @{}
            AudioOutputFormat = 'mp3'; AnalyzeOnly = $false; SkipIfNormalized = $true; Recurse = $true
            PreserveHierarchy = $true; ReportPath = 'report.json'; ReportMode = 'both'
        }

        InModuleScope MediaNormalizer.Ui -Parameters @{
            core = $coreModule
            probe = $probeModule
            progress = $progressModule
            dtoValue = $dto
            sourceValue = $source
            eventsValue = $events
        } {
            param($core, $probe, $progress, $dtoValue, $sourceValue, $eventsValue)
            & $script:UiNormalizeWorker $core $probe $progress 'op-test' $dtoValue $sourceValue $eventsValue
        }

        $items = [Collections.Generic.List[object]]::new()
        $item = $null
        while ($events.TryDequeue([ref]$item)) { $items.Add($item) }
        @($items | Where-Object Type -eq 'Progress' | ForEach-Object { "$($_.Current)/$($_.Total)" }) |
            Should -Contain '1/2'
        @($items | Where-Object Type -eq 'Progress' | ForEach-Object { "$($_.Current)/$($_.Total)" }) |
            Should -Contain '2/2'
        ($items | Where-Object Type -eq 'Completed' | Select-Object -First 1).Reason | Should -Be 'Failed'
        $source.Dispose()
    }
}
