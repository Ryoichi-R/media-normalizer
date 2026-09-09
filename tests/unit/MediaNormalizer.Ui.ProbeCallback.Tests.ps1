#Requires -Modules Pester
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../lib/MediaNormalizer.Ui.psm1') -Force
}
Describe 'Probe timer callback module scope' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
    It 'completes an empty probe queue through the real timer delegate outside module scope' {
        $module = Get-Module MediaNormalizer.Ui
        $state = & $module {
            Initialize-UiAssemblies
            $state = [pscustomobject]@{
                Controls = @{ Dgv = $null; BtnRun = [Windows.Forms.Button]::new() }
                PendingProbeJobs = @{}
                ProbeTimer = $null
                ProbeSummary = 'pending'
                ScanValid = $true
                OperationState = 'Idle'
            }
            $state.Controls.BtnRun.Enabled = $false
            Start-ProbeTimer -State $state
            $state
        }
        $timer = $state.ProbeTimer
        try {
            $tick = [Windows.Forms.Timer].GetMethod('OnTick', [Reflection.BindingFlags]'Instance, NonPublic')
            { $tick.Invoke($timer, @([EventArgs]::Empty)) } | Should -Not -Throw
            $state.ProbeTimer | Should -BeNullOrEmpty
            $state.ProbeSummary | Should -BeNullOrEmpty
            $state.Controls.BtnRun.Enabled | Should -BeTrue
        } finally {
            $timer.Dispose()
            $state.Controls.BtnRun.Dispose()
        }
    }
}

Describe 'Async probe and mode selection in a fresh process' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
    It 'preserves UI module function resolution after starting a real ThreadJob' {
        $fixture = Join-Path $TestDrive 'fixture.mp4'
        Set-Content $fixture 'fixture'
        $runner = Join-Path $PSScriptRoot 'Invoke-ProbeCallbackRegression.ps1'
        $library = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../lib'))
        $output = & pwsh -STA -NoProfile -File $runner -LibraryRoot $library -FixturePath $fixture 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }
}
