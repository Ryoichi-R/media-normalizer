#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.Core.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.Platform.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.WorkerProtocol.psm1') -Force
}

Describe 'Worker child process registration' -Tag 'PosixOnly' {
    It 'waits for an identity-matched host ACK before returning a child result' {
        if ((Get-MediaNormalizerPlatform) -eq 'Windows') { Set-ItResult -Skipped -Because 'POSIX worker process registration contract' }
        $events = [Collections.Generic.List[object]]::new()
        $acks = @{}
        $sink = {
            param($event)
            [void]$events.Add($event)
            if ($event.type -eq 'process-started') {
                $acks[$event.processToken] = @{
                    accepted = $true
                    processId = $event.processId
                    processStartedAtUtc = $event.processStartedAtUtc
                }
            }
        }.GetNewClosure()
        $runId = '6f55000c-709c-40f0-9f76-ececf7a5e3ca'
        $context = [pscustomobject]@{
            RunId = $runId
            EventSink = $sink
            PendingProcessAcks = $acks
            AckTimeoutSeconds = 2
            RecoveryRequired = $false
        }
        $state = New-MediaNormalizerState
        Add-Member -InputObject $state -MemberType NoteProperty -Name WorkerProtocolContext -Value $context
        $result = InModuleScope MediaNormalizer.Core -Parameters @{ s = $state } {
            param($s)
            Invoke-MediaNormalizerProcess -FilePath '/bin/sh' -Arguments @('-c', 'sleep 0.15; printf registered') `
                -State $s -CliMode -TrackElapsedForEta:$false -TrackPhaseProgress:$false
        }

        $result.ExitCode | Should -Be 0
        $result.StdoutText | Should -Be 'registered'
        ($events | ForEach-Object type) | Should -Be @('process-starting', 'process-started', 'process-exited')
        foreach ($event in $events) { (Test-MediaNormalizerWorkerEvent -Message $event).IsValid | Should -BeTrue }
    }

    It 'fails closed and stops the child when the host rejects its registration' {
        if ((Get-MediaNormalizerPlatform) -eq 'Windows') { Set-ItResult -Skipped -Because 'POSIX worker process registration contract' }
        $events = [Collections.Generic.List[object]]::new()
        $acks = @{}
        $sink = {
            param($event)
            [void]$events.Add($event)
            if ($event.type -eq 'process-started') {
                $acks[$event.processToken] = @{
                    accepted = $true
                    processId = [int]$event.processId + 1
                    processStartedAtUtc = $event.processStartedAtUtc
                }
            }
        }.GetNewClosure()
        $context = [pscustomobject]@{
            RunId = '6f55000c-709c-40f0-9f76-ececf7a5e3ca'
            EventSink = $sink
            PendingProcessAcks = $acks
            AckTimeoutSeconds = 2
            RecoveryRequired = $false
        }
        $state = New-MediaNormalizerState
        Add-Member -InputObject $state -MemberType NoteProperty -Name WorkerProtocolContext -Value $context

        {
            InModuleScope MediaNormalizer.Core -Parameters @{ s = $state } {
                param($s)
                Invoke-MediaNormalizerProcess -FilePath '/bin/sleep' -Arguments @('30') `
                    -State $s -CliMode -TrackElapsedForEta:$false -TrackPhaseProgress:$false
            }
        } | Should -Throw '*RECOVERY_REQUIRED*identity mismatch*'
        $state.RunningProcess | Should -BeNullOrEmpty
        @($events | Where-Object type -eq 'process-started').Count | Should -Be 1
        @($events | Where-Object type -eq 'process-exited').Count | Should -Be 0
    }
}
