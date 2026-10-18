#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.Platform.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.RunRecovery.psm1') -Force -DisableNameChecking
}

Describe 'CLI run recovery contract' {
    It 'schema fixes the supported transitions and record fields' {
        $schema = Get-Content -LiteralPath (Join-Path $script:repoRoot 'contracts/run-recovery.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $schema.properties.schemaVersion.enum | Should -Contain 1
        $schema.properties.schemaVersion.enum | Should -Contain 2
        $schema.properties.entrypoint.enum | Should -Contain 'gui'
        $schema.properties.status.enum | Should -Contain 'recovery-required'
        $schema.required | Should -Contain 'ownerProcessId'
        $schema.additionalProperties | Should -BeFalse
    }

    It 'reads a canonical unresolved running record' {
        $path = Join-Path $script:repoRoot 'contracts/fixtures/recovery/active-run-running.json'
        $record = Read-MediaNormalizerRunRecord -Path $path
        $record.status | Should -Be 'running'
        $record.runId | Should -Be '6f55000c-709c-40f0-9f76-ececf7a5e3ca'
    }

    It 'reads a canonical GUI host record with process identities' {
        $path = Join-Path $script:repoRoot 'contracts/fixtures/recovery/active-gui-run-running.json'
        $record = Read-MediaNormalizerRunRecord -Path $path
        $record.entrypoint | Should -Be 'gui'
        $record.status | Should -Be 'running'
        $record.processes.Count | Should -Be 1
        $record.processes[0].processToken | Should -Be 'aabbd447-9897-44d0-a52c-6dd393dab4ec'
    }

    It 'rejects unknown GUI record fields at the root and inside identity arrays' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("mn-recovery-extra-fields-" + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($root) | Out-Null
        try {
            $cases = @(
                @{ Fixture = 'active-gui-run-running.json'; Mutate = { param($record) $record.unexpected = $true } },
                @{ Fixture = 'active-gui-run-running.json'; Mutate = { param($record) $record.processes[0].unexpected = $true } },
                @{ Fixture = 'active-gui-run-recovery-required.json'; Mutate = { param($record) $record.pendingProcessStarts[0].unexpected = $true } }
            )
            $index = 0
            foreach ($case in $cases) {
                $record = Get-Content -LiteralPath (Join-Path $script:repoRoot "contracts/fixtures/recovery/$($case.Fixture)") -Raw | ConvertFrom-Json -AsHashtable
                & $case.Mutate $record
                $path = Join-Path $root "invalid-$index.json"
                [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $record -Depth 8))
                { Read-MediaNormalizerRunRecord -Path $path } | Should -Throw '*RECOVERY_REQUIRED*'
                $index++
            }
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'blocks a CLI run when a GUI host record is unresolved' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("mn-recovery-gui-unresolved-" + [guid]::NewGuid().ToString('N'))
        try {
            $path = InModuleScope MediaNormalizer.Platform -Parameters @{ r = $root } { param($r) Get-MediaNormalizerStoragePath -Kind RunRecord -StorageRoot $r }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:repoRoot 'contracts/fixtures/recovery/active-gui-run-running.json') -Destination $path
            { Enter-MediaNormalizerCliRun -StorageRoot $root } | Should -Throw '*RECOVERY_REQUIRED*'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails closed on an invalid recovery record' {
        $path = Join-Path $script:repoRoot 'contracts/fixtures/recovery/active-run-invalid.json'
        { Read-MediaNormalizerRunRecord -Path $path } | Should -Throw '*RECOVERY_REQUIRED*'
    }

    It 'blocks a new job while a prior run record is unresolved' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("mn-recovery-unresolved-" + [guid]::NewGuid().ToString('N'))
        try {
            $path = InModuleScope MediaNormalizer.Platform -Parameters @{ r = $root } { param($r) Get-MediaNormalizerStoragePath -Kind RunRecord -StorageRoot $r }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:repoRoot 'contracts/fixtures/recovery/active-run-running.json') -Destination $path
            { Enter-MediaNormalizerCliRun -StorageRoot $root } | Should -Throw '*RECOVERY_REQUIRED*'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'records completion before releasing both locks and allows the next run' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("mn-recovery-complete-" + [guid]::NewGuid().ToString('N'))
        $run = $null
        try {
            $run = Enter-MediaNormalizerCliRun -StorageRoot $root
            $running = Read-MediaNormalizerRunRecord -Path $run.RecordPath
            $running.status | Should -Be 'running'
            $run.GuardLock.CanWrite | Should -BeTrue
            $run.JobLock.CanWrite | Should -BeTrue
            $completed = Complete-MediaNormalizerCliRun -Run $run -ExitCode 1
            $completed.status | Should -Be 'completed'
            $completed.resultCode | Should -Be 1
            $next = Enter-MediaNormalizerCliRun -StorageRoot $root
            $null = Complete-MediaNormalizerCliRun -Run $next -ExitCode 0
            (Read-MediaNormalizerRunRecord -Path $next.RecordPath).status | Should -Be 'completed'
        } finally {
            if ($run -and $run.JobLock) { $run.JobLock.Dispose() }
            if ($run -and $run.GuardLock) { $run.GuardLock.Dispose() }
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports a held normalization job lock as JOB_ALREADY_RUNNING' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("mn-recovery-job-lock-" + [guid]::NewGuid().ToString('N'))
        $heldLock = $null
        try {
            $heldLock = Enter-MediaNormalizerFileLock -Kind JobLock -StorageRoot $root
            { Enter-MediaNormalizerCliRun -StorageRoot $root } | Should -Throw '*JOB_ALREADY_RUNNING*'
        } finally {
            if ($heldLock) { $heldLock.Dispose() }
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'marks recovery required and keeps the persistent guard after an unverified stop' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ("mn-recovery-required-" + [guid]::NewGuid().ToString('N'))
        $run = $null
        try {
            $run = Enter-MediaNormalizerCliRun -StorageRoot $root
            $record = Complete-MediaNormalizerCliRun -Run $run -ExitCode 4 -RecoveryRequired
            $record.status | Should -Be 'recovery-required'
            { Enter-MediaNormalizerCliRun -StorageRoot $root } | Should -Throw '*RECOVERY_REQUIRED*'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects all writable paths inside an app bundle Contents directory' {
        { InModuleScope MediaNormalizer.Platform { Assert-MediaNormalizerWritablePath -Path '/tmp/MediaNormalizer.app/Contents/Resources/runtime/state.json' } } |
            Should -Throw '*Contents以下*'
    }

    It 'resolves macOS settings, logs, presets, and locks outside an app bundle' {
        $paths = InModuleScope MediaNormalizer.Platform {
            $home = [Environment]::GetFolderPath('UserProfile')
            [pscustomobject]@{
                Settings = Get-MediaNormalizerStoragePath -Kind Settings -Platform macOS
                Presets = Get-MediaNormalizerStoragePath -Kind UserPresets -Platform macOS
                GuiLock = Get-MediaNormalizerStoragePath -Kind GuiLock -Platform macOS
                JobLock = Get-MediaNormalizerStoragePath -Kind JobLock -Platform macOS
                RunRecord = Get-MediaNormalizerStoragePath -Kind RunRecord -Platform macOS
                Log = Get-MediaNormalizerStoragePath -Kind Log -Platform macOS
                Home = $home
            }
        }
        $supportRoot = Join-Path $paths.Home 'Library/Application Support/media-normalizer'
        $logRoot = Join-Path $paths.Home 'Library/Logs/media-normalizer'
        $paths.Settings | Should -Be (Join-Path $supportRoot 'settings.json')
        $paths.Presets | Should -Be (Join-Path $supportRoot 'presets.user.json')
        $paths.GuiLock | Should -Be (Join-Path $supportRoot 'run/gui-instance.lock')
        $paths.JobLock | Should -Be (Join-Path $supportRoot 'run/normalization-job.lock')
        $paths.RunRecord | Should -Be (Join-Path $supportRoot 'run/active-run.json')
        $paths.Log | Should -Be (Join-Path $logRoot 'media-normalizer.log')
    }
}
