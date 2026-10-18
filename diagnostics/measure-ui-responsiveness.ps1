#Requires -Version 5.1
<#
.SYNOPSIS
    実行中の media-normalizer GUI プロセスのウィンドウ応答性を計測する。
.DESCRIPTION
    TODO.md MN-10 / plans/media-normalizer-ui-responsiveness-remediation-plan.md Phase 0 (設計判断9)。
    指定 PID (MediaNormalizer.exe の launcher ではなく、GUI ウィンドウを実際に持つ子 pwsh の PID)
    から可視トップレベル HWND を解決し、副作用のない WM_NULL のみを SendMessageTimeout で送って
    応答遅延を計測する。IsHungAppWindow は補助指標として併記する(設計判断9: 単独では合否判定しない)。
    送信は WM_NULL のみで、ウィンドウの状態を変更する操作は一切行わない。
.PARAMETER ProcessId
    GUI ウィンドウを保持するプロセスの PID。launcher (MediaNormalizer.exe) の PID ではなく、
    その子として起動される pwsh の PID を指定すること(Program.cs:100-101 参照)。
.PARAMETER DurationSeconds
    計測を継続する秒数。
.PARAMETER IntervalMilliseconds
    サンプリング間隔(既定 250ms)。
.PARAMETER OutputCsvPath
    結果を追記する CSV パス。列: 時刻, HWND, IsHung, 応答遅延ms, HWND変化, ゴースト化, pwsh CPU%
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$ProcessId,
    [int]$DurationSeconds = 30,
    [int]$IntervalMilliseconds = 250,
    [Parameter(Mandatory)][string]$OutputCsvPath
)

Add-Type -Namespace MediaNormalizerDiag -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

[DllImport("user32.dll")]
public static extern bool IsWindowVisible(IntPtr hWnd);

[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
    uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

[DllImport("user32.dll")]
public static extern bool IsHungAppWindow(IntPtr hWnd);
'@

$WM_NULL = 0x0000
$SMTO_NORMAL = 0x0000
$TIMEOUT_MS = 1000

function Resolve-VisibleTopLevelWindow {
    param([Parameter(Mandatory)][int]$TargetProcessId)

    # 注意: このコールバックは関数パラメータを直接クロージャ捕捉すると、
    # EnumWindows からのコールバック実行時に値が失われることがある(実測で確認済み)。
    # script スコープ変数経由で受け渡すことで確実に伝播させる。
    $script:_resolvedHwnd = [IntPtr]::Zero
    $script:_targetProcessIdForEnum = $TargetProcessId
    $callback = {
        param($hWnd, $lParam)
        $procId = 0
        [void][MediaNormalizerDiag.NativeMethods]::GetWindowThreadProcessId($hWnd, [ref]$procId)
        if ($procId -eq $script:_targetProcessIdForEnum -and [MediaNormalizerDiag.NativeMethods]::IsWindowVisible($hWnd)) {
            $script:_resolvedHwnd = $hWnd
        }
        return $true
    }
    [void][MediaNormalizerDiag.NativeMethods]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:_resolvedHwnd
}

if (-not (Test-Path -LiteralPath (Split-Path -Parent $OutputCsvPath))) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $OutputCsvPath))
}
if (-not (Test-Path -LiteralPath $OutputCsvPath)) {
    '時刻,HWND,IsHung,応答遅延ms,HWND変化,ゴースト化,pwsh CPU%' | Set-Content -LiteralPath $OutputCsvPath -Encoding UTF8
}

try {
    $targetProcess = Get-Process -Id $ProcessId -ErrorAction Stop
} catch {
    throw "PID $ProcessId のプロセスが見つかりません: $($_.Exception.Message)"
}

$lastHwnd = [IntPtr]::Zero
$lastCpuTime = $targetProcess.TotalProcessorTime
$lastSampleAt = Get-Date
$processorCount = [Environment]::ProcessorCount
$deadline = (Get-Date).AddSeconds($DurationSeconds)

while ((Get-Date) -lt $deadline) {
    $now = Get-Date
    $hwnd = Resolve-VisibleTopLevelWindow -TargetProcessId $ProcessId
    $hwndChanged = ($hwnd -ne [IntPtr]::Zero -and $lastHwnd -ne [IntPtr]::Zero -and $hwnd -ne $lastHwnd)

    $isHung = $false
    $latencyMs = -1
    $ghosted = $false
    if ($hwnd -eq [IntPtr]::Zero) {
        $ghosted = $true
    } else {
        $isHung = [MediaNormalizerDiag.NativeMethods]::IsHungAppWindow($hwnd)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $result = [IntPtr]::Zero
        [void][MediaNormalizerDiag.NativeMethods]::SendMessageTimeout(
            $hwnd, $WM_NULL, [IntPtr]::Zero, [IntPtr]::Zero,
            $SMTO_NORMAL, $TIMEOUT_MS, [ref]$result)
        $sw.Stop()
        $latencyMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    }

    $cpuPercent = 0.0
    try {
        $targetProcess.Refresh()
        $currentCpuTime = $targetProcess.TotalProcessorTime
        $deltaCpu = ($currentCpuTime - $lastCpuTime).TotalSeconds
        $deltaWall = ($now - $lastSampleAt).TotalSeconds
        if ($deltaWall -gt 0) {
            $cpuPercent = [math]::Round(($deltaCpu / ($deltaWall * $processorCount)) * 100.0, 1)
        }
        $lastCpuTime = $currentCpuTime
    } catch {
        # プロセス終了直後などは無視する。
    }
    $lastSampleAt = $now

    $line = '{0:o},{1},{2},{3},{4},{5},{6}' -f `
        $now, $hwnd, $isHung, $latencyMs, $hwndChanged, $ghosted, $cpuPercent
    Add-Content -LiteralPath $OutputCsvPath -Value $line -Encoding UTF8

    if ($hwnd -ne [IntPtr]::Zero) { $lastHwnd = $hwnd }

    Start-Sleep -Milliseconds $IntervalMilliseconds
}

Write-Host "計測完了: $OutputCsvPath"
