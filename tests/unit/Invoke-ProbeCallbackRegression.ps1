param([string]$LibraryRoot, [string]$FixturePath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $LibraryRoot 'MediaNormalizer.Core.psm1') -Force
Import-Module (Join-Path $LibraryRoot 'MediaNormalizer.Probe.psm1') -Force
Import-Module (Join-Path $LibraryRoot 'MediaNormalizer.Ui.psm1') -Force
$m = Get-Module MediaNormalizer.Ui
& $m {
    Set-Item function:script:Read-Settings { [pscustomobject]@{ Values = @{InputDir='';OutputDir='';LastPreset='デフォルト';LastMode='video'}; Warnings=@() } }
    Set-Item function:script:Save-Settings {}
    Set-Item function:script:Write-LogBuffer {}
}
$state = Initialize-UiState -State (New-MediaNormalizerState)
$form = New-MainForm -State $state
try {
    $state.LogTimer.Stop()
    $state.HasThreadJob = $true
    $state.Controls.TxtInput.Text = ''
    $state.CachedFiles = @(Get-Item $FixturePath)
    $state.ScanValid = $true
    & $m { param($s) Update-FileGrid -State $s } $state
    [Threading.Thread]::Sleep(1000)
    if ($state.ProbeTimer) { [void][Windows.Forms.Timer].GetMethod('OnTick', [Reflection.BindingFlags]'Instance, NonPublic').Invoke($state.ProbeTimer, @([EventArgs]::Empty)) }
    $state.Controls.ChkAudio.Checked = $true
    $state.Controls.ChkVideo.Checked = $false
    if ($state.Controls.Dgv.Rows[0].Cells['Audio'].Value -ne $true -or $state.Controls.Dgv.Rows[0].Cells['Video'].Value -ne $false) { throw 'Mode selection did not propagate' }
    [pscustomobject]@{ Audio=$state.Controls.Dgv.Rows[0].Cells['Audio'].Value; Video=$state.Controls.Dgv.Rows[0].Cells['Video'].Value; Summary=$state.Controls.LblSummary.Text }
} finally { $form.Dispose(); if($state.ProbeTimer){$state.ProbeTimer.Dispose()}; $state.LogTimer.Dispose() }
