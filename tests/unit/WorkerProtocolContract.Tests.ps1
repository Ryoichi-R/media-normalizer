#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:fixtureRoot = Join-Path $script:repoRoot 'contracts/fixtures/worker-protocol'
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.WorkerProtocol.psm1') -Force
}

Describe 'Worker protocol contract' {
    It 'declares the planned command and event vocabulary in the machine-readable schema' {
        $schema = Get-Content -LiteralPath (Join-Path $script:repoRoot 'contracts/worker-protocol.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $schema.oneOf.Count | Should -Be 2
        $commandNames = @($schema['$defs'].command.oneOf | ForEach-Object { ($_['$ref'] -split '/')[-1] })
        $eventNames = @($schema['$defs'].event.oneOf | ForEach-Object { ($_['$ref'] -split '/')[-1] })
        $commandNames | Should -Contain 'normalizeCommand'
        $commandNames | Should -Contain 'processRegistrationAckCommand'
        $commandNames | Should -Contain 'temporaryFileRegistrationAckCommand'
        $eventNames | Should -Contain 'progress'
        $eventNames | Should -Contain 'processStarted'
        $eventNames | Should -Contain 'processExited'
        $eventNames | Should -Contain 'temporaryOutput'
    }

    It 'accepts every canonical command and event fixture' {
        foreach ($path in Get-ChildItem -LiteralPath $script:fixtureRoot -Filter 'command-*.json') {
            $validation = Test-MediaNormalizerWorkerCommand -Message (Get-Content -LiteralPath $path.FullName -Raw)
            $validation.IsValid | Should -BeTrue -Because ($path.Name + ': ' + ($validation.Errors -join '; '))
        }
        foreach ($path in Get-ChildItem -LiteralPath $script:fixtureRoot -Filter 'event-*.json') {
            $validation = Test-MediaNormalizerWorkerEvent -Message (Get-Content -LiteralPath $path.FullName -Raw)
            $validation.IsValid | Should -BeTrue -Because ($path.Name + ': ' + ($validation.Errors -join '; '))
        }
    }

    It 'rejects unknown versions, missing fields, wrong numeric types, and extra fields' {
        $scan = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'command-scan.json') -Raw | ConvertFrom-Json -AsHashtable
        $scan.schemaVersion = 2
        (Test-MediaNormalizerWorkerCommand -Message $scan).IsValid | Should -BeFalse

        $scan = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'command-scan.json') -Raw | ConvertFrom-Json -AsHashtable
        $scan.Remove('paths')
        (Test-MediaNormalizerWorkerCommand -Message $scan).IsValid | Should -BeFalse

        $progress = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'event-progress.json') -Raw | ConvertFrom-Json -AsHashtable
        $progress.percent = '40.5'
        (Test-MediaNormalizerWorkerEvent -Message $progress).IsValid | Should -BeFalse

        $progress = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'event-progress.json') -Raw | ConvertFrom-Json -AsHashtable
        $progress.unexpected = $true
        (Test-MediaNormalizerWorkerEvent -Message $progress).IsValid | Should -BeFalse
    }

    It 'rejects stale process acknowledgements and out-of-range progress' {
        $ack = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'command-process-registration-ack.json') -Raw | ConvertFrom-Json -AsHashtable
        $ack.accepted = 'yes'
        (Test-MediaNormalizerWorkerCommand -Message $ack).IsValid | Should -BeFalse

        $progress = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'event-progress.json') -Raw | ConvertFrom-Json -AsHashtable
        $progress.percent = 101
        (Test-MediaNormalizerWorkerEvent -Message $progress).IsValid | Should -BeFalse

        $processStarting = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'event-process-starting.json') -Raw | ConvertFrom-Json -AsHashtable
        $processStarting.arguments = @('ffmpeg', 12)
        (Test-MediaNormalizerWorkerEvent -Message $processStarting).IsValid | Should -BeFalse

        $errorEvent = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'event-error.json') -Raw | ConvertFrom-Json -AsHashtable
        $errorEvent.runId = 'not-a-uuid'
        (Test-MediaNormalizerWorkerEvent -Message $errorEvent).IsValid | Should -BeFalse

        $temporaryOutput = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'event-temporary-output.json') -Raw | ConvertFrom-Json -AsHashtable
        $temporaryOutput.role = 'final'
        (Test-MediaNormalizerWorkerEvent -Message $temporaryOutput).IsValid | Should -BeFalse
    }
}
