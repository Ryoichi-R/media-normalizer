#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:libRoot = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib')
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Core.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Probe.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Ui.psm1')) -Force
}

Describe 'MediaNormalizer.Ui selection state' {
    It 'uses one stable key and scope for equivalent paths' {
        InModuleScope MediaNormalizer.Ui {
            $keyA = Get-FileRowStateKey -Path 'C:\Media\Clip.MP4\'
            $keyB = Get-FileRowStateKey -Path 'c:\media\clip.mp4'
            $keyA | Should -Be $keyB

            $scopeA = Get-InputScopeKey -Paths @('C:\Media\b.mp4', 'C:\Media\a.mp3')
            $scopeB = Get-InputScopeKey -Paths @('c:\media\a.mp3', 'C:\MEDIA\b.mp4')
            $scopeA | Should -Be $scopeB
        }
    }

    It 'revalidates mode and format support and avoids double-counting selected size and duration' {
        InModuleScope MediaNormalizer.Ui {
            $records = @(
                [pscustomobject]@{
                    FullName = 'C:\Media\clip.mp4'; File = [pscustomobject]@{ FullName = 'C:\Media\clip.mp4' }
                    SupportsAudio = $true; SupportsVideo = $true; AudioSelected = $true; VideoSelected = $true
                    SpeedPercent = 100; Size = 100; Duration = 12.0
                },
                [pscustomobject]@{
                    FullName = 'C:\Media\voice.mp3'; File = [pscustomobject]@{ FullName = 'C:\Media\voice.mp3' }
                    SupportsAudio = $true; SupportsVideo = $false; AudioSelected = $true; VideoSelected = $true
                    SpeedPercent = 100; Size = 50; Duration = 8.0
                }
            )

            $snapshot = Get-FileSelectionSnapshotFromRecord `
                -Records $records -AudioEnabled:$false -VideoEnabled:$true -AnalyzeOnly:$false

            $snapshot.AudioCount | Should -Be 0
            $snapshot.VideoCount | Should -Be 1
            $snapshot.SelectedSize | Should -Be 100
            $snapshot.SelectedDurationSec | Should -Be 12
            $snapshot.ExecutionCount | Should -Be 1
        }
    }

    It 'keeps display selection counts while AnalyzeOnly suppresses video execution' {
        InModuleScope MediaNormalizer.Ui {
            $records = @(
                [pscustomobject]@{
                    FullName = 'C:\Media\clip.mp4'; File = [pscustomobject]@{ FullName = 'C:\Media\clip.mp4' }
                    SupportsAudio = $true; SupportsVideo = $true; AudioSelected = $true; VideoSelected = $true
                    SpeedPercent = 100; Size = 100; Duration = 12.0
                }
            )
            $snapshot = Get-FileSelectionSnapshotFromRecord `
                -Records $records -AudioEnabled:$true -VideoEnabled:$true -AnalyzeOnly:$true

            $snapshot.AudioCount | Should -Be 1
            $snapshot.VideoCount | Should -Be 1
            $snapshot.ExecutionAudioFiles.Count | Should -Be 1
            $snapshot.ExecutionVideoFiles.Count | Should -Be 0
            $snapshot.ExecutionCount | Should -Be 1
        }
    }

    It 'reports an index mismatch instead of silently dropping the row' {
        InModuleScope MediaNormalizer.Ui {
            $row = [pscustomobject]@{
                IsNewRow = $false
                Cells = @{
                    FullName = [pscustomobject]@{ Value = 'C:\Media\missing.mp4' }
                    Audio = [pscustomobject]@{ Value = $true }
                    Video = [pscustomobject]@{ Value = $false }
                    SpeedPercent = [pscustomobject]@{ Value = 100 }
                    FileName = [pscustomobject]@{ Value = 'missing.mp4' }
                }
            }
            $state = [pscustomobject]@{
                Controls = @{ Dgv = [pscustomobject]@{ Rows = @($row) } }
                FileIndex = @{}
                DurationMap = @{}
            }

            $snapshot = Get-FileGridSelectionSnapshot -State $state
            $snapshot.Errors.Count | Should -Be 1
            $snapshot.Errors[0] | Should -Match '索引'
        }
    }

    It 'fills missing selection-state properties without replacing existing values' {
        InModuleScope MediaNormalizer.Ui {
            $existing = [pscustomobject]@{ DesiredAudio = $false }
            $state = [pscustomobject]@{
                FileRowState = @{ 'C:\MEDIA\CLIP.MP4' = $existing }
                InputScopeKey = 'existing-scope'
            }
            Initialize-FileGridSelectionState -State $state | Out-Null

            $state.FileRowState['C:\MEDIA\CLIP.MP4'] | Should -Be $existing
            $state.InputScopeKey | Should -Be 'existing-scope'
            $state.InputSelectionPaths.Count | Should -Be 0
            $state.FileGridUpdateDepth | Should -Be 0
        }
    }

    It 'keeps a scan error visible when an obsolete probe job completes' {
        InModuleScope MediaNormalizer.Ui {
            Mock -ModuleName MediaNormalizer.Ui Get-Job {
                [pscustomobject]@{ Id = 8811; State = 'Completed' }
            }
            Mock -ModuleName MediaNormalizer.Ui Receive-ProbeJobResult {
                [pscustomobject]@{ FullName = 'obsolete.mp4'; Duration = 5.0 }
            }
            Mock -ModuleName MediaNormalizer.Ui Remove-Job { }

            $state = [pscustomobject]@{
                PendingProbeJobs = @{ 8811 = @('obsolete.mp4') }
                DurationMap = @{}
                FullNameToRow = @{}
                ProbeTimer = $null
                ProbeSummary = [pscustomobject]@{ AudioCount = 9; VideoCount = 9 }
                ScanValid = $false
                Controls = @{
                    Dgv = [pscustomobject]@{}
                    ChkAudio = [pscustomobject]@{ Checked = $true }
                    ChkVideo = [pscustomobject]@{ Checked = $true }
                    LblSummary = [pscustomobject]@{ Text = '[エラー] 入力を確認してください' }
                    BtnRun = [pscustomobject]@{ Enabled = $false }
                }
                RunningProcess = $false
            }

            Update-PendingProbeJobs -State $state

            $state.PendingProbeJobs.Count | Should -Be 0
            $state.ProbeSummary | Should -BeNullOrEmpty
            $state.Controls.LblSummary.Text | Should -Be '[エラー] 入力を確認してください'
            $state.Controls.BtnRun.Enabled | Should -BeFalse
        }
    }

    It 'preserves desired video selection, speed, row identity, and probe state across mode changes' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
        InModuleScope MediaNormalizer.Ui {
            Initialize-UiAssemblies
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-selection-state-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            $dgv = $null
            try {
                $audioPath = Join-Path $tmp 'voice.mp3'
                $videoPath = Join-Path $tmp 'clip.mp4'
                Set-Content -LiteralPath $audioPath -Value 'fixture' -Encoding UTF8
                Set-Content -LiteralPath $videoPath -Value 'fixture' -Encoding UTF8

                $dgv = [Windows.Forms.DataGridView]::new()
                $dgv.AllowUserToAddRows = $false
                foreach ($column in @(
                        [Windows.Forms.DataGridViewCheckBoxColumn]::new(),
                        [Windows.Forms.DataGridViewCheckBoxColumn]::new())) {
                    [void]$dgv.Columns.Add($column)
                }
                $dgv.Columns[0].Name = 'Audio'
                $dgv.Columns[1].Name = 'Video'
                foreach ($name in @('FileName', 'Ext', 'Size', 'Duration', 'SpeedPercent', 'FullName')) {
                    [void]$dgv.Columns.Add($name, $name)
                }
                $state = [pscustomobject]@{
                    Controls = @{
                        Dgv = $dgv
                        ChkAudio = [pscustomobject]@{ Checked = $true }
                        ChkVideo = [pscustomobject]@{ Checked = $true }
                        TxtInput = [pscustomobject]@{ Text = $tmp }
                        NumSpeed = [pscustomobject]@{ Value = 100 }
                        LblSummary = [pscustomobject]@{ Text = '' }
                        BtnRun = [pscustomobject]@{ Enabled = $true }
                    }
                    CachedFiles = @([IO.FileInfo]$audioPath, [IO.FileInfo]$videoPath)
                    HasThreadJob = $false
                    PendingProbeJobs = @{}
                    ProbeTimer = $null
                    DurationMap = @{}
                    FileIndex = @{}
                    FullNameToRow = @{}
                    ProbeSummary = $null
                    FfprobeAvailable = $false
                    RunningProcess = $false
                    LogBuffer = [Text.StringBuilder]::new()
                    ScanValid = $true
                }
                Update-FileGrid -State $state -InputScopeKey (Get-InputScopeKey -Paths @($tmp))
                $videoRow = $state.FullNameToRow[$videoPath]
                $rowReference = $videoRow
                $durationKeys = @($state.DurationMap.Keys)
                $state.PendingProbeJobs[123] = @($videoPath)
                $state.PendingProbeJobs.Count | Should -Be 1
                $videoRow.Cells['Video'].Value = $false
                $videoRow.Cells['SpeedPercent'].Value = 150
                Save-FileGridSelectionStateFromGrid -State $state

                $state.Controls.ChkVideo.Checked = $false
                Update-FileGridModeState -State $state
                $videoRow.Cells['Video'].Value | Should -BeFalse
                $videoRow.Cells['Video'].ReadOnly | Should -BeTrue
                $videoRow | Should -Be $rowReference

                $state.Controls.ChkVideo.Checked = $true
                Update-FileGridModeState -State $state
                $videoRow.Cells['Video'].Value | Should -BeFalse
                $videoRow.Cells['SpeedPercent'].Value | Should -Be 150
                @($state.DurationMap.Keys) | Should -Be $durationKeys
                $state.PendingProbeJobs.Count | Should -Be 1
            } finally {
                if ($dgv) { $dgv.Dispose() }
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'restores selection and speed on same-scope rescan but resets them on a new scope' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
        InModuleScope MediaNormalizer.Ui {
            Initialize-UiAssemblies
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-selection-rescan-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            $dgv = $null
            try {
                $path = Join-Path $tmp 'clip.mp4'
                Set-Content -LiteralPath $path -Value 'fixture' -Encoding UTF8
                $dgv = [Windows.Forms.DataGridView]::new()
                $dgv.AllowUserToAddRows = $false
                $audio = [Windows.Forms.DataGridViewCheckBoxColumn]::new(); $audio.Name = 'Audio'; [void]$dgv.Columns.Add($audio)
                $video = [Windows.Forms.DataGridViewCheckBoxColumn]::new(); $video.Name = 'Video'; [void]$dgv.Columns.Add($video)
                foreach ($name in @('FileName', 'Ext', 'Size', 'Duration', 'SpeedPercent', 'FullName')) { [void]$dgv.Columns.Add($name, $name) }
                $state = [pscustomobject]@{
                    Controls = @{
                        Dgv = $dgv; ChkAudio = [pscustomobject]@{ Checked = $true }; ChkVideo = [pscustomobject]@{ Checked = $true }
                        TxtInput = [pscustomobject]@{ Text = $tmp }; NumSpeed = [pscustomobject]@{ Value = 100 }
                        LblSummary = [pscustomobject]@{ Text = '' }; BtnRun = [pscustomobject]@{ Enabled = $true }
                    }
                    CachedFiles = @([IO.FileInfo]$path); HasThreadJob = $false; PendingProbeJobs = @{}; ProbeTimer = $null
                    DurationMap = @{}; FileIndex = @{}; FullNameToRow = @{}; ProbeSummary = $null
                    FfprobeAvailable = $false; RunningProcess = $false; LogBuffer = [Text.StringBuilder]::new(); ScanValid = $true
                }
                $scope = Get-InputScopeKey -Paths @($tmp)
                Update-FileGrid -State $state -InputScopeKey $scope
                $row = $state.FullNameToRow[$path]
                $row.Cells['Video'].Value = $false
                $row.Cells['SpeedPercent'].Value = 175
                Save-FileGridSelectionStateFromGrid -State $state
                Update-FileGrid -State $state -InputScopeKey $scope
                $state.Controls.Dgv.Rows[0].Cells['Video'].Value | Should -BeFalse
                $state.Controls.Dgv.Rows[0].Cells['SpeedPercent'].Value | Should -Be 175

                Update-FileGrid -State $state -InputScopeKey 'new-scope'
                $state.Controls.Dgv.Rows[0].Cells['Video'].Value | Should -BeTrue
                $state.Controls.Dgv.Rows[0].Cells['SpeedPercent'].Value | Should -Be 100
            } finally {
                if ($dgv) { $dgv.Dispose() }
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'clears the nested update guard when a structural refresh throws' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
        InModuleScope MediaNormalizer.Ui {
            Initialize-UiAssemblies
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-selection-reentry-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            $dgv = $null
            try {
                $path = Join-Path $tmp 'clip.mp4'
                Set-Content -LiteralPath $path -Value 'fixture' -Encoding UTF8
                $dgv = [Windows.Forms.DataGridView]::new()
                $dgv.AllowUserToAddRows = $false
                $audio = [Windows.Forms.DataGridViewCheckBoxColumn]::new(); $audio.Name = 'Audio'; [void]$dgv.Columns.Add($audio)
                $video = [Windows.Forms.DataGridViewCheckBoxColumn]::new(); $video.Name = 'Video'; [void]$dgv.Columns.Add($video)
                foreach ($name in @('FileName', 'Ext', 'Size', 'Duration', 'SpeedPercent', 'FullName')) { [void]$dgv.Columns.Add($name, $name) }
                $state = [pscustomobject]@{
                    Controls = @{
                        Dgv = $dgv; ChkAudio = [pscustomobject]@{ Checked = $true }; ChkVideo = [pscustomobject]@{ Checked = $true }
                        TxtInput = [pscustomobject]@{ Text = $tmp }; NumSpeed = [pscustomobject]@{ Value = 100 }
                        LblSummary = [pscustomobject]@{ Text = '' }; BtnRun = [pscustomobject]@{ Enabled = $true }
                    }
                    CachedFiles = @([IO.FileInfo]$path); HasThreadJob = $false; PendingProbeJobs = @{}; ProbeTimer = $null
                    DurationMap = @{}; FileIndex = @{}; FullNameToRow = @{}; ProbeSummary = $null
                    FfprobeAvailable = $false; RunningProcess = $false; LogBuffer = [Text.StringBuilder]::new(); ScanValid = $true
                }
                Mock -ModuleName MediaNormalizer.Ui Stop-PendingProbeJobs { throw 'simulated grid refresh failure' }

                { Update-FileGrid -State $state -InputScopeKey 'reentry-scope' } | Should -Throw '*simulated grid refresh failure*'
                $state.FileGridUpdateDepth | Should -Be 0
                $state.FileGridModeRefreshPending | Should -BeFalse
            } finally {
                if ($dgv) { $dgv.Dispose() }
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'coalesces a mode change raised during a structural refresh into one deferred refresh' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
        InModuleScope MediaNormalizer.Ui {
            Initialize-UiAssemblies
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-selection-pending-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            $dgv = $null
            $summary = $null
            try {
                $path = Join-Path $tmp 'clip.mp4'
                Set-Content -LiteralPath $path -Value 'fixture' -Encoding UTF8
                $dgv = [Windows.Forms.DataGridView]::new()
                $dgv.AllowUserToAddRows = $false
                $audio = [Windows.Forms.DataGridViewCheckBoxColumn]::new(); $audio.Name = 'Audio'; [void]$dgv.Columns.Add($audio)
                $video = [Windows.Forms.DataGridViewCheckBoxColumn]::new(); $video.Name = 'Video'; [void]$dgv.Columns.Add($video)
                foreach ($name in @('FileName', 'Ext', 'Size', 'Duration', 'SpeedPercent', 'FullName')) { [void]$dgv.Columns.Add($name, $name) }
                $summary = [Windows.Forms.Label]::new()
                $state = [pscustomobject]@{
                    Controls = @{
                        Dgv = $dgv; ChkAudio = [pscustomobject]@{ Checked = $true }; ChkVideo = [pscustomobject]@{ Checked = $true }
                        TxtInput = [pscustomobject]@{ Text = $tmp }; NumSpeed = [pscustomobject]@{ Value = 100 }
                        LblSummary = $summary; BtnRun = [pscustomobject]@{ Enabled = $true }
                    }
                    CachedFiles = @([IO.FileInfo]$path); HasThreadJob = $false; PendingProbeJobs = @{}; ProbeTimer = $null
                    DurationMap = @{}; FileIndex = @{}; FullNameToRow = @{}; ProbeSummary = $null
                    FfprobeAvailable = $false; RunningProcess = $false; LogBuffer = [Text.StringBuilder]::new(); ScanValid = $true
                }
                $scope = Get-InputScopeKey -Paths @($tmp)
                Update-FileGrid -State $state -InputScopeKey $scope
                $realUpdateMode = ${function:Update-FileGridModeState}
                $observation = [pscustomobject]@{ Triggered = $false; PendingSeen = $false }
                $summary.Add_TextChanged({
                    if (-not $observation.Triggered -and $summary.Text -like 'スキャン中*') {
                        $observation.Triggered = $true
                        $state.Controls.ChkVideo.Checked = $false
                        & $realUpdateMode -State $state
                        $observation.PendingSeen = [bool]$state.FileGridModeRefreshPending
                    }
                }.GetNewClosure())
                Mock -ModuleName MediaNormalizer.Ui Update-FileGridModeState { }

                Update-FileGrid -State $state -InputScopeKey $scope

                $observation.PendingSeen | Should -BeTrue
                $state.FileGridUpdateDepth | Should -Be 0
                $state.FileGridModeRefreshPending | Should -BeFalse
                Should -Invoke -ModuleName MediaNormalizer.Ui Update-FileGridModeState -Times 1 -Exactly
                & $realUpdateMode -State $state
                $state.Controls.Dgv.Rows[0].Cells['Video'].Value | Should -BeFalse
                $state.FileRowState[(Get-FileRowStateKey -Path $path)].DesiredVideo | Should -BeTrue
            } finally {
                if ($summary) { $summary.Dispose() }
                if ($dgv) { $dgv.Dispose() }
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'reproduces the video selection sequence through the existing WinForms entry points' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
        InModuleScope MediaNormalizer.Ui {
            Initialize-UiAssemblies
            Mock Initialize-ThreadJob { $false }
            Mock Read-Settings {
                [pscustomobject]@{
                    Values = @{ InputDir = ''; OutputDir = ''; LastPreset = 'デフォルト'; LastMode = 'both' }
                    Warnings = @()
                }
            }
            Mock Save-Settings {}
            Mock Write-LogBuffer {}

            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-selection-entry-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            $form = $null
            try {
                foreach ($name in @('voice.mp3', 'clip.mp4')) {
                    Set-Content -LiteralPath (Join-Path $tmp $name) -Value 'fixture' -Encoding UTF8
                }
                $state = New-MediaNormalizerState
                Initialize-UiState -State $state | Out-Null
                $form = New-MainForm -State $state
                $form.Show()
                [Windows.Forms.Application]::DoEvents()

                $state.Controls.TxtInput.Text = $tmp
                $state.Controls.BtnScanFiles.PerformClick()
                [Windows.Forms.Application]::DoEvents()
                $state.ScanValid | Should -BeTrue
                $state.Controls.Dgv.Rows.Count | Should -Be 2

                $videoRow = @($state.Controls.Dgv.Rows | Where-Object {
                    [string]$_.Cells['FullName'].Value -eq (Join-Path $tmp 'clip.mp4')
                })[0]
                $rowReference = $videoRow
                $state.Controls.Dgv.CurrentCell = $videoRow.Cells['Video']
                [void]$state.Controls.Dgv.BeginEdit($true)
                $onContentClick = [Windows.Forms.DataGridViewCheckBoxCell].GetMethod(
                    'OnContentClick',
                    [Reflection.BindingFlags]'Instance, NonPublic')
                [void]$onContentClick.Invoke(
                    $videoRow.Cells['Video'],
                    @([Windows.Forms.DataGridViewCellEventArgs]::new(
                            $videoRow.Cells['Video'].ColumnIndex,
                            $videoRow.Index)))
                [Windows.Forms.Application]::DoEvents()
                $state.Controls.Dgv.IsCurrentCellDirty | Should -BeFalse
                $videoRow.Cells['Video'].Value | Should -BeFalse
                $state.FileRowState[(Get-FileRowStateKey -Path (Join-Path $tmp 'clip.mp4'))].DesiredVideo | Should -BeFalse
                $state.Controls.LblSummary.Text | Should -Match '動画: 0件'

                # 既存の上段Audioチェックボタン経路だけを操作する。
                $state.Controls.ChkAudio.Checked = $false
                [Windows.Forms.Application]::DoEvents()
                $videoRow.Cells['Video'].Value | Should -BeFalse
                $videoRow | Should -Be $rowReference

                # Video OFF -> ON も既存の上段Videoチェックボタン経路で操作する。
                $state.Controls.ChkVideo.Checked = $false
                $state.Controls.ChkVideo.Checked = $true
                [Windows.Forms.Application]::DoEvents()
                $videoRow.Cells['Video'].Value | Should -BeFalse
                $videoRow.Cells['Video'].ReadOnly | Should -BeFalse
                $state.Controls.LblSummary.Text | Should -Match '動画: 0件'

                $state.Controls.NumSpeed.Value = 150
                $state.Controls.BtnApplySpeed.PerformClick()
                [Windows.Forms.Application]::DoEvents()
                @($state.Controls.Dgv.Rows | ForEach-Object { $_.Cells['SpeedPercent'].Value }) | Should -Not -Contain 100
                @($state.FileRowState.Values | ForEach-Object { $_.SpeedPercent }) | Should -Not -Contain 100

                $state.Controls.ChkRecurse.Checked = $false
                [Windows.Forms.Application]::DoEvents()
                $videoRow = @($state.Controls.Dgv.Rows | Where-Object {
                    [string]$_.Cells['FullName'].Value -eq (Join-Path $tmp 'clip.mp4')
                })[0]
                $videoRow.Cells['Video'].Value | Should -BeFalse
                $videoRow.Cells['SpeedPercent'].Value | Should -Be 150
                $state.Controls.ChkRecurse.Checked = $true
                [Windows.Forms.Application]::DoEvents()
                $videoRow = @($state.Controls.Dgv.Rows | Where-Object {
                    [string]$_.Cells['FullName'].Value -eq (Join-Path $tmp 'clip.mp4')
                })[0]
                $videoRow.Cells['Video'].Value | Should -BeFalse
                $videoRow.Cells['SpeedPercent'].Value | Should -Be 150
            } finally {
                if ($form) {
                    try { $form.Close() } catch { }
                    try { $form.Dispose() } catch { }
                }
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
