#Requires -Version 5.1

param(
    [switch]$Cli,
    [string]$InputDir,
    [Alias('InputFile')][string[]]$InputPath,
    [string]$OutputDir,
    [ValidateSet('audio', 'video', 'both')][string]$Mode = 'audio',
    [string]$Preset = 'デフォルト',
    [int]$SpeedPercent = 100,
    [ValidateSet('mp3', 'm4a', 'aac', 'flac', 'wav', 'opus', 'ogg')]
    [string]$AudioOutputFormat = 'mp3',
    [switch]$AnalyzeOnly,
    [bool]$SkipIfNormalized = $true,
    [ValidateRange(0.0, 10.0)][double]$NormalizationTolerance = 0.5,
    [bool]$Recurse = $true,
    [bool]$PreserveHierarchy = $true,
    [ValidateSet('rename', 'skip', 'overwrite')]
    [string]$CollisionPolicy = 'rename',
    [string]$ReportPath
)

$moduleRoot = Join-Path $PSScriptRoot 'lib'
Import-Module (Join-Path $moduleRoot 'MediaNormalizer.Platform.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'MediaNormalizer.Probe.psm1') -Force
Import-Module (Join-Path $moduleRoot 'MediaNormalizer.Progress.psm1') -Force
Import-Module (Join-Path $moduleRoot 'MediaNormalizer.Core.psm1') -Force

# 同梱modeでは子processとThreadJobへ固定runtimeの実体pathを渡す。
if (-not [string]::IsNullOrWhiteSpace($env:MEDIA_NORMALIZER_RUNTIME_ROOT)) {
    $env:FFMPEG_PATH = Resolve-MediaNormalizerCommand -Name FFmpeg
    $env:FFPROBE_PATH = Resolve-MediaNormalizerCommand -Name FFprobe
    $env:MEDIA_NORMALIZER_PYTHON = Resolve-MediaNormalizerCommand -Name Python
}

# Installer が launcher 強制終了後も実行中の PowerShell 本体を検出できるよう、
# プロセス存続中は専用ファイルを排他的に開く。存在ではなくハンドル競合を使う。
$script:MediaNormalizerRunningLock = $null
$script:MediaNormalizerCliRun = $null
$mediaNormalizerPlatform = Get-MediaNormalizerPlatform
if ($mediaNormalizerPlatform -eq 'Windows') {
    $runningLockPath = Join-Path $PSScriptRoot '.media-normalizer-running.lock'
    try {
        $script:MediaNormalizerRunningLock = [IO.File]::Open(
            $runningLockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None)
    }
    catch [IO.IOException] {
        Write-Error 'Media Normalizer は既に起動しています。'
        exit 2
    }
}

if ($Cli) {
    $missing = @()
    if ([string]::IsNullOrWhiteSpace($InputDir) -and
        (-not $InputPath -or $InputPath.Count -eq 0)) {
        $missing += '-InputPath または -InputDir'
    }
    if ([string]::IsNullOrWhiteSpace($OutputDir)) { $missing += '-OutputDir' }
    if ($missing.Count -gt 0) {
        Write-Host "[ERROR] CLI モードでは次のパラメータが必須です: $($missing -join ', ')" -ForegroundColor Red
        Write-Host ''
        Write-Host '使い方:' -ForegroundColor Yellow
        Write-Host '  media-normalizer.ps1 -Cli -InputPath <ファイル/フォルダ> -OutputDir <出力フォルダ> [-Mode audio|video|both] [-AudioOutputFormat mp3|m4a|aac|flac|wav|opus|ogg] [-AnalyzeOnly]'
        Write-Host ''
        Write-Host '例:'
        Write-Host '  media-normalizer.ps1 -Cli -InputPath "C:\media\in" -OutputDir "C:\media\out" -Mode both -Preset "デフォルト" -AudioOutputFormat flac'
        Write-Host '  media-normalizer.ps1 -Cli -InputFile "C:\media\sample.wav" -OutputDir "C:\media\report" -AnalyzeOnly'
        exit 2
    }

    if ($mediaNormalizerPlatform -eq 'macOS') {
        Import-Module (Join-Path $moduleRoot 'MediaNormalizer.RunRecovery.psm1') -Force -DisableNameChecking
        $storageRoot = Split-Path -Parent (Get-MediaNormalizerStoragePath -Kind Settings)
        try {
            $script:MediaNormalizerCliRun = Enter-MediaNormalizerCliRun -StorageRoot $storageRoot
        } catch {
            $message = [string]$_.Exception.Message
            Write-Error $message
            if ($message -match '^\[JOB_ALREADY_RUNNING\]') { exit 3 }
            if ($message -match '^\[RECOVERY_REQUIRED\]') { exit 4 }
            exit 2
        }
    }

    $cliParams = @{}
    foreach ($key in @(
            'InputDir',
            'InputPath',
            'OutputDir',
            'Mode',
            'Preset',
            'SpeedPercent',
            'AudioOutputFormat',
            'AnalyzeOnly',
            'SkipIfNormalized',
            'NormalizationTolerance',
            'Recurse',
            'PreserveHierarchy',
            'CollisionPolicy',
            'ReportPath')) {
        if ($PSBoundParameters.ContainsKey($key)) {
            $cliParams[$key] = $PSBoundParameters[$key]
        }
    }
    Invoke-NormalizeCli @cliParams
    if ($script:MediaNormalizerCliRun) {
        try {
            Complete-MediaNormalizerCliRun -Run $script:MediaNormalizerCliRun -ExitCode $LASTEXITCODE `
                -RecoveryRequired:($LASTEXITCODE -eq 4) | Out-Null
        } catch {
            Write-Error "[RECOVERY_REQUIRED] CLI run記録を確定できません: $($_.Exception.Message)"
            exit 4
        }
    }
    exit $LASTEXITCODE
}

# GUI 経路のみで Ui.psm1 を import する（WinForms / Native.Win32 / ThreadJob 初期化を遅延）
Import-Module (Join-Path $moduleRoot 'MediaNormalizer.Ui.psm1') -Force

$state = New-MediaNormalizerState
$state = Initialize-UiState -State $state
New-MainForm -State $state | Out-Null
Set-ConsoleWindowHidden
Show-MainForm -State $state
