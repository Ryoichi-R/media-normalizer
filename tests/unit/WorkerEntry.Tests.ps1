#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:workerPath = Join-Path $script:repoRoot 'scripts/mn-worker.ps1'
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.Platform.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.RunRecovery.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.WorkerProtocol.psm1') -Force

    function Invoke-MediaNormalizerWorkerFixture {
        param(
            [Parameter(Mandatory)][Collections.IDictionary]$Command,
            [string]$StorageRoot
        )
        $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $pwsh
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
        $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $script:workerPath)) { $startInfo.ArgumentList.Add($argument) }
        if ($StorageRoot) { $startInfo.ArgumentList.Add('-StorageRoot'); $startInfo.ArgumentList.Add($StorageRoot) }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            $process.Start() | Out-Null
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.WriteLine((ConvertTo-Json -InputObject $Command -Depth 16 -Compress))
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(20000)) {
                $process.Kill($true)
                throw 'worker fixture timed out.'
            }
            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                StdoutText = $stdout.GetAwaiter().GetResult()
                StderrText = $stderr.GetAwaiter().GetResult()
            }
        } finally {
            $process.Dispose()
        }
    }
}

Describe 'Media Normalizer worker entry' {
    It 'answers capabilities with one valid NDJSON event' {
        $command = @{ schemaVersion = 1; id = 'c0000000-0000-4000-8000-000000000001'; cmd = 'capabilities' }
        $result = Invoke-MediaNormalizerWorkerFixture -Command $command
        $result.ExitCode | Should -Be 0
        $result.StderrText | Should -BeNullOrEmpty
        $lines = @($result.StdoutText -split "`r?`n" | Where-Object { $_ })
        $lines.Count | Should -Be 1
        $event = ConvertFrom-Json -InputObject $lines[0] -AsHashtable
        (Test-MediaNormalizerWorkerEvent -Message $event).IsValid | Should -BeTrue
        $event.type | Should -Be 'capabilities-result'
        $event.audioOutputFormats | Should -Contain 'flac'
    }

    It 'uses Core scan classification and filters unsupported files' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('mn-worker-scan-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        try {
            [IO.File]::WriteAllText((Join-Path $root 'voice.MP3'), 'fixture')
            [IO.File]::WriteAllText((Join-Path $root 'clip.mkv'), 'fixture')
            [IO.File]::WriteAllText((Join-Path $root 'notes.txt'), 'fixture')
            $command = @{
                schemaVersion = 1; id = 'c0000000-0000-4000-8000-000000000002'; cmd = 'scan'
                paths = @($root); mode = 'both'; recurse = $false
            }
            $result = Invoke-MediaNormalizerWorkerFixture -Command $command
            $result.ExitCode | Should -Be 0
            $lines = @([regex]::Split($result.StdoutText.Trim(), '\r?\n') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $lines.Count | Should -Be 1 -Because "stderr was: $($result.StderrText)"
            $event = ConvertFrom-Json -InputObject $lines[0] -AsHashtable
            (Test-MediaNormalizerWorkerEvent -Message $event).IsValid | Should -BeTrue
            $event.files.Count | Should -Be 2
            @($event.files | Where-Object { $_.extension -eq '.mp3' -and $_.audioEligible -and -not $_.videoEligible }).Count | Should -Be 1
            @($event.files | Where-Object { $_.extension -eq '.mkv' -and $_.videoEligible }).Count | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns one INVALID_COMMAND event for an unsupported command' {
        $command = @{ schemaVersion = 1; id = 'c0000000-0000-4000-8000-000000000004'; cmd = 'unsupported' }
        $result = Invoke-MediaNormalizerWorkerFixture -Command $command
        $result.ExitCode | Should -Be 2 -Because "stdout=$($result.StdoutText); stderr=$($result.StderrText)"
        $lines = @([regex]::Split($result.StdoutText.Trim(), '\r?\n') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines.Count | Should -Be 1 -Because "stderr was: $($result.StderrText)"
        $event = ConvertFrom-Json -InputObject $lines[0] -AsHashtable
        (Test-MediaNormalizerWorkerEvent -Message $event).IsValid | Should -BeTrue
        $event.code | Should -Be 'INVALID_COMMAND'
    }

    It 'returns JOB_ALREADY_RUNNING and exit 3 when the job lock is held' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('mn-worker-lock-' + [guid]::NewGuid().ToString('N'))
        $inputRoot = Join-Path $root 'input'
        [void][IO.Directory]::CreateDirectory($inputRoot)
        [IO.File]::WriteAllText((Join-Path $inputRoot 'voice.mp3'), 'fixture')
        $heldLock = $null
        try {
            $heldLock = Enter-MediaNormalizerFileLock -Kind JobLock -StorageRoot $root
            $command = @{
                schemaVersion = 1; id = 'c0000000-0000-4000-8000-000000000003'; cmd = 'normalize'
                runId = '6f55000c-709c-40f0-9f76-ececf7a5e3ca'; inputPaths = @((Join-Path $inputRoot 'voice.mp3'))
                outputDir = (Join-Path $root 'output'); mode = 'audio'; target = -16.0; truePeak = -1.0
                bitrate = '192k'; sampleRate = '48000'; collisionPolicy = 'rename'; speedPercent = 100
                audioOutputFormat = 'mp3'; analyzeOnly = $false; skipIfNormalized = $true
                normalizationTolerance = 0.5; recurse = $true; preserveHierarchy = $true
            }
            $result = Invoke-MediaNormalizerWorkerFixture -Command $command -StorageRoot $root
            $result.ExitCode | Should -Be 3
            $lines = @([regex]::Split($result.StdoutText.Trim(), '\r?\n') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $lines.Count | Should -Be 1 -Because "stderr was: $($result.StderrText)"
            $event = ConvertFrom-Json -InputObject $lines[0] -AsHashtable
            (Test-MediaNormalizerWorkerEvent -Message $event).IsValid | Should -BeTrue
            $event.code | Should -Be 'JOB_ALREADY_RUNNING'
        } finally {
            if ($heldLock) { $heldLock.Dispose() }
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
