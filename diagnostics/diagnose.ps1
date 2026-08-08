#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnostic launcher for media-normalizer.ps1
.DESCRIPTION
    Loads the main GUI script and writes startup/runtime errors to diagnose.log.
#>

$diagLog = Join-Path $PSScriptRoot 'diagnose.log'
"=== Diagnose Start: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Out-File -LiteralPath $diagLog -Encoding utf8

function Write-Diag {
    param([string]$Msg)
    $ts = Get-Date -Format 'HH:mm:ss.fff'
    "[$ts] $Msg" | Out-File -LiteralPath $diagLog -Append -Encoding utf8
}

Write-Diag ("PowerShell: {0}" -f $PSVersionTable.PSVersion)
Write-Diag ("OS: {0}" -f [System.Environment]::OSVersion.VersionString)
Write-Diag (".NET: {0}" -f [System.Runtime.InteropServices.RuntimeEnvironment]::GetSystemVersion())
Write-Diag ("ScriptRoot: {0}" -f $PSScriptRoot)

try {
    Add-Type -AssemblyName System.Windows.Forms
    Write-Diag 'WinForms: OK'
} catch {
    Write-Diag ("WinForms: FAIL - {0}" -f $_.Exception.Message)
}

try {
    Add-Type -AssemblyName System.Drawing
    Write-Diag 'Drawing: OK'
} catch {
    Write-Diag ("Drawing: FAIL - {0}" -f $_.Exception.Message)
}

[System.Windows.Forms.Application]::SetUnhandledExceptionMode(
    [System.Windows.Forms.UnhandledExceptionMode]::CatchException
)
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Write-Diag ("ThreadException: {0}" -f $e.Exception.Message)
    Write-Diag ("StackTrace: {0}" -f $e.Exception.StackTrace)
    [System.Windows.Forms.MessageBox]::Show(
        ("Runtime error: {0}`n`nSee diagnose.log for details." -f $e.Exception.Message),
        'Diagnose',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
})

Write-Diag '=== Loading main script ==='

# T1-3: 呼び出し前後・例外・finally をすべて記録し脱出点を可視化する
# - dot-source(`.`) から call operator(`&`) に変更: 呼び出し先 exit による diagnose.ps1 強制終了を回避
# - media-normalizer.ps1 末尾の `exit 0` は削除済みのため、ShowDialog 戻り後に finally へ遷移する
$normalExit = $false
try {
    Write-Diag '>>> Invoking main script'
    & "$PSScriptRoot\media-normalizer.ps1"
    Write-Diag '<<< Main script returned'
    $normalExit = $true
} catch {
    $line = $_.InvocationInfo.ScriptLineNumber
    $msg = $_.Exception.Message
    $stack = $_.ScriptStackTrace

    Write-Diag ("FATAL: {0}" -f $msg)
    Write-Diag ("Line: {0}" -f $line)
    Write-Diag ("Stack: {0}" -f $stack)

    [System.Windows.Forms.MessageBox]::Show(
        ("Startup error: {0}`n`nLine: {1}`n`nSee diagnose.log for details." -f $msg, $line),
        'Diagnose',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
} finally {
    if ($normalExit) {
        Write-Diag 'Main script exited normally'
    } else {
        Write-Diag 'Main script exited via exception path'
    }
    Write-Diag ("=== Diagnose End: {0} ===" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
}
