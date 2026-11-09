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
    $result = [ordered]@{
        schemaVersion = 1
        type = 'capabilities-result'
        id = $script:WorkerCommand.id
        modes = @('audio', 'video', 'both')
        audioInputExtensions = @(Get-AudioInputExtensions | Sort-Object)
        videoInputExtensions = @(Get-VideoInputExtensions | Sort-Object)
        audioOutputFormats = @(Get-AudioOutputFormats | Sort-Object)
    }
    if ($script:WorkerCommand.Contains('outputSelectionProtocol') -and $script:WorkerCommand.outputSelectionProtocol) {
        $result.outputSelections = @(Get-MediaNormalizerOutputSelections)
    }
    return $result
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

function New-MediaNormalizerWorkerControl {
    param([string]$RunId)

    $workerContext = [pscustomobject]@{
        RunId = $RunId
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

    return @{ Context = $workerContext; State = $state; Events = $eventsOut; Pump = $inputPump }
}

function Get-MediaNormalizerInputIdentity {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer) { return }
    if ($item.LinkTarget) { $item = Get-Item -LiteralPath $item.ResolvedTarget -Force -ErrorAction SilentlyContinue }
    if ($item -and $item.PSObject.Properties['UnixStat'] -and $item.UnixStat) {
        return "$($item.UnixStat.DeviceId):$($item.UnixStat.Inode)"
    }
    if ($item) { return $item.FullName }
}

function New-MediaNormalizerInputProtection {
    param([string[]]$Paths)

    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $Paths) {
        [void]$names.Add([IO.Path]::GetFullPath($path))
        $identity = Get-MediaNormalizerInputIdentity $path
        if ($identity) { [void]$identities.Add($identity) }
    }
    return {
        param([string]$Path)
        if ($names.Contains([IO.Path]::GetFullPath($Path))) { return $true }
        $identity = Get-MediaNormalizerInputIdentity $Path
        return $identity -and $identities.Contains($identity)
    }.GetNewClosure()
}

function Get-MediaNormalizerOutputRoute {
    param([IO.FileInfo]$File, $Inventory, [Collections.IDictionary]$Command)

    $result = [ordered]@{ kind = 'unknown'; formats = @(); reason = $null; speedReason = $null; warning = $null }
    if ($Inventory.StreamCounts.audio -lt 1) {
        $result.kind = 'no-audio'
        $result.reason = '音声トラックがありません。'
        return $result
    }
    $hasVideo = $Inventory.RealVideoCount -gt 0
    $result.kind = if ($hasVideo) { 'video' } else { 'audio' }
    if ($Command.analyzeOnly) { return $result }

    $extension = $File.Extension.TrimStart('.').ToLowerInvariant()
    $videoContainer = $hasVideo -and $extension -in @('mp4', 'mov', 'mkv') -and
        (Test-MediaNormalizerContainer $Inventory $extension)
    $avi = $hasVideo -and $extension -eq 'avi' -and (Test-MediaNormalizerContainer $Inventory 'avi')
    $selection = [string]$Command.outputSelection
    $audioFormat = [string]$Command.audioOutputFormat

    if ($selection -in (Get-AudioOutputFormats)) {
        $result.formats = @($selection)
    } elseif ($selection -eq 'mp4') {
        if (-not $hasVideo) { $result.reason = '映像がありません。' }
        elseif ($videoContainer -and $extension -eq 'mp4') { $result.formats = @('mp4') }
        else { $result.reason = 'この形式からの MP4 変換は未対応です。' }
    } elseif ($selection -eq 'original-video') {
        if ($videoContainer) { $result.formats = @($extension) }
        elseif (-not $hasVideo) { $result.reason = '映像がありません。' }
        else { $result.reason = '映像を保持できない形式です。' }
    } elseif ($videoContainer) {
        $result.formats = @(if ($selection -eq 'audio-and-video') { $audioFormat }; $extension)
    } elseif (-not $hasVideo -or $avi) {
        $result.formats = @($audioFormat)
        if ($avi) { $result.warning = '映像は出力されません。' }
    } else {
        $result.reason = '拡張子と動画形式を確認してください。音声形式を指定すると音声を抽出できます。'
    }

    if (@($result.formats | Where-Object { ".$_" -in (Get-VideoInputExtensions) }).Count -gt 0) {
        if ($Inventory.StreamCounts.subtitle -gt 0 -or $Inventory.ChapterCount -gt 0) {
            $result.speedReason = '字幕またはチャプターを保持するには速度を100%にしてください。'
        } elseif (-not (Test-VideoSpeedChangeSafety -Inventory $Inventory).IsSafe) {
            $result.speedReason = 'HDR・10bit以上または広色域の映像を保持するには速度を100%にしてください。'
        }
    }
    return $result
}

function Get-MediaNormalizerWorkerInventory {
    param([string]$Path, [hashtable]$Control)

    $timeout = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30))
    try {
        Get-MediaInventory -FilePath $Path -State $Control.State -PumpEvents $Control.Pump -CliMode -VerifyInputSnapshot -CancellationToken $timeout.Token
    } catch {
        if ($Control.Context.FatalError -or $Control.Context.RecoveryRequired -or $_.Exception.Message.StartsWith('[RECOVERY_REQUIRED]')) {
            throw "[RECOVERY_REQUIRED] $($_.Exception.Message)"
        }
        if ($timeout.IsCancellationRequested -and -not $Control.State.CancelRequested) {
            throw 'メディア情報の取得がタイムアウトしました。'
        }
        throw
    } finally {
        $timeout.Dispose()
    }
}

function Invoke-MediaNormalizerWorkerPlannedScan {
    param([Collections.IDictionary]$Command)

    $control = New-MediaNormalizerWorkerControl -RunId $Command.runId
    $root = Get-MediaInputRoot -InputPath $Command.paths
    $extensions = @(Get-AudioInputExtensions)
    $allFiles = Get-MediaInputFiles -InputPath $Command.paths -Recurse:$Command.recurse
    $files = @($allFiles | Where-Object { $_.Extension -in $extensions })
    $protected = New-MediaNormalizerInputProtection -Paths @($files | ForEach-Object FullName)
    $results = [Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        & $control.Pump
        if ($control.State.CancelRequested) { break }
        $duration = 0.0
        $size = 0L
        $modifiedTicks = 0L
        try {
            $inventory = Get-MediaNormalizerWorkerInventory -Path $file.FullName -Control $control
            $route = Get-MediaNormalizerOutputRoute -File $file -Inventory $inventory -Command $Command
            $duration = [math]::Max(0.0, $inventory.DurationSec)
            $size = $inventory.Length
            $modifiedTicks = $inventory.LastWriteTicks
        } catch {
            if ($_.Exception.Message.StartsWith('[RECOVERY_REQUIRED]')) { throw }
            if ($control.State.CancelRequested) { break }
            $route = @{ kind = 'unknown'; formats = @(); reason = $_.Exception.Message; speedReason = $null; warning = $null }
        }
        $destinations = @()
        if ($Command.outputDir -and $route.formats.Count -gt 0) {
            $directoryOptions = @{
                InputRoot = $root; InputFilePath = $file.FullName; OutputRoot = $Command.outputDir
                PreserveHierarchy = $Command.preserveHierarchy
            }
            $directory = Resolve-MediaOutputDirectory @directoryOptions
            $destinations = @(foreach ($format in $route.formats) { Join-Path $directory "$($file.BaseName).$format" })
            if (@($destinations | Where-Object { & $protected $_ }).Count -gt 0) {
                $message = '出力予定名が入力原本と重複しています。'
                $route.warning = (@($route.warning, $message) | Where-Object { $_ }) -join ' '
                if ($Command.collisionPolicy -eq 'overwrite') { $route.reason = $message }
            }
        }
        $results.Add([ordered]@{
            path = $file.FullName; kind = $route.kind; formats = @($route.formats)
            reason = $route.reason; speedReason = $route.speedReason; warning = $route.warning
            destinations = $destinations; size = $size; modifiedTicks = $modifiedTicks; duration = $duration
        })
    }
    & $control.Pump
    if ($control.State.CancelRequested) { $results.Clear() }
    return [ordered]@{
        schemaVersion = 1; type = 'scan-result'; id = $Command.id; runId = $Command.runId
        inputRoot = $root; status = if ($control.State.CancelRequested) { 'cancelled' } else { 'completed' }
        files = $results.ToArray()
    }
}

function Get-MediaNormalizerWorkerBatch {
    param([Collections.IDictionary]$Command, [hashtable]$Options, [hashtable]$Control, [hashtable]$Totals)

    $state = $Control.State
    $snapshots = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($snapshot in $Command.plannedFiles) { $snapshots.Add([IO.Path]::GetFullPath($snapshot.path), $snapshot) }
    $protectedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $Command.protectedInputs) { [void]$protectedPaths.Add([IO.Path]::GetFullPath($path)) }
    if ([IO.Path]::GetFullPath($Command.inputRoot) -cne (Get-MediaInputRoot -InputPath $Command.scanPaths) -or
        @($Options.InputPath | Where-Object { -not $snapshots.ContainsKey($_) -or -not $protectedPaths.Contains($_) }).Count -gt 0) {
        throw 'スキャンの入力ルートまたは選択情報が一致しません。再スキャンしてください。'
    }

    $groups = [ordered]@{ audio = [Collections.Generic.List[IO.FileInfo]]::new(); video = [Collections.Generic.List[IO.FileInfo]]::new() }
    $inventories = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($path in $Options.InputPath) {
        & $Control.Pump
        try {
            if ($state.CancelRequested) { throw [OperationCanceledException]::new('処理前にキャンセルされました。') }
            $file = [IO.FileInfo]::new($path)
            $snapshot = $snapshots[$path]
            $sourceFile = Get-MediaInputFileInfo -Path $path
            if (-not $sourceFile -or $sourceFile.Length -ne [long]$snapshot.size -or
                $sourceFile.LastWriteTimeUtc.Ticks -ne [long]$snapshot.modifiedTicks) {
                throw '入力が変更されたか見つかりません。'
            }
            $inventory = Get-MediaNormalizerWorkerInventory -Path $path -Control $Control
            if ($inventory.ResolvedPath -cne $sourceFile.FullName -or
                $inventory.Length -ne [long]$snapshot.size -or $inventory.LastWriteTicks -ne [long]$snapshot.modifiedTicks) {
                throw 'メディア情報の取得中に入力が変更されました。'
            }
            $route = Get-MediaNormalizerOutputRoute -File $file -Inventory $inventory -Command $Command
            if ($route.reason) { throw $route.reason }
            if (($route.formats -join ',') -cne ($snapshot.formats -join ',')) { throw '出力予定形式が変わりました。' }
            $speed = if ($Options.SpeedPercentByPath.ContainsKey($path)) { $Options.SpeedPercentByPath[$path] } else { $Options.SpeedPercent }
            if ($speed -ne 100 -and $route.speedReason) { throw $route.speedReason }

            $inventories.Add($path, $inventory)
            $state.DurationMap[$path] = $inventory.DurationSec
            $modes = if ($Options.AnalyzeOnly) { @('audio') } else {
                @(foreach ($format in $route.formats) {
                    if (".$format" -in (Get-VideoInputExtensions)) { 'video' } else { 'audio' }
                })
            }
            foreach ($mode in $modes) {
                $groups[$mode].Add($file)
                $state.ProgressTotal++
                $state.TotalDurationSec += $inventory.DurationSec
            }
        } catch {
            if ($_.Exception.Message.StartsWith('[RECOVERY_REQUIRED]')) { throw }
            $status = if ($state.CancelRequested) { 'cancelled' } else { 'failed' }
            $message = $_.Exception.Message
            if ($status -eq 'cancelled') { $Totals.Cancelled++ }
            else { $Totals.Fail++; $message += ' 再スキャンしてください。' }
            $state.ReportRecords.Add([pscustomobject]@{
                inputPath = $path; outputPath = $null; mode = $null; outputFormat = $null
                action = $status; completedAt = (Get-Date).ToString('o'); error = $message
            })
            Write-MediaNormalizerWorkerEvent ([ordered]@{
                schemaVersion = 1; type = 'file-done'; runId = $Options.RunId; inputPath = $path; outputPath = $null
                status = $status; measurements = $null; message = $message
            })
            Write-MediaNormalizerWorkerEvent ([ordered]@{
                schemaVersion = 1; type = 'log'; runId = $Options.RunId; level = 'warning'; message = "$path — $message"
            })
        }
    }
    return @{ Groups = $groups; Inventories = $inventories; Protected = (New-MediaNormalizerInputProtection -Paths $Command.protectedInputs) }
}

function ConvertTo-MediaNormalizerWorkerOptions {
    param([Parameter(Mandatory)][Collections.IDictionary]$Command)

    $speedByPath = @{}
    if ($Command.Contains('speedPercentByPath')) {
        foreach ($key in $Command.speedPercentByPath.Keys) { $speedByPath[[string]$key] = [int]$Command.speedPercentByPath[$key] }
    }
    $planned = $Command.Contains('outputSelection')
    $audioFormat = if ($planned -and $Command.outputSelection -in (Get-AudioOutputFormats)) {
        [string]$Command.outputSelection
    } else { [string]$Command.audioOutputFormat }
    return @{
        RunId = [string]$Command.runId
        InputPath = @($Command.inputPaths | ForEach-Object { [IO.Path]::GetFullPath([string]$_) })
        InputDir = if ($planned) { [IO.Path]::GetFullPath($Command.inputRoot) } else { Get-MediaInputRoot -InputPath $Command.inputPaths }
        OutputDir = [IO.Path]::GetFullPath($Command.outputDir)
        Mode = if ($planned) { $null } else { [string]$Command.mode }
        Target = [double]$Command.target
        TruePeak = [double]$Command.truePeak
        Bitrate = [string]$Command.bitrate
        SampleRate = [string]$Command.sampleRate
        CollisionPolicy = [string]$Command.collisionPolicy
        SpeedPercent = [int]$Command.speedPercent
        SpeedPercentByPath = $speedByPath
        AudioOutputFormat = $audioFormat
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
    $planned = $Command.Contains('outputSelection')
    if (-not $planned) {
        foreach ($path in $options.InputPath) {
            if (-not (Test-Path -LiteralPath $path)) { throw "入力パスが見つかりません: $path" }
        }
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

    $control = New-MediaNormalizerWorkerControl -RunId $options.RunId
    $workerContext = $control.Context
    $state = $control.State
    $eventsOut = $control.Events
    $inputPump = $control.Pump

    $script:WorkerExitCode = 1
    $totals = @{ Success = 0; Analyzed = 0; Fail = 0; Cancelled = 0; Skipped = 0 }
    $reportPath = $options.ReportPath
    $reportSucceeded = $true
    $start = [ordered]@{ schemaVersion = 1; type = 'run-start'; runId = $options.RunId }
    if ($planned) { $start.outputSelection = $Command.outputSelection } else { $start.mode = $options.Mode }
    try {
        Write-MediaNormalizerWorkerEvent $start
        $batch = $null
        if ($planned) {
            $batch = Get-MediaNormalizerWorkerBatch -Command $Command -Options $options -Control $control -Totals $totals
            $modes = @($batch.Groups.Keys | Where-Object { $batch.Groups[$_].Count -gt 0 })
        } else {
            $modes = if ($options.Mode -eq 'both') {
                if ($options.AnalyzeOnly) { @('audio') } else { @('audio', 'video') }
            } else { @($options.Mode) }
        }
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
            if ($planned) {
                [void]$parameters.Remove('ReportMode')
                $parameters.TargetFiles = $batch.Groups[$mode].ToArray()
                $parameters.InputInventories = $batch.Inventories
                $parameters.IsProtectedInput = $batch.Protected
            }
            $result = Invoke-Normalize @parameters
            foreach ($counter in @($totals.Keys)) { $totals[$counter] += [int]$result[$counter] }
            if ($result.ContainsKey('ReportPath') -and $result.ReportPath) { $reportPath = [string]$result.ReportPath }
            if ($result.ContainsKey('ReportSucceeded') -and -not $result.ReportSucceeded) { $reportSucceeded = $false }
            if (-not $planned -and $totals.Cancelled -gt 0) { break }
        }
        if ($planned) {
            $reportPath = if ($options.ReportPath) { $options.ReportPath } else {
                Join-Path $options.OutputDir ('media-normalizer-report-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.json')
            }
            try {
                if (& $batch.Protected $reportPath) { throw 'レポート出力先が入力原本を指しています。' }
                $reportPath = Write-NormalizationReport -Path $reportPath -Records $state.ReportRecords.ToArray() -Configuration @{
                    outputSelection = $Command.outputSelection
                    audioOutputFormat = $options.AudioOutputFormat
                    targetLufs = $options.Target; truePeakDbtp = $options.TruePeak
                    bitrate = $options.Bitrate; sampleRate = $options.SampleRate
                    analyzeOnly = $options.AnalyzeOnly; skipIfNormalized = $options.SkipIfNormalized
                    normalizationTolerance = $options.NormalizationTolerance
                    recurse = $options.Recurse; preserveHierarchy = $options.PreserveHierarchy
                }
            } catch {
                $reportSucceeded = $false
                Write-MediaNormalizerWorkerError -Code 'REPORT_FAILED' -Message $_.Exception.Message -RunId $options.RunId
            }
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
            if ($script:WorkerCommand.Contains('outputSelection')) {
                Write-MediaNormalizerWorkerEvent -Event (Invoke-MediaNormalizerWorkerPlannedScan -Command $script:WorkerCommand)
            } else {
                Write-MediaNormalizerWorkerEvent -Event (Invoke-MediaNormalizerWorkerScan -Command $script:WorkerCommand)
            }
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
