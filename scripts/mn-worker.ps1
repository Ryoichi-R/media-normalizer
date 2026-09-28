#Requires -Version 7.4

[CmdletBinding()]
param([string]$StorageRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$moduleRoot = Join-Path $repoRoot 'lib'
Import-Module (Join-Path $moduleRoot 'MediaNormalizer.Platform.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'MediaNormalizer.Progress.psm1') -Force
Import-Module (Join-Path $moduleRoot 'MediaNormalizer.Probe.psm1') -Force
Import-Module (Join-Path $moduleRoot 'MediaNormalizer.Core.psm1') -Force
Import-Module (Join-Path $moduleRoot 'MediaNormalizer.RunRecovery.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'MediaNormalizer.WorkerProtocol.psm1') -Force

$script:WorkerExitCode = 2
$script:WorkerInput = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.UTF8Encoding]::new($false))

function Write-MediaNormalizerWorkerEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Event)

    $validation = Test-MediaNormalizerWorkerEvent -Message $Event
    if (-not $validation.IsValid) {
        throw "worker event violates protocol: $($validation.Errors -join '; ')"
    }
    $json = ConvertTo-Json -InputObject $Event -Depth 32 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function Write-MediaNormalizerWorkerError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message,
        [string]$RunId,
        [string]$InputPath
    )

    $event = [ordered]@{ schemaVersion = 1; type = 'error'; code = $Code; message = $Message }
    if ($RunId) { $event.runId = $RunId }
    if ($InputPath) { $event.inputPath = $InputPath }
    Write-MediaNormalizerWorkerEvent -Event $event
}

function Get-MediaNormalizerWorkerCapabilities {
    return [ordered]@{
        schemaVersion = 1
        type = 'capabilities-result'
        id = $script:WorkerCommand.id
        modes = @('audio', 'video', 'both')
        audioInputExtensions = @(Get-AudioInputExtensions | Sort-Object)
        videoInputExtensions = @(Get-VideoInputExtensions | Sort-Object)
        audioOutputFormats = @(Get-AudioOutputFormats | Sort-Object)
    }
}

function Invoke-MediaNormalizerWorkerScan {
    param([Parameter(Mandatory)][Collections.IDictionary]$Command)

    $files = Get-MediaInputFiles -InputPath @($Command.paths) -Recurse:([bool]$Command.recurse)
    $audioExtensions = @(Get-AudioInputExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $videoExtensions = @(Get-VideoInputExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $results = [Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $extension = $file.Extension.ToLowerInvariant()
        $audioEligible = $extension -in $audioExtensions
        $videoEligible = $extension -in $videoExtensions
        $include = switch ([string]$Command.mode) {
            'audio' { $audioEligible }
            'video' { $videoEligible }
            default { $audioEligible -or $videoEligible }
        }
        if ($include) {
            $results.Add([ordered]@{
                path = $file.FullName
                extension = $extension
                audioEligible = [bool]$audioEligible
                videoEligible = [bool]$videoEligible
            })
        }
    }
    return [ordered]@{
        schemaVersion = 1
        type = 'scan-result'
        id = $Command.id
        files = $results.ToArray()
    }
}

function ConvertTo-MediaNormalizerWorkerOptions {
    param([Parameter(Mandatory)][Collections.IDictionary]$Command)

    $speedByPath = @{}
    if ($Command.Contains('speedPercentByPath')) {
        foreach ($key in $Command.speedPercentByPath.Keys) { $speedByPath[[string]$key] = [int]$Command.speedPercentByPath[$key] }
    }
    return @{
        RunId = [string]$Command.runId
        InputPath = @($Command.inputPaths | ForEach-Object { [string]$_ })
        InputDir = Get-MediaInputRoot -InputPath @($Command.inputPaths)
        OutputDir = [string]$Command.outputDir
        Mode = [string]$Command.mode
        Target = [double]$Command.target
        TruePeak = [double]$Command.truePeak
        Bitrate = [string]$Command.bitrate
        SampleRate = [string]$Command.sampleRate
        CollisionPolicy = [string]$Command.collisionPolicy
        SpeedPercent = [int]$Command.speedPercent
        SpeedPercentByPath = $speedByPath
        AudioOutputFormat = [string]$Command.audioOutputFormat
        AnalyzeOnly = [bool]$Command.analyzeOnly
        SkipIfNormalized = [bool]$Command.skipIfNormalized
        NormalizationTolerance = [double]$Command.normalizationTolerance
        Recurse = [bool]$Command.recurse
        PreserveHierarchy = [bool]$Command.preserveHierarchy
        ReportPath = if ($Command.Contains('reportPath') -and $null -ne $Command.reportPath) { [string]$Command.reportPath } else { $null }
    }
}

function Invoke-MediaNormalizerWorkerNormalize {
    param([Parameter(Mandatory)][Collections.IDictionary]$Command)

    $options = ConvertTo-MediaNormalizerWorkerOptions -Command $Command
    foreach ($path in $options.InputPath) {
        if (-not (Test-Path -LiteralPath $path)) { throw "入力パスが見つかりません: $path" }
    }
    $jobLock = $null
    try {
        $jobLock = Enter-MediaNormalizerFileLock -Kind JobLock -StorageRoot $StorageRoot
    } catch {
        if ($_.Exception.Message -match '^\[JOB_ALREADY_RUNNING\]') {
            Write-MediaNormalizerWorkerError -Code 'JOB_ALREADY_RUNNING' -Message $_.Exception.Message -RunId $options.RunId
            $script:WorkerExitCode = 3
            return
        }
        throw
    }

    $workerContext = [pscustomobject]@{
        RunId = $options.RunId
        EventSink = $null
        ExpectedProcesses = @{}
        PendingProcessAcks = @{}
        ExpectedTemporaryPaths = @{}
        PendingTemporaryAcks = @{}
        RecoveryRequired = $false
        FatalError = $null
        AckTimeoutSeconds = 10
    }
    $eventsOut = {
        param($event)
        if ($event.type -in @('run-start', 'run-done')) { return }
        if ($event.type -eq 'process-started') {
            $workerContext.ExpectedProcesses[[string]$event.processToken] = @{
                processId = [int]$event.processId
                processStartedAtUtc = [string]$event.processStartedAtUtc
            }
        } elseif ($event.type -eq 'process-exited') {
            [void]$workerContext.ExpectedProcesses.Remove([string]$event.processToken)
        }
        $null = Write-MediaNormalizerWorkerEvent -Event $event
    }.GetNewClosure()
    $workerContext.EventSink = $eventsOut
    $state = New-MediaNormalizerState
    Add-Member -InputObject $state -MemberType NoteProperty -Name WorkerProtocolContext -Value $workerContext
    $ioState = [pscustomobject]@{ Reader = $script:WorkerInput; PendingRead = $null; Closed = $false; State = $state; Context = $workerContext }
    $inputPump = {
        while (-not $ioState.Closed) {
            if ($null -eq $ioState.PendingRead) { $ioState.PendingRead = $ioState.Reader.ReadLineAsync() }
            if (-not $ioState.PendingRead.IsCompleted) { break }
            $line = $ioState.PendingRead.GetAwaiter().GetResult()
            $ioState.PendingRead = $null
            if ($null -eq $line) {
                $ioState.Closed = $true
                $ioState.State.CancelRequested = $true
                $ioState.Context.FatalError = 'Worker control channel closed during an active run.'
                throw "[RECOVERY_REQUIRED] worker control channel closed before run completion."
            }
            if ($line.Length -gt 1048576) {
                $ioState.Context.FatalError = 'Worker command exceeded the maximum line length.'
                throw 'worker command is too large.'
            }
            try { $message = ConvertFrom-Json -InputObject $line -AsHashtable -ErrorAction Stop }
            catch {
                $ioState.Context.FatalError = 'Worker command is not valid JSON.'
                throw 'worker command is not valid JSON.'
            }
            $validation = Test-MediaNormalizerWorkerCommand -Message $message
            if (-not $validation.IsValid) {
                $ioState.Context.FatalError = $validation.Errors -join '; '
                throw "worker command violates protocol: $($validation.Errors -join '; ')"
            }
            if ([string]$message.runId -ne $ioState.Context.RunId) {
                $ioState.Context.FatalError = 'Worker command runId does not match the active run.'
                throw 'worker command runId does not match the active run.'
            }
            switch ([string]$message.cmd) {
                'cancel' { $ioState.State.CancelRequested = $true }
                'process-registration-ack' {
                    $token = [string]$message.processToken
                    if (-not $ioState.Context.ExpectedProcesses.ContainsKey($token)) {
                        $ioState.Context.FatalError = 'Host acknowledged an unknown process identity.'
                        throw '[RECOVERY_REQUIRED] host acknowledged an unknown process identity.'
                    }
                    if ($ioState.Context.PendingProcessAcks.ContainsKey($token)) {
                        $ioState.Context.FatalError = 'Host sent a duplicate process identity acknowledgement.'
                        throw '[RECOVERY_REQUIRED] duplicate process identity acknowledgement.'
                    }
                    $expected = $ioState.Context.ExpectedProcesses[$token]
                    $ioState.Context.PendingProcessAcks[$token] = @{
                        accepted = [bool]$message.accepted
                        processId = [int]$message.processId
                        processStartedAtUtc = if ($message.processStartedAtUtc -is [datetime]) {
                            $message.processStartedAtUtc.ToUniversalTime().ToString('o')
                        } elseif ($message.processStartedAtUtc -is [DateTimeOffset]) {
                            $message.processStartedAtUtc.ToString('o')
                        } else { [string]$message.processStartedAtUtc }
                    }
                    if ([int]$message.processId -ne [int]$expected.processId) {
                        $ioState.Context.FatalError = 'Host process identity acknowledgement does not match the observed PID.'
                    }
                }
                'temporary-file-registration-ack' {
                    $temporaryPath = [IO.Path]::GetFullPath([string]$message.temporaryPath)
                    if (-not $ioState.Context.ExpectedTemporaryPaths.ContainsKey($temporaryPath)) {
                        $ioState.Context.FatalError = 'Host acknowledged an unknown temporary output path.'
                        throw '[RECOVERY_REQUIRED] host acknowledged an unknown temporary output path.'
                    }
                    if ($ioState.Context.PendingTemporaryAcks.ContainsKey($temporaryPath)) {
                        $ioState.Context.FatalError = 'Host sent a duplicate temporary output acknowledgement.'
                        throw '[RECOVERY_REQUIRED] duplicate temporary output acknowledgement.'
                    }
                    $ioState.Context.PendingTemporaryAcks[$temporaryPath] = @{ accepted = [bool]$message.accepted }
                }
                default {
                    $ioState.Context.FatalError = "Command '$($message.cmd)' is not accepted while a worker run is active."
                    throw $ioState.Context.FatalError
                }
            }
        }
    }.GetNewClosure()

    $script:WorkerExitCode = 1
    $totals = @{ Success = 0; Analyzed = 0; Fail = 0; Cancelled = 0; Skipped = 0 }
    $reportPath = $options.ReportPath
    $reportSucceeded = $true
    $modes = if ($options.Mode -eq 'both') { if ($options.AnalyzeOnly) { @('audio') } else { @('audio', 'video') } } else { @($options.Mode) }
    $null = Write-MediaNormalizerWorkerEvent -Event ([ordered]@{
        schemaVersion = 1; type = 'run-start'; runId = $options.RunId; mode = $options.Mode
    })
    try {
        foreach ($mode in $modes) {
            $parameters = @{
                State = $state
                Mode = $mode
                ReportMode = $options.Mode
                InputDir = $options.InputDir
                InputPaths = $options.InputPath
                OutputDir = $options.OutputDir
                Target = $options.Target
                TruePeak = $options.TruePeak
                Bitrate = $options.Bitrate
                SampleRate = $options.SampleRate
                CollisionPolicy = $options.CollisionPolicy
                SpeedPercent = $options.SpeedPercent
                SpeedPercentByPath = $options.SpeedPercentByPath
                AudioOutputFormat = $options.AudioOutputFormat
                AnalyzeOnly = $options.AnalyzeOnly
                SkipIfNormalized = $options.SkipIfNormalized
                NormalizationTolerance = $options.NormalizationTolerance
                Recurse = $options.Recurse
                PreserveHierarchy = $options.PreserveHierarchy
                ReportPath = $options.ReportPath
                EventSink = $eventsOut
                RunId = $options.RunId
                PumpEvents = $inputPump
                Logger = { param($message) }
                CliMode = $true
            }
            $result = Invoke-Normalize @parameters
            foreach ($counter in @($totals.Keys)) { $totals[$counter] += [int]$result[$counter] }
            if ($result.ContainsKey('ReportPath') -and $result.ReportPath) { $reportPath = [string]$result.ReportPath }
            if ($result.ContainsKey('ReportSucceeded') -and -not $result.ReportSucceeded) { $reportSucceeded = $false }
            if ($totals.Cancelled -gt 0) { break }
        }
        if ($workerContext.FatalError) { throw "[RECOVERY_REQUIRED] $($workerContext.FatalError)" }
        if ($workerContext.RecoveryRequired) { throw '[RECOVERY_REQUIRED] Worker could not confirm host process registration.' }
        if ($totals.Cancelled -gt 0) { $script:WorkerExitCode = 130 }
        elseif ($totals.Fail -gt 0 -or -not $reportSucceeded) { $script:WorkerExitCode = 1 }
        else { $script:WorkerExitCode = 0 }
    } catch {
        $message = [string]$_.Exception.Message
        if ($message -match '^\[RECOVERY_REQUIRED\]') { $script:WorkerExitCode = 4 }
        else { $script:WorkerExitCode = 1 }
        Write-MediaNormalizerWorkerError -Code $(if ($script:WorkerExitCode -eq 4) { 'RECOVERY_REQUIRED' } else { 'WORKER_FAILED' }) `
            -Message $message -RunId $options.RunId
    } finally {
        try {
            $null = Write-MediaNormalizerWorkerEvent -Event ([ordered]@{
                schemaVersion = 1; type = 'run-done'; runId = $options.RunId
                success = [int]$totals.Success; analyzed = [int]$totals.Analyzed; fail = [int]$totals.Fail
                skipped = [int]$totals.Skipped; cancelled = [int]$totals.Cancelled
                reportPath = $reportPath; reportSucceeded = $reportSucceeded
            })
        } finally {
            if ($jobLock) { $jobLock.Dispose() }
        }
    }
}

try {
    $line = $script:WorkerInput.ReadLine()
    if ($null -eq $line -or $line.Length -gt 1048576) { throw 'worker expects one command JSON object on stdin.' }
    try { $script:WorkerCommand = ConvertFrom-Json -InputObject $line -AsHashtable -ErrorAction Stop }
    catch { throw 'worker startup command is not valid JSON.' }
    $validation = Test-MediaNormalizerWorkerCommand -Message $script:WorkerCommand
    if (-not $validation.IsValid) {
        Write-MediaNormalizerWorkerError -Code 'INVALID_COMMAND' -Message ($validation.Errors -join '; ')
        exit 2
    }
    switch ([string]$script:WorkerCommand.cmd) {
        'capabilities' {
            Write-MediaNormalizerWorkerEvent -Event (Get-MediaNormalizerWorkerCapabilities)
            exit 0
        }
        'scan' {
            Write-MediaNormalizerWorkerEvent -Event (Invoke-MediaNormalizerWorkerScan -Command $script:WorkerCommand)
            exit 0
        }
        'normalize' {
            Invoke-MediaNormalizerWorkerNormalize -Command $script:WorkerCommand
            exit $script:WorkerExitCode
        }
        default {
            Write-MediaNormalizerWorkerError -Code 'INVALID_COMMAND' -Message 'Unsupported worker startup command.'
            exit 2
        }
    }
} catch {
    $message = [string]$_.Exception.Message
    if ($message -match '^\[JOB_ALREADY_RUNNING\]') {
        Write-MediaNormalizerWorkerError -Code 'JOB_ALREADY_RUNNING' -Message $message
        exit 3
    }
    if ($message -match '^\[RECOVERY_REQUIRED\]') {
        Write-MediaNormalizerWorkerError -Code 'RECOVERY_REQUIRED' -Message $message
        exit 4
    }
    Write-MediaNormalizerWorkerError -Code 'WORKER_FAILED' -Message $message
    exit 2
}
