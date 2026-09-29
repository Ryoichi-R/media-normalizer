#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.Progress.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.Core.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.Platform.psm1') -Force -DisableNameChecking
}

Describe 'MediaNormalizer POSIX process runner' -Tag 'PosixOnly' {
    It 'preserves argv containing spaces, quotes, backslashes, Unicode, and a leading hyphen' {
        if ((Get-MediaNormalizerPlatform) -eq 'Windows') { Set-ItResult -Skipped -Because 'POSIX-only process argv contract' }
        $arguments = @('%s\n', 'space value', 'quote " word', 'backslash\', '日本語', '-leading')
        $result = InModuleScope MediaNormalizer.Core -Parameters @{ a = $arguments } {
            param($a)
            Invoke-MediaNormalizerProcess -FilePath '/usr/bin/printf' -Arguments $a -CliMode `
                -TrackElapsedForEta:$false -TrackPhaseProgress:$false
        }
        $result.ExitCode | Should -Be 0
        $result.StdoutText | Should -Be "space value`nquote `" word`nbackslash\`n日本語`n-leading`n"
        $result.StderrText | Should -Be ''
    }

    It 'pumps stdout and stderr and returns the child exit code' {
        if ((Get-MediaNormalizerPlatform) -eq 'Windows') { Set-ItResult -Skipped -Because 'POSIX-only process stream contract' }
        $result = InModuleScope MediaNormalizer.Core {
            Invoke-MediaNormalizerProcess -FilePath '/bin/sh' `
                -Arguments @('-c', 'printf stdout-message; printf stderr-message >&2; exit 7') `
                -CliMode -TrackElapsedForEta:$false -TrackPhaseProgress:$false
        }
        $result.ExitCode | Should -Be 7
        $result.StdoutText | Should -Be 'stdout-message'
        $result.StderrText | Should -Be 'stderr-message'
    }

    It 'pumps ffmpeg progress, heartbeat, stdout, stderr, and exit code from a real process' {
        if ((Get-MediaNormalizerPlatform) -eq 'Windows') { Set-ItResult -Skipped -Because 'POSIX-only process stream/progress contract' }
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("mn-posix-progress-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $toolPath = Join-Path $tempRoot 'fake-ffmpeg'
        $scriptBody = @'
#!/bin/sh
if [ "$1" != "-progress" ]; then exit 9; fi
progress_path=$2
printf '%s\n' 'out_time_us=2500000' 'progress=continue' > "$progress_path"
printf '%s\n' 'stdout-start'
printf '%s\n' 'stderr-start' >&2
sleep 0.30
printf '%s\n' 'out_time_us=5000000' 'progress=end' > "$progress_path"
printf '%s\n' 'stdout-end'
printf '%s\n' 'stderr-end' >&2
exit 6
'@
        [IO.File]::WriteAllText($toolPath, $scriptBody, [Text.UTF8Encoding]::new($false))
        [IO.File]::SetUnixFileMode($toolPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        $state = [pscustomobject]@{
            CancelRequested = $false
            RunningProcess = $null
            ProgressCurrent = 0
            ProgressTotal = 0
            CurrentPhase = $null
            PhaseEtaSeconds = $null
            PhaseProgressPercent = -1.0
            CurrentFileElapsedSec = 0.0
        }
        $phaseValues = [Collections.Generic.List[double]]::new()
        $logs = [Collections.Generic.List[string]]::new()
        $progressCallback = { param($current, $total) $phaseValues.Add([double]$state.PhaseProgressPercent) }.GetNewClosure()
        $logger = { param($message) $logs.Add([string]$message) }.GetNewClosure()
        $clock = [pscustomobject]@{ Now = [DateTime]::UtcNow }
        $getNow = { $clock.Now = $clock.Now.AddSeconds(6); return $clock.Now }.GetNewClosure()
        try {
            $result = InModuleScope MediaNormalizer.Core -Parameters @{
                path = $toolPath; s = $state; p = $progressCallback; l = $logger; n = $getNow
            } {
                param($path, $s, $p, $l, $n)
                Invoke-MediaNormalizerProcess -FilePath $path -Arguments @('ignored') -State $s `
                    -PhaseLabel 'POSIX progress' -Logger $l -Progress $p -CliMode `
                    -CurrentFileDurationSec 10 -TrackElapsedForEta:$false -TrackPhaseProgress:$true `
                    -UiUpdateIntervalSeconds 0.01 -SleepMilliseconds 10 -GetNow $n -WriteProgressFile
            }
            $result.ExitCode | Should -Be 6
            $result.StdoutText | Should -Be "stdout-start`nstdout-end`n"
            $result.StderrText | Should -Be "stderr-start`nstderr-end`n"
            @($phaseValues | Where-Object { $_ -gt 0 -and $_ -le 100 }).Count | Should -BeGreaterThan 0
            ($logs -join "`n") | Should -Match 'POSIX progress\.\.\. 6s'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'stops a parent-child-grandchild tree without touching the sentinel process' {
        if ((Get-MediaNormalizerPlatform) -eq 'Windows') { Set-ItResult -Skipped -Because 'POSIX-only process tree contract' }
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = '/bin/sh'
        $startInfo.UseShellExecute = $false
        $startInfo.ArgumentList.Add('-c')
        $startInfo.ArgumentList.Add("sh -c 'sleep 30 & wait' & wait")
        $root = [Diagnostics.Process]::new()
        $root.StartInfo = $startInfo
        $sentinel = [Diagnostics.Process]::Start('/bin/sleep', '30')
        try {
            $root.Start() | Out-Null
            Start-Sleep -Milliseconds 150
            $result = Stop-MediaNormalizerProcessTree -RootProcessId $root.Id -GracePeriodSeconds 2
            $root.WaitForExit(3000) | Out-Null
            $result.Stopped | Should -BeTrue
            $result.TargetProcessIds.Count | Should -BeGreaterOrEqual 3
            $result.RemainingProcessIds | Should -BeNullOrEmpty
            $root.HasExited | Should -BeTrue
            $sentinel.HasExited | Should -BeFalse
        } finally {
            if ($root -and $root.Id -gt 0 -and -not $root.HasExited) {
                Stop-MediaNormalizerProcessTree -RootProcessId $root.Id -GracePeriodSeconds 1 | Out-Null
            }
            if ($sentinel -and -not $sentinel.HasExited) { $sentinel.Kill(); $sentinel.WaitForExit() }
            if ($sentinel) { $sentinel.Dispose() }
            $root.Dispose()
        }
    }

    It 'fails closed when the root process can no longer be observed' {
        if ((Get-MediaNormalizerPlatform) -eq 'Windows') { Set-ItResult -Skipped -Because 'POSIX-only process tree contract' }
        $root = [Diagnostics.Process]::Start('/usr/bin/true', '')
        try {
            $root.WaitForExit()
            $result = Stop-MediaNormalizerProcessTree -RootProcessId $root.Id -GracePeriodSeconds 0
            $result.Stopped | Should -BeFalse
            $result.RemainingProcessIds | Should -Contain $root.Id
        } finally {
            $root.Dispose()
        }
    }

    It 'cancellation stops the target process tree and leaves an unrelated process alive' {
        if ((Get-MediaNormalizerPlatform) -eq 'Windows') { Set-ItResult -Skipped -Because 'POSIX-only process tree contract' }
        $source = [Threading.CancellationTokenSource]::new()
        $source.CancelAfter(300)
        $state = [pscustomobject]@{
            CancelRequested = $false
            RunningProcess = $null
            ProgressCurrent = 0
            ProgressTotal = 0
            CurrentPhase = $null
            PhaseEtaSeconds = $null
            PhaseProgressPercent = -1.0
            CurrentFileElapsedSec = 0.0
        }
        $sentinel = [Diagnostics.Process]::Start('/bin/sleep', '30')
        try {
            $result = InModuleScope MediaNormalizer.Core -Parameters @{ s = $state; t = $source.Token } {
                param($s, $t)
                Invoke-MediaNormalizerProcess -FilePath '/bin/sh' `
                    -Arguments @('-c', 'sleep 30 & wait') -State $s -CliMode `
                    -TrackElapsedForEta:$false -TrackPhaseProgress:$false `
                    -SleepMilliseconds 20 -CancellationToken $t
            }
            $result.ExitCode | Should -Not -Be 0
            $state.RunningProcess | Should -BeNullOrEmpty
            $sentinel.HasExited | Should -BeFalse
        } finally {
            if ($state.RunningProcess -and -not $state.RunningProcess.HasExited) {
                Stop-MediaNormalizerProcessTree -RootProcessId $state.RunningProcess.Id -GracePeriodSeconds 1 | Out-Null
            }
            if ($sentinel -and -not $sentinel.HasExited) { $sentinel.Kill(); $sentinel.WaitForExit() }
            if ($sentinel) { $sentinel.Dispose() }
            $source.Dispose()
        }
    }
}
