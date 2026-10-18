Set-StrictMode -Version Latest

function Get-MediaNormalizerPlatform {
    [CmdletBinding()]
    param()

    $windowsFlag = Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $windowsFlag) { if ($windowsFlag) { return 'Windows' } }
    elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return 'Windows' }

    $macOsFlag = Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $macOsFlag -and $macOsFlag) { return 'macOS' }
    $linuxFlag = Get-Variable -Name IsLinux -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $linuxFlag -and $linuxFlag) { return 'Linux' }
    return 'Unknown'
}

function Get-MediaNormalizerRuntimeExecutablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][ValidateSet('FFmpeg', 'FFprobe', 'Python', 'PowerShell')][string]$Name,
        [ValidateSet('Windows', 'macOS', 'Linux')][string]$Platform = (Get-MediaNormalizerPlatform)
    )

    $relativePath = switch ($Name) {
        'FFmpeg' {
            if ($Platform -eq 'Windows') { 'ffmpeg/bin/ffmpeg.exe' } else { 'ffmpeg/bin/ffmpeg' }
        }
        'FFprobe' {
            if ($Platform -eq 'Windows') { 'ffmpeg/bin/ffprobe.exe' } else { 'ffmpeg/bin/ffprobe' }
        }
        'Python' {
            if ($Platform -eq 'Windows') { 'python/python.exe' } else { 'python/bin/python3' }
        }
        'PowerShell' {
            if ($Platform -eq 'Windows') { 'powershell/pwsh.exe' } else { 'powershell/pwsh' }
        }
    }

    $path = [IO.Path]::GetFullPath($RuntimeRoot)
    foreach ($segment in $relativePath.Split('/')) {
        $path = Join-Path $path $segment
    }
    return $path
}

function Get-MediaNormalizerBinaryArchitecture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        $header = [byte[]]::new([int][math]::Min(64, $stream.Length))
        if ($header.Length -lt 4) { return 'unknown' }
        $read = $stream.Read($header, 0, $header.Length)
        if ($read -lt 4) { return 'unknown' }

        if ($header[0] -eq 0x4d -and $header[1] -eq 0x5a) {
            if ($read -lt 64) { return 'unknown' }
            $peOffset = [BitConverter]::ToInt32($header, 0x3c)
            if ($peOffset -lt 0 -or ($peOffset + 6) -gt $stream.Length) { return 'unknown' }
            $stream.Position = $peOffset
            $peHeader = [byte[]]::new(6)
            if ($stream.Read($peHeader, 0, 6) -ne 6 -or
                $peHeader[0] -ne 0x50 -or $peHeader[1] -ne 0x45 -or
                $peHeader[2] -ne 0 -or $peHeader[3] -ne 0) { return 'unknown' }
            $machine = [BitConverter]::ToUInt16($peHeader, 4)
            $architecture = switch ($machine) {
                0x8664 { 'x64' }
                0xaa64 { 'arm64' }
                0x014c { 'x86' }
                default { 'unknown' }
            }
            return $architecture
        }

        if ($header[0] -eq 0x7f -and $header[1] -eq 0x45 -and $header[2] -eq 0x4c -and $header[3] -eq 0x46) {
            if ($read -lt 20) { return 'unknown' }
            $machine = if ($header[5] -eq 2) {
                [uint16](([uint16]$header[18] -shl 8) -bor [uint16]$header[19])
            } else {
                [uint16](([uint16]$header[19] -shl 8) -bor [uint16]$header[18])
            }
            $architecture = switch ($machine) {
                62 { 'x64' }
                183 { 'arm64' }
                3 { 'x86' }
                default { 'unknown' }
            }
            return $architecture
        }

        $littleMachO = $header[0] -eq 0xcf -and $header[1] -eq 0xfa -and $header[2] -eq 0xed -and $header[3] -eq 0xfe
        $bigMachO = $header[0] -eq 0xfe -and $header[1] -eq 0xed -and $header[2] -eq 0xfa -and $header[3] -in @(0xce, 0xcf)
        if ($littleMachO -or $bigMachO) {
            if ($read -lt 8) { return 'unknown' }
            $cpuType = if ($littleMachO) {
                [BitConverter]::ToUInt32($header, 4)
            } else {
                [uint32](([uint32]$header[4] -shl 24) -bor ([uint32]$header[5] -shl 16) -bor ([uint32]$header[6] -shl 8) -bor [uint32]$header[7])
            }
            $architecture = switch ($cpuType) {
                0x0100000c { 'arm64' }
                0x01000007 { 'x64' }
                12 { 'arm' }
                7 { 'x86' }
                default { 'unknown' }
            }
            return $architecture
        }

        return 'unknown'
    } finally {
        $stream.Dispose()
    }
}

function Assert-MediaNormalizerWritablePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $normalizedPath = [IO.Path]::GetFullPath($Path).Replace('\', '/')
    if ($normalizedPath -match '(?i)\.app/Contents(?:/|$)') {
        throw "アプリbundleのContents以下は書き込み先にできません: $normalizedPath"
    }
    return $normalizedPath
}

function Get-MediaNormalizerStoragePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Settings', 'UserPresets', 'Log', 'GuiLock', 'JobLock', 'RecoveryGuard', 'RunRecord', 'GuiInstance')][string]$Kind,
        [string]$StorageRoot,
        [ValidateSet('Windows', 'macOS', 'Linux')][string]$Platform = (Get-MediaNormalizerPlatform)
    )

    if (-not [string]::IsNullOrWhiteSpace($StorageRoot)) {
        $root = [IO.Path]::GetFullPath($StorageRoot)
        $relativePath = switch ($Kind) {
            'Settings' { 'settings.json' }
            'UserPresets' { 'presets.user.json' }
            'Log' { 'logs/media-normalizer.log' }
            'GuiLock' { 'run/gui-instance.lock' }
            'JobLock' { 'run/normalization-job.lock' }
            'RecoveryGuard' { 'run/recovery-guard.lock' }
            'RunRecord' { 'run/active-run.json' }
            'GuiInstance' { 'run/gui-instance.json' }
        }
    } elseif ($Platform -eq 'Windows') {
        $root = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'media-normalizer'
        $relativePath = switch ($Kind) {
            'Settings' { 'settings.json' }
            'UserPresets' { 'presets.user.json' }
            'Log' { 'media-normalizer.log' }
            'GuiLock' { 'run/gui-instance.lock' }
            'JobLock' { 'run/normalization-job.lock' }
            'RecoveryGuard' { 'run/recovery-guard.lock' }
            'RunRecord' { 'run/active-run.json' }
            'GuiInstance' { 'run/gui-instance.json' }
        }
    } else {
        $homePath = [Environment]::GetFolderPath('UserProfile')
        if ([string]::IsNullOrWhiteSpace($homePath)) { $homePath = [Environment]::GetEnvironmentVariable('HOME') }
        if ([string]::IsNullOrWhiteSpace($homePath)) { throw 'ユーザーhome pathを解決できません。' }
        if ($Platform -eq 'macOS') {
            $supportRoot = Join-Path (Join-Path $homePath 'Library') 'Application Support/media-normalizer'
            if ($Kind -eq 'Log') {
                $root = Join-Path (Join-Path $homePath 'Library/Logs') 'media-normalizer'
                $relativePath = 'media-normalizer.log'
            } else {
                $root = $supportRoot
                $relativePath = switch ($Kind) {
                    'Settings' { 'settings.json' }
                    'UserPresets' { 'presets.user.json' }
                    'Log' { 'media-normalizer.log' }
                    'GuiLock' { 'run/gui-instance.lock' }
                    'JobLock' { 'run/normalization-job.lock' }
                    'RecoveryGuard' { 'run/recovery-guard.lock' }
                    'RunRecord' { 'run/active-run.json' }
                    'GuiInstance' { 'run/gui-instance.json' }
                }
            }
        } else {
            $root = [Environment]::GetEnvironmentVariable('XDG_STATE_HOME')
            if ([string]::IsNullOrWhiteSpace($root)) { $root = Join-Path $homePath '.local/state' }
            $root = Join-Path $root 'media-normalizer'
            $relativePath = switch ($Kind) {
                'Settings' { 'settings.json' }
                'UserPresets' { 'presets.user.json' }
                'Log' { 'media-normalizer.log' }
                'GuiLock' { 'run/gui-instance.lock' }
                'JobLock' { 'run/normalization-job.lock' }
                'RecoveryGuard' { 'run/recovery-guard.lock' }
                'RunRecord' { 'run/active-run.json' }
                'GuiInstance' { 'run/gui-instance.json' }
            }
        }
    }

    $path = $root
    foreach ($segment in $relativePath.Split('/')) { $path = Join-Path $path $segment }
    return Assert-MediaNormalizerWritablePath -Path $path
}

function Resolve-MediaNormalizerCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('FFmpeg', 'FFprobe', 'Python', 'PowerShell')][string]$Name,
        [string]$RuntimeRoot,
        [ValidateSet('Windows', 'macOS', 'Linux')][string]$Platform = (Get-MediaNormalizerPlatform),
        [switch]$Required
    )

    $overrideName = switch ($Name) {
        'FFmpeg' { 'FFMPEG_PATH' }
        'FFprobe' { 'FFPROBE_PATH' }
        'Python' { 'MEDIA_NORMALIZER_PYTHON' }
        'PowerShell' { $null }
    }
    if ($overrideName) {
        $overridePath = [Environment]::GetEnvironmentVariable($overrideName)
        if (-not [string]::IsNullOrWhiteSpace($overridePath)) {
            $resolvedOverride = [IO.Path]::GetFullPath($overridePath)
            if (-not (Test-Path -LiteralPath $resolvedOverride -PathType Leaf)) {
                throw "$overrideName は存在する実行ファイルの絶対pathを指定してください: $overridePath"
            }
            return $resolvedOverride
        }
    }

    $effectiveRuntimeRoot = $RuntimeRoot
    if ([string]::IsNullOrWhiteSpace($effectiveRuntimeRoot)) {
        $effectiveRuntimeRoot = [Environment]::GetEnvironmentVariable('MEDIA_NORMALIZER_RUNTIME_ROOT')
    }
    if (-not [string]::IsNullOrWhiteSpace($effectiveRuntimeRoot)) {
        $bundledPath = Get-MediaNormalizerRuntimeExecutablePath -RuntimeRoot $effectiveRuntimeRoot -Name $Name -Platform $Platform
        if (-not (Test-Path -LiteralPath $bundledPath -PathType Leaf)) {
            throw "指定された同梱runtimeに $Name がありません。PATH上の別実体へfallbackしません: $bundledPath"
        }
        return $bundledPath
    }

    $candidateNames = switch ($Name) {
        'FFmpeg' { @('ffmpeg') }
        'FFprobe' { @('ffprobe') }
        'Python' { if ($Platform -eq 'Windows') { @('py', 'python') } else { @('python3', 'python') } }
        'PowerShell' { @('pwsh') }
    }
    foreach ($candidateName in $candidateNames) {
        $command = Get-Command -Name $candidateName -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($command) {
            if ($Platform -eq 'Windows') { return [string]$candidateName }
            return [string]$command.Source
        }
    }

    if ($Required) { throw "$Name が見つかりません。" }
    return $null
}

function Get-MediaNormalizerProcessTreeSnapshot {
    param([Parameter(Mandatory)][int]$RootProcessId)

    $rows = & /bin/ps -axo pid=,ppid= 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'プロセス一覧を取得できませんでした。' }
    $parentById = @{}
    foreach ($row in $rows) {
        if ([string]$row -match '^\s*(\d+)\s+(\d+)\s*$') {
            $parentById[[int]$Matches[1]] = [int]$Matches[2]
        }
    }
    if (-not $parentById.ContainsKey($RootProcessId)) { return @() }

    $depthById = @{ $RootProcessId = 0 }
    $frontier = @($RootProcessId)
    while ($frontier.Count -gt 0) {
        $next = [Collections.Generic.List[int]]::new()
        foreach ($candidateId in $parentById.Keys) {
            if ($depthById.ContainsKey([int]$candidateId)) { continue }
            if ($frontier -contains [int]$parentById[$candidateId]) {
                $depthById[[int]$candidateId] = $depthById[[int]$parentById[$candidateId]] + 1
                $next.Add([int]$candidateId)
            }
        }
        $frontier = $next.ToArray()
    }

    $snapshot = [Collections.Generic.List[object]]::new()
    foreach ($processId in @($depthById.Keys | Sort-Object { -$depthById[$_] }, { [int]$_ })) {
        try {
            $process = Get-Process -Id ([int]$processId) -ErrorAction Stop
            $snapshot.Add([pscustomobject]@{
                Id = [int]$processId
                Depth = [int]$depthById[$processId]
                StartTimeTicks = $process.StartTime.ToUniversalTime().Ticks
            })
        } catch {
            if ([int]$processId -eq $RootProcessId) { return @() }
        }
    }
    return $snapshot.ToArray()
}

function Stop-MediaNormalizerProcessTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(2, 2147483647)][int]$RootProcessId,
        [ValidateRange(0, 60)][int]$GracePeriodSeconds = 5
    )

    if ($RootProcessId -eq $PID) {
        throw '現在のPowerShellプロセスは終了対象にできません。'
    }

    if ((Get-MediaNormalizerPlatform) -eq 'Windows') {
        & taskkill.exe /T /F /PID $RootProcessId 2>&1 | Out-Null
        $stopped = $LASTEXITCODE -eq 0
        return [pscustomobject]@{
            RootProcessId = $RootProcessId
            TargetProcessIds = @($RootProcessId)
            RemainingProcessIds = if ($stopped) { @() } else { @($RootProcessId) }
            Stopped = $stopped
        }
    }

    $snapshot = @(Get-MediaNormalizerProcessTreeSnapshot -RootProcessId $RootProcessId)
    if ($snapshot.Count -eq 0) {
        # ルートを観測できない場合、そこから生成された子孫の不在を証明できない。
        # 成功扱いにせず、呼び出し側にRECOVERY_REQUIREDを返す。
        return [pscustomobject]@{
            RootProcessId = $RootProcessId
            TargetProcessIds = @($RootProcessId)
            RemainingProcessIds = @($RootProcessId)
            Stopped = $false
        }
    }

    $killPath = '/bin/kill'
    foreach ($entry in $snapshot) {
        try {
            $current = Get-Process -Id $entry.Id -ErrorAction Stop
            if ($current.StartTime.ToUniversalTime().Ticks -ne $entry.StartTimeTicks) { continue }
            & $killPath -TERM ([string]$entry.Id) 2>$null
        } catch { }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($GracePeriodSeconds)
    do {
        $remaining = [Collections.Generic.List[int]]::new()
        foreach ($entry in $snapshot) {
            try {
                $current = Get-Process -Id $entry.Id -ErrorAction Stop
                if ($current.StartTime.ToUniversalTime().Ticks -eq $entry.StartTimeTicks) {
                    $remaining.Add($entry.Id)
                }
            } catch { }
        }
        if ($remaining.Count -eq 0 -or [DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 100
    } while ($true)

    foreach ($processId in $remaining) {
        $entry = $snapshot | Where-Object Id -eq $processId | Select-Object -First 1
        try {
            $current = Get-Process -Id $processId -ErrorAction Stop
            if ($current.StartTime.ToUniversalTime().Ticks -eq $entry.StartTimeTicks) {
                & $killPath -KILL ([string]$processId) 2>$null
            }
        } catch { }
    }

    Start-Sleep -Milliseconds 100
    $stillRunning = [Collections.Generic.List[int]]::new()
    foreach ($entry in $snapshot) {
        try {
            $current = Get-Process -Id $entry.Id -ErrorAction Stop
            if ($current.StartTime.ToUniversalTime().Ticks -eq $entry.StartTimeTicks) {
                $stillRunning.Add($entry.Id)
            }
        } catch { }
    }
    return [pscustomobject]@{
        RootProcessId = $RootProcessId
        TargetProcessIds = @($snapshot.Id)
        RemainingProcessIds = $stillRunning.ToArray()
        Stopped = $stillRunning.Count -eq 0
    }
}

Export-ModuleMember -Function Get-MediaNormalizerPlatform, Get-MediaNormalizerRuntimeExecutablePath, Get-MediaNormalizerBinaryArchitecture, Assert-MediaNormalizerWritablePath, Get-MediaNormalizerStoragePath, Resolve-MediaNormalizerCommand, Stop-MediaNormalizerProcessTree
