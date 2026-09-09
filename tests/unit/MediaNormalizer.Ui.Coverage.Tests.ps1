#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:libRoot = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib')
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Core.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Probe.psm1')) -Force
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Ui.psm1')) -Force
}

Describe 'MediaNormalizer.Ui coverage contracts' {
    It 'covers platform-aware path helpers' {
        InModuleScope MediaNormalizer.Ui {
            if ($IsWindows) {
                (Get-SettingsPath) | Should -Match 'media-normalizer[\\/]settings\.json$'
                (Get-LogPath) | Should -Match 'media-normalizer[\\/]media-normalizer\.log$'
                (Get-LegacyAutoInputDir) | Should -Match 'pre-normalization data$'
                (Get-LegacyAutoOutputDir) | Should -Match 'normalization data$'
            } else {
                { Get-SettingsPath } | Should -Throw
                { Get-LogPath } | Should -Throw
                { Get-LegacyAutoInputDir } | Should -Throw
                { Get-LegacyAutoOutputDir } | Should -Throw
            }
        }
    }

    It 'covers ffprobe duration parse and command failure fallbacks' {
        InModuleScope MediaNormalizer.Probe {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-probe-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            $oldPath = $env:PATH
            try {
                Set-Content -LiteralPath (Join-Path $tmp 'ffprobe.cmd') -Value '@echo 0' -Encoding ASCII
                $env:PATH = "$tmp;$oldPath"
                $state = [pscustomobject]@{ FfprobeAvailable = $true }
                Get-MediaDuration -State $state -FilePath (Join-Path $tmp 'sample.mp4') | Should -Be -1

                $env:PATH = Join-Path $tmp 'missing-command-path'
                $state2 = [pscustomobject]@{ FfprobeAvailable = $true }
                Get-MediaDuration -State $state2 -FilePath (Join-Path $tmp 'sample.mp4') | Should -Be -1
            } finally {
                $env:PATH = $oldPath
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'writes normalized process output while filtering progress lines' {
        InModuleScope MediaNormalizer.Ui {
            $state = [pscustomobject]@{ LogBuffer = [Text.StringBuilder]::new() }
            Write-ProcessOutputLog -State $state -Text "`e[32mFile: 1/2`r`nStream 1/2: ignored`nUseful output`rSecond Pass: ignored`n"
            $state.LogBuffer.ToString() | Should -Be "  Useful output`r`n"
        }
    }

    It 'resolves selected target extensions for audio and video controls' {
        InModuleScope MediaNormalizer.Ui {
            $state = [pscustomobject]@{
                Controls = @{
                    ChkAudio = [pscustomobject]@{ Checked = $true }
                    ChkVideo = [pscustomobject]@{ Checked = $false }
                }
            }
            $result = Get-TargetExtensions -State $state
            $result.Audio.Count | Should -BeGreaterThan 0
            $result.Video.Count | Should -Be 0

            $state.Controls.ChkVideo.Checked = $true
            $result = Get-TargetExtensions -State $state
            $result.Video.Count | Should -BeGreaterThan 0
        }
    }

    It 'toggles all UI controls and keeps analyze-only skip disabled' {
        InModuleScope MediaNormalizer.Ui {
            $controlNames = @(
                'BtnRun', 'BtnScanFiles', 'TxtInput', 'BtnBrowseInput', 'TxtOutput',
                'BtnBrowseOutput', 'ChkAudio', 'ChkVideo', 'CmbPreset', 'CmbCollision',
                'NumSpeed', 'BtnApplySpeed', 'BtnBrowseFiles', 'CmbAudioFormat',
                'ChkAnalyzeOnly', 'ChkSkipNormalized', 'ChkRecurse', 'ChkPreserveHierarchy',
                'Dgv', 'BtnCancel')
            $controls = @{}
            foreach ($name in $controlNames) {
                $controls[$name] = [pscustomobject]@{ Enabled = $true; Checked = $false; Value = 100 }
            }
            $controls.ChkAnalyzeOnly.Checked = $true
            $state = [pscustomobject]@{ Controls = $controls }

            Set-UIEnabled -State $state -Enabled:$false
            $controls.BtnRun.Enabled | Should -BeFalse
            $controls.BtnCancel.Enabled | Should -BeTrue
            $controls.ChkSkipNormalized.Enabled | Should -BeFalse

            Set-UIEnabled -State $state -Enabled:$true
            $controls.BtnRun.Enabled | Should -BeTrue
            $controls.BtnCancel.Enabled | Should -BeFalse
            $controls.ChkSkipNormalized.Enabled | Should -BeFalse
        }
    }

    It 'clears the grid and records a scan error' {
        InModuleScope MediaNormalizer.Ui {
            $rows = [Collections.ArrayList]::new()
            [void]$rows.Add('stale')
            $timer = [Timers.Timer]::new()
            $job = Start-Job -ScriptBlock { Start-Sleep -Seconds 30 }
            $state = [pscustomobject]@{
                Controls = @{
                    Dgv = [pscustomobject]@{ Rows = $rows }
                    LblSummary = [pscustomobject]@{ Text = '' }
                }
                ScanValid = $true
                CachedFiles = @('stale')
                LogBuffer = [Text.StringBuilder]::new()
                ProbeTimer = $timer
                PendingProbeJobs = @{ $job.Id = @('stale.mp4') }
                ProbeSummary = [pscustomobject]@{ AudioCount = 1; VideoCount = 1; Total = 1; SizeText = '1 KB' }
            }
            try {
                Clear-FileListWithError -State $state -Message '入力が不正です'
                $rows.Count | Should -Be 0
                $state.Controls.LblSummary.Text | Should -Be '[エラー] 入力が不正です'
                $state.ScanValid | Should -BeFalse
                $state.CachedFiles.Count | Should -Be 0
                $state.ProbeTimer | Should -BeNullOrEmpty
                $state.PendingProbeJobs.Count | Should -Be 0
                $state.ProbeSummary | Should -BeNullOrEmpty
                $state.LogBuffer.ToString() | Should -Match '\[ERROR\] 入力が不正です'
            } finally {
                $leftover = Get-Job -Id $job.Id -ErrorAction SilentlyContinue
                if ($leftover) {
                    Stop-Job -Job $leftover -ErrorAction SilentlyContinue
                    Remove-Job -Job $leftover -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    It 'stops and removes pending probe jobs' {
        InModuleScope MediaNormalizer.Ui {
            $timer = [Timers.Timer]::new()
            $job = Start-Job -ScriptBlock { Start-Sleep -Seconds 30 }
            try {
                $state = [pscustomobject]@{
                    ProbeTimer = $timer
                    PendingProbeJobs = @{ $job.Id = @('sample.mp4') }
                }
                Stop-PendingProbeJobs -State $state
                $state.ProbeTimer | Should -BeNullOrEmpty
                $state.PendingProbeJobs.Count | Should -Be 0
                (Get-Job -Id $job.Id -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
            } finally {
                $leftover = Get-Job -Id $job.Id -ErrorAction SilentlyContinue
                if ($leftover) {
                    Stop-Job -Job $leftover -ErrorAction SilentlyContinue
                    Remove-Job -Job $leftover -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    It 'maps selected grid speed values and reports invalid overrides' {
        InModuleScope MediaNormalizer.Ui {
            function New-CellRow {
                param($fullName, $fileName, $audio, $video, $speed)
                [pscustomobject]@{
                    Cells = @{
                        FullName = [pscustomobject]@{ Value = $fullName }
                        FileName = [pscustomobject]@{ Value = $fileName }
                        Audio = [pscustomobject]@{ Value = $audio }
                        Video = [pscustomobject]@{ Value = $video }
                        SpeedPercent = [pscustomobject]@{ Value = $speed }
                    }
                }
            }
            $state = [pscustomobject]@{
                Controls = @{
                    Dgv = [pscustomobject]@{ Rows = @(
                        (New-CellRow 'a.mp3' 'a.mp3' $true $false 150),
                        (New-CellRow 'b.mp4' 'b.mp4' $false $true 'invalid'),
                        (New-CellRow 'c.wav' 'c.wav' $false $false 200)
                    ) }
                    NumSpeed = [pscustomobject]@{ Value = 100 }
                }
            }
            $result = Get-SpeedPercentMapFromGrid `
                -State $state -EffectiveTargetPaths @('a.mp3', 'b.mp4')
            $result.Values['a.mp3'] | Should -Be 150
            $result.Values.ContainsKey('c.wav') | Should -BeFalse
            $result.Errors.Count | Should -Be 1
            $result.Errors[0] | Should -Match 'b\.mp4'
        }
    }

    It 'sets a valid input selection and invokes the file-list refresh' {
        InModuleScope MediaNormalizer.Ui {
            Mock Update-FileList {}
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-ui-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            try {
                $state = [pscustomobject]@{
                    Controls = @{ TxtInput = [pscustomobject]@{ Text = '' } }
                    InputSelectionPaths = @()
                    ApplyingInputSelection = $false
                }
                Set-UiInputSelection -State $state -Paths @($tmp, (Join-Path $tmp 'missing.mp4'))
                $state.InputSelectionPaths.Count | Should -Be 1
                $state.Controls.TxtInput.Text | Should -Be ([IO.Path]::GetFullPath($tmp))
                $state.ApplyingInputSelection | Should -BeFalse
                Should -Invoke Update-FileList -Times 1 -Exactly

                Set-UiInputSelection -State $state -Paths @((Join-Path $tmp 'missing-again.mp4'))
                Should -Invoke Update-FileList -Times 1 -Exactly
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'returns the fallback rationale text for a missing preset' {
        InModuleScope MediaNormalizer.Ui {
            Get-PresetRationaleText -Preset $null | Should -Be 'プリセットの根拠情報を取得できません。'
        }
    }

    It 'covers malformed settings version and invalid persisted mode' {
        InModuleScope MediaNormalizer.Ui {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-settings-coverage-' + [guid]::NewGuid().ToString('N') + '.json')
            try {
                '{"version":"not-a-number","inputDir":"C:\\bad"}' | Set-Content -LiteralPath $tmp -Encoding UTF8
                $defaults = @{ InputDir = ''; OutputDir = ''; LastPreset = 'デフォルト'; LastMode = 'audio' }
                $invalidVersion = Read-Settings -SettingsPath $tmp -Defaults $defaults
                ($invalidVersion.Warnings -join "`n") | Should -Match 'version が不正'

                '{"version":2,"lastMode":"invalid"}' | Set-Content -LiteralPath $tmp -Encoding UTF8
                $invalidMode = Read-Settings -SettingsPath $tmp -Defaults $defaults
                $invalidMode.Values.LastMode | Should -Be 'audio'
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'initializes state on Windows without creating a form' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
        InModuleScope MediaNormalizer.Ui {
            $state = [pscustomobject]@{ HasThreadJob = $false }
            $result = Initialize-UiState -State $state
            $result.PSObject.Properties['ProbeScript'] | Should -Not -BeNullOrEmpty
            $result.PSObject.Properties['LogPath'] | Should -Not -BeNullOrEmpty
            $result.PSObject.Properties['Controls'] | Should -Not -BeNullOrEmpty
            $result.Form | Should -BeNullOrEmpty

            $oldForm = [Windows.Forms.Form]::new()
            $oldLogTimer = [Windows.Forms.Timer]::new()
            $oldProbeTimer = [Windows.Forms.Timer]::new()
            $stateWithResources = [pscustomobject]@{
                Form = $oldForm
                LogTimer = $oldLogTimer
                ProbeTimer = $oldProbeTimer
                HasThreadJob = $false
            }
            Initialize-UiState -State $stateWithResources | Out-Null
            $oldForm.IsDisposed | Should -BeTrue
            $stateWithResources.LogTimer | Should -BeNullOrEmpty
            $stateWithResources.ProbeTimer | Should -BeNullOrEmpty
        }
    }

    It 'updates and resets progress controls on Windows' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
        InModuleScope MediaNormalizer.Ui {
            Initialize-UiAssemblies
            $state = [pscustomobject]@{
                Controls = @{
                    PnlProgressBg = [pscustomobject]@{ Width = 200 }
                    PnlProgressFill = [pscustomobject]@{ Width = 0 }
                    LblProgress = [pscustomobject]@{ Text = '' }
                }
                ProcessingStartTime = (Get-Date).AddSeconds(-5)
                ProcessedDurationSec = 10.0
                CurrentFileElapsedSec = 2.0
                TotalDurationSec = 20.0
                CurrentPhase = '正規化'
                PhaseProgressPercent = 50.0
            }
            Update-Progress -State $state -Current 1 -Total 2
            $state.Controls.PnlProgressFill.Width | Should -Be 100
            $state.Controls.LblProgress.Text | Should -Match '正規化 50%'
            Reset-Progress -State $state
            $state.Controls.PnlProgressFill.Width | Should -Be 0
            $state.Controls.LblProgress.Text | Should -Be ''
            $state.TotalDurationSec | Should -Be 0
        }
    }

    It 'rebuilds the file grid and summary synchronously on Windows' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
        InModuleScope MediaNormalizer.Ui {
            Initialize-UiAssemblies

            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-grid-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            try {
                $audioPath = Join-Path $tmp 'voice.mp3'
                $videoPath = Join-Path $tmp 'clip.mp4'
                $otherPath = Join-Path $tmp 'notes.txt'
                foreach ($path in @($audioPath, $videoPath, $otherPath)) {
                    Set-Content -LiteralPath $path -Value 'fixture' -Encoding UTF8
                }

                $dgv = [Windows.Forms.DataGridView]::new()
                $dgv.AllowUserToAddRows = $false
                $audioColumn = [Windows.Forms.DataGridViewCheckBoxColumn]::new()
                $audioColumn.Name = 'Audio'
                [void]$dgv.Columns.Add($audioColumn)
                $videoColumn = [Windows.Forms.DataGridViewCheckBoxColumn]::new()
                $videoColumn.Name = 'Video'
                [void]$dgv.Columns.Add($videoColumn)
                foreach ($name in @('FileName', 'Ext', 'Size', 'Duration', 'SpeedPercent', 'FullName')) {
                    [void]$dgv.Columns.Add($name, $name)
                }
                $controls = @{
                    Dgv = $dgv
                    ChkAudio = [pscustomobject]@{ Checked = $true }
                    ChkVideo = [pscustomobject]@{ Checked = $true }
                    TxtInput = [pscustomobject]@{ Text = $tmp }
                    NumSpeed = [pscustomobject]@{ Value = 150 }
                    LblSummary = [pscustomobject]@{ Text = '' }
                    BtnRun = [pscustomobject]@{ Enabled = $false }
                }
                $state = [pscustomobject]@{
                    Controls = $controls
                    CachedFiles = @(
                        Get-Item -LiteralPath $audioPath
                        Get-Item -LiteralPath $videoPath
                        Get-Item -LiteralPath $otherPath
                    )
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
                }

                Update-FileGrid -State $state
                $dgv.Rows.Count | Should -Be 3
                $state.FileIndex.Count | Should -Be 3
                $state.DurationMap[$audioPath] | Should -Be -1
                $state.Controls.LblSummary.Text | Should -Match '音声: 2件 / 動画: 1件 / 全 3件'
                $dgv.Rows[2].DefaultCellStyle.ForeColor | Should -Be ([Drawing.Color]::Gray)
                $dgv.Rows[0].Cells['SpeedPercent'].Value | Should -Be 150
            } finally {
                $dgv.Dispose()
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'covers scan validation and asynchronous probe fallback on Windows' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
        InModuleScope MediaNormalizer.Ui {
            Initialize-UiAssemblies
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-grid-async-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            $dgv = $null
            try {
                $audioPath = Join-Path $tmp 'voice.mp3'
                Set-Content -LiteralPath $audioPath -Value 'fixture' -Encoding UTF8

                $stateForScan = [pscustomobject]@{
                    Controls = @{
                        TxtInput = [pscustomobject]@{ Text = '' }
                        ChkRecurse = [pscustomobject]@{ Checked = $true }
                    }
                    InputSelectionPaths = @()
                }
                Mock Clear-FileListWithError {}
                Update-FileList -State $stateForScan
                Should -Invoke Clear-FileListWithError -Times 1 -Exactly

                $stateForScan.Controls.TxtInput.Text = Join-Path $tmp 'missing'
                Update-FileList -State $stateForScan
                Should -Invoke Clear-FileListWithError -Times 2 -Exactly

                $stateForScan.Controls.TxtInput.Text = $tmp
                Mock Get-InputFiles { throw 'enumeration failure' }
                Update-FileList -State $stateForScan
                Should -Invoke Clear-FileListWithError -Times 3 -Exactly

                $dgv = [Windows.Forms.DataGridView]::new()
                $dgv.AllowUserToAddRows = $false
                $audioColumn = [Windows.Forms.DataGridViewCheckBoxColumn]::new()
                $audioColumn.Name = 'Audio'
                [void]$dgv.Columns.Add($audioColumn)
                $videoColumn = [Windows.Forms.DataGridViewCheckBoxColumn]::new()
                $videoColumn.Name = 'Video'
                [void]$dgv.Columns.Add($videoColumn)
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
                        BtnRun = [pscustomobject]@{ Enabled = $false }
                    }
                    CachedFiles = @([IO.FileInfo]$audioPath)
                    HasThreadJob = $true
                    PendingProbeJobs = @{}
                    ProbeTimer = $null
                    DurationMap = @{}
                    FileIndex = @{}
                    FullNameToRow = @{}
                    ProbeSummary = $null
                    RunningProcess = $false
                    LogBuffer = [Text.StringBuilder]::new()
                    ProbeScript = { param($path) -1.0 }
                    FfprobeAvailable = $false
                }
                Mock Start-ThreadJob { throw 'threadjob unavailable' }
                Update-FileGrid -State $state
                $state.DurationMap[$audioPath] | Should -Be -1
                $state.Controls.LblSummary.Text | Should -Match '全 1件'
                $state.Controls.BtnRun.Enabled | Should -BeTrue

                $state.HasThreadJob = $true
                $state.PendingProbeJobs = @{}
                $state.DurationMap = @{}
                $state.FullNameToRow = @{}
                $state.ProbeSummary = $null
                Mock Start-ThreadJob { [pscustomobject]@{ Id = 424242 } }
                Update-FileGrid -State $state
                $state.PendingProbeJobs.Count | Should -Be 1
                $state.ProbeTimer | Should -Not -BeNullOrEmpty
                $state.Controls.LblSummary.Text | Should -Match '計算中'
                $state.Controls.BtnRun.Enabled | Should -BeFalse
            } finally {
                if ($state -and $state.ProbeTimer) {
                    $state.ProbeTimer.Stop()
                    $state.ProbeTimer.Dispose()
                    $state.ProbeTimer = $null
                }
                if ($dgv) { $dgv.Dispose() }
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'adapts UI state to the Core normalize contract' {
        InModuleScope MediaNormalizer.Ui {
            $controls = @{
                CmbCollision = [pscustomobject]@{ SelectedItem = '連番付与' }
                TxtInput = [pscustomobject]@{ Text = 'C:\in' }
                TxtOutput = [pscustomobject]@{ Text = 'C:\out' }
                NumTarget = [pscustomobject]@{ Value = -100 }
                NumTP = [pscustomobject]@{ Value = -1 }
                CmbBR = [pscustomobject]@{ SelectedItem = '192k' }
                CmbSR = [pscustomobject]@{ SelectedItem = '48000' }
                NumSpeed = [pscustomobject]@{ Value = 125 }
                CmbAudioFormat = [pscustomobject]@{ SelectedItem = 'mp3' }
                ChkAnalyzeOnly = [pscustomobject]@{ Checked = $false }
                ChkSkipNormalized = [pscustomobject]@{ Checked = $true }
                ChkRecurse = [pscustomobject]@{ Checked = $true }
                ChkPreserveHierarchy = [pscustomobject]@{ Checked = $false }
            }
            $state = [pscustomobject]@{
                Controls = $controls
                InputSelectionPaths = @('C:\in\a.mp3')
                ReportPath = 'C:\out\report.json'
                LogBuffer = [Text.StringBuilder]::new()
            }
            $result = Invoke-NormalizeUi -State $state -Mode audio -TargetFiles @() -SpeedPercentByPath @{}
            $result.Fail | Should -Be 1
        }
    }

    It 'covers Show-MainForm validation and console hiding on Windows' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
        InModuleScope MediaNormalizer.Ui {
            { Show-MainForm -State ([pscustomobject]@{}) } | Should -Throw '*State.Form is null*'
            { Show-MainForm -State ([pscustomobject]@{ Form = 'not-a-form' }) } | Should -Throw '*not a System.Windows.Forms.Form*'
            $disposed = [Windows.Forms.Form]::new()
            $disposed.Dispose()
            { Show-MainForm -State ([pscustomobject]@{ Form = $disposed }) } | Should -Throw '*has been disposed*'
            { Set-ConsoleWindowHidden } | Should -Not -Throw
        }
    }

    It 'covers progress no-start and zero-total branches on Windows' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
        InModuleScope MediaNormalizer.Ui {
            Initialize-UiAssemblies
            $state = [pscustomobject]@{
                Controls = @{
                    PnlProgressBg = [pscustomobject]@{ Width = 100 }
                    PnlProgressFill = [pscustomobject]@{ Width = 0 }
                    LblProgress = [pscustomobject]@{ Text = '' }
                }
                ProcessingStartTime = $null
                ProcessedDurationSec = 0.0
                CurrentFileElapsedSec = 0.0
                TotalDurationSec = 0.0
            }
            Update-Progress -State $state -Current 0 -Total 3
            $state.Controls.LblProgress.Text | Should -Match '0 / 3 完了 \(0%\)'
            Update-Progress -State $state -Current 1 -Total 0
            $state.Controls.LblProgress.Text | Should -Match '0 / 3 完了'
            $state.ProcessingStartTime = (Get-Date).AddSeconds(-5)
            $state.ProcessedDurationSec = 10.0
            $state.CurrentFileElapsedSec = 2.0
            $state.TotalDurationSec = 20.0
            Update-Progress -State $state -Current 1 -Total 3
            $state.Controls.LblProgress.Text | Should -Match '残り'
            $state.TotalDurationSec = 0.0
            Update-Progress -State $state -Current 1 -Total 3
            $state.Controls.LblProgress.Text | Should -Match '残り'
            Update-Progress -State $state -Current 3 -Total 3
            $state.Controls.LblProgress.Text | Should -Match '完了'
        }
    }

    It 'rotates a persistent log when the active file reaches the limit' {
        InModuleScope MediaNormalizer.Ui {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-log-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            try {
                $logPath = Join-Path $tmp 'media-normalizer.log'
                Set-Content -LiteralPath $logPath -Value ('x' * (5MB + 1)) -Encoding UTF8
                $state = [pscustomobject]@{
                    LogBuffer = [Text.StringBuilder]::new()
                    LogPath = $logPath
                    Controls = @{ TxtLog = $null }
                    LogPersistenceWarningIssued = $false
                }
                Write-Log -State $state -Message 'rotated message'
                Write-LogBuffer -State $state
                Test-Path -LiteralPath ($logPath + '.1') | Should -BeTrue
                (Get-Content -LiteralPath $logPath -Raw) | Should -Match 'rotated message'
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'records a warning when persistent log storage fails' {
        InModuleScope MediaNormalizer.Ui {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-log-block-' + [guid]::NewGuid().ToString('N'))
            Set-Content -LiteralPath $tmp -Value 'blocking file' -Encoding UTF8
            try {
                $state = [pscustomobject]@{
                    LogBuffer = [Text.StringBuilder]::new()
                    LogPath = Join-Path $tmp 'media-normalizer.log'
                    Controls = @{ TxtLog = $null }
                    LogPersistenceWarningIssued = $false
                }
                Write-Log -State $state -Message 'will fail to persist'
                Write-LogBuffer -State $state
                $state.LogPersistenceWarningIssued | Should -BeTrue
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'drains completed probe jobs and updates the summary on Windows' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
        InModuleScope MediaNormalizer.Ui {
            Initialize-UiAssemblies
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mn-probe-latest-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            $samplePath = 'sample.mp4'
            $dgv = $null
            try {
                Mock -ModuleName MediaNormalizer.Ui Get-Job { [pscustomobject]@{ Id = 8101; State = 'Completed' } }
                Mock -ModuleName MediaNormalizer.Ui Receive-ProbeJobResult { [pscustomobject]@{ FullName = 'sample.mp4'; Duration = 8.0 } }
                Mock -ModuleName MediaNormalizer.Ui Remove-Job { }
                $dgv = [Windows.Forms.DataGridView]::new()
                $dgv.AllowUserToAddRows = $false
                $audio = [Windows.Forms.DataGridViewCheckBoxColumn]::new(); $audio.Name = 'Audio'; [void]$dgv.Columns.Add($audio)
                $video = [Windows.Forms.DataGridViewCheckBoxColumn]::new(); $video.Name = 'Video'; [void]$dgv.Columns.Add($video)
                foreach ($name in @('FileName', 'Ext', 'Size', 'Duration', 'SpeedPercent', 'FullName')) {
                    [void]$dgv.Columns.Add($name, $name)
                }
                $rowIndex = $dgv.Rows.Add($false, $true, 'sample.mp4', '.mp4', '1 KB', '取得中...', 100, $samplePath)
                $probeRow = $dgv.Rows[$rowIndex]
                $state = [pscustomobject]@{
                    PendingProbeJobs = @{ 8101 = @($samplePath) }
                    DurationMap = @{}
                    FileIndex = @{ $samplePath = [pscustomobject]@{ FullName = $samplePath; Extension = '.mp4'; Length = 1024L } }
                    FullNameToRow = @{ $samplePath = $probeRow }
                    ProbeTimer = $null
                    ProbeSummary = $null
                    ScanValid = $true
                    Controls = @{
                        Dgv = $dgv
                        ChkAudio = [pscustomobject]@{ Checked = $true }
                        ChkVideo = [pscustomobject]@{ Checked = $true }
                        ChkAnalyzeOnly = [pscustomobject]@{ Checked = $false }
                        LblSummary = [pscustomobject]@{ Text = '' }
                        BtnRun = [pscustomobject]@{ Enabled = $false }
                    }
                    RunningProcess = $false
                }
                Update-PendingProbeJobs -State $state
                $state.ProbeTimer | Should -BeNullOrEmpty
                $state.PendingProbeJobs.Count | Should -Be 0
                $state.DurationMap[$samplePath] | Should -Be 8
                $probeRow.Cells['Duration'].Value | Should -Be '0:08'
                $state.Controls.LblSummary.Text | Should -Match '動画: 1件 / 全 1件'
                $state.Controls.BtnRun.Enabled | Should -BeTrue
                $state.ProbeSummary | Should -BeNullOrEmpty
            } finally {
                if ($dgv) { $dgv.Dispose() }
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'cleans up a probe timer when a queued job has disappeared' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
        InModuleScope MediaNormalizer.Ui {
            Initialize-UiAssemblies
            $state = [pscustomobject]@{
                PendingProbeJobs = @{ 654322 = @('missing.mp4') }
                DurationMap = @{}
                FileIndex = @{}
                FullNameToRow = @{}
                ProbeTimer = $null
                ProbeSummary = $null
                ScanValid = $true
                Controls = @{
                    Dgv = [Windows.Forms.DataGridView]::new()
                    ChkAudio = [pscustomobject]@{ Checked = $true }
                    ChkVideo = [pscustomobject]@{ Checked = $true }
                    ChkAnalyzeOnly = [pscustomobject]@{ Checked = $false }
                    LblSummary = [pscustomobject]@{ Text = '' }
                    BtnRun = [pscustomobject]@{ Enabled = $false }
                }
                RunningProcess = $false
            }
            try {
                Mock -ModuleName MediaNormalizer.Ui Get-Job { $null }
                Update-PendingProbeJobs -State $state
                $state.ProbeTimer | Should -BeNullOrEmpty
                $state.PendingProbeJobs.Count | Should -Be 0
                $state.Controls.BtnRun.Enabled | Should -BeTrue
                $state.ProbeSummary | Should -BeNullOrEmpty
            } finally {
                if ($state.ProbeTimer) {
                    $state.ProbeTimer.Stop()
                    $state.ProbeTimer.Dispose()
                    $state.ProbeTimer = $null
                }
                $state.Controls.Dgv.Dispose()
            }
        }
    }

    It 'handles a completed probe job whose result cannot be received' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
        InModuleScope MediaNormalizer.Ui {
            Initialize-UiAssemblies
            try {
                Mock -ModuleName MediaNormalizer.Ui Get-Job { [pscustomobject]@{ Id = 999; State = 'Completed' } }
                Mock -ModuleName MediaNormalizer.Ui Receive-ProbeJobResult { throw 'receive failed' }
                Mock -ModuleName MediaNormalizer.Ui Remove-Job { }
                $state = [pscustomobject]@{
                    PendingProbeJobs = @{ 999 = @('broken.mp4') }
                    DurationMap = @{}
                    FileIndex = @{}
                    FullNameToRow = @{}
                    ProbeTimer = $null
                    ProbeSummary = $null
                    ScanValid = $true
                    Controls = @{
                        Dgv = [Windows.Forms.DataGridView]::new()
                        ChkAudio = [pscustomobject]@{ Checked = $true }
                        ChkVideo = [pscustomobject]@{ Checked = $true }
                        ChkAnalyzeOnly = [pscustomobject]@{ Checked = $false }
                        LblSummary = [pscustomobject]@{ Text = '' }
                        BtnRun = [pscustomobject]@{ Enabled = $false }
                    }
                    RunningProcess = $false
                }
                Update-PendingProbeJobs -State $state
                $state.ProbeTimer | Should -BeNullOrEmpty
                $state.PendingProbeJobs.Count | Should -Be 0
                $state.ProbeSummary | Should -BeNullOrEmpty
            } finally {
                if ($state -and $state.Controls.Dgv) { $state.Controls.Dgv.Dispose() }
            }
        }
    }

    It 'constructs the main form and exercises non-modal UI handlers on Windows' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
        InModuleScope MediaNormalizer.Ui {
            Initialize-UiAssemblies
            Mock Initialize-ThreadJob { $false }
            Mock Read-Settings {
                [pscustomobject]@{
                    Values = @{ InputDir = ''; OutputDir = ''; LastPreset = 'デフォルト'; LastMode = 'both' }
                    Warnings = @('test settings warning')
                }
            }
            Mock Save-Settings {}
            Mock Write-LogBuffer {}
            Mock Invoke-Item {}

            $state = New-MediaNormalizerState
            Initialize-UiState -State $state | Out-Null
            $state.ThreadJobSetupWarning = 'test threadjob warning'
            $form = $null
            $openRoot = Join-Path ([IO.Path]::GetTempPath()) ('mn-ui-open-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $openRoot -Force | Out-Null
            try {
                $form = New-MainForm -State $state
                $form | Should -BeOfType [Windows.Forms.Form]
                $state.Controls.CmbPreset.Items.Count | Should -BeGreaterThan 0
                $form.Show()
                [Windows.Forms.Application]::DoEvents()

                if ($state.Controls.CmbPreset.Items.Count -gt 1) {
                    $state.Controls.CmbPreset.SelectedIndex = 1
                    $state.Controls.CmbPreset.SelectedIndex = 0
                }
                $state.Controls.ChkAudio.Checked = $true
                $state.Controls.ChkAudio.Checked = $false
                $state.Controls.ChkVideo.Checked = $true
                $state.Controls.ChkVideo.Checked = $false
                $state.Controls.ChkRecurse.Checked = $false
                $state.Controls.ChkRecurse.Checked = $true
                $state.Controls.ChkAnalyzeOnly.Checked = $true
                $state.Controls.BtnRun.Text | Should -Be '解析してレポート作成'
                $state.Controls.ChkAnalyzeOnly.Checked = $false
                $state.Controls.BtnRun.Text | Should -Be '実行'

                $state.Controls.Dgv.Rows.Add() | Out-Null
                $state.Controls.NumSpeed.Value = 150
                { $state.Controls.BtnApplySpeed.PerformClick() } | Should -Not -Throw

                $state.Controls.TxtInput.Text = Join-Path ([IO.Path]::GetTempPath()) 'media-normalizer-missing-input'
                $state.Controls.BtnScanFiles.PerformClick()
                $state.Controls.BtnOpenInput.PerformClick()
                $state.Controls.TxtOutput.Text = Join-Path ([IO.Path]::GetTempPath()) 'media-normalizer-missing-output'
                $state.Controls.BtnOpenOutput.PerformClick()
                $state.Controls.TxtInput.Text = $openRoot
                $state.Controls.BtnOpenInput.PerformClick()
                $state.Controls.TxtOutput.Text = $openRoot
                $state.Controls.BtnOpenOutput.PerformClick()

                Mock Update-FileList { throw 'scan failure' }
                $state.Controls.BtnScanFiles.PerformClick()
                $state.ScanValid = $true
                Mock Update-FileGrid {}
                $state.Controls.ChkAudio.Checked = $true
                $state.Controls.ChkAudio.Checked = $false
                $state.Controls.ChkVideo.Checked = $true
                $state.Controls.ChkVideo.Checked = $false
                Mock Update-FileList {}
                $state.Controls.ChkRecurse.Checked = $false
                $state.Controls.ChkRecurse.Checked = $true
                $state.ApplyingInputSelection = $true
                $state.Controls.TxtInput.Text = 'ignored while applying selection'
                $state.ApplyingInputSelection = $false
                $state.Controls.TxtOutput.Text = ''
                $state.Controls.BtnRun.PerformClick()

                $runRoot = Join-Path ([IO.Path]::GetTempPath()) ('mn-ui-run-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
                try {
                    $state.Controls.TxtInput.Text = $runRoot
                    $state.Controls.TxtOutput.Text = $runRoot
                    $state.Controls.CmbPreset.SelectedIndex = -1
                    $state.Controls.BtnRun.PerformClick()
                    $state.LogBuffer.ToString() | Should -Match '選択中のプリセットを解決できません'

                } finally {
                    Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
                }

                $state.Controls.BtnCancel.PerformClick()
                $state.Controls.BtnCancel.PerformClick()
                $state.RunningProcess = [pscustomobject]@{ HasExited = $false }
                $state.CancelRequested = $true
                $form.Close()
                $state.RunningProcess = $null
                $form.Close()
            } finally {
                if (Test-Path -LiteralPath $openRoot) {
                    Remove-Item -LiteralPath $openRoot -Recurse -Force -ErrorAction SilentlyContinue
                }
                if ($form -and -not $form.IsDisposed) {
                    $form.Dispose()
                }
                if ($state.LogTimer) {
                    try { $state.LogTimer.Stop() } catch { }
                    try { $state.LogTimer.Dispose() } catch { }
                    $state.LogTimer = $null
                }
            }
        }
    }
}
