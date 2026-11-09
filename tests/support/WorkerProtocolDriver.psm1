Set-StrictMode -Version Latest

# Test-only driver for scripts/mn-worker.ps1. It speaks the NDJSON protocol the
# Mac GUI uses: one command on stdin, then registration ACKs for every
# process-started and temporary-output event until the worker closes stdout.

function Invoke-WorkerProtocolCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkerPath,
        [Parameter(Mandatory)][string]$StorageRoot,
        [Parameter(Mandatory)][Collections.IDictionary]$Command,
        [scriptblock]$OnEvent,
        [int]$TimeoutSeconds = 180
    )

    $utf8 = [Text.UTF8Encoding]::new($false)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = $utf8
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $WorkerPath, '-StorageRoot', $StorageRoot)) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $stderr = $process.StandardError.ReadToEndAsync()
        $send = {
            param([Collections.IDictionary]$Message)
            $process.StandardInput.WriteLine((ConvertTo-Json -InputObject $Message -Depth 16 -Compress))
            $process.StandardInput.Flush()
        }.GetNewClosure()
        & $send $Command

        $events = [Collections.Generic.List[object]]::new()
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ($true) {
            $read = $process.StandardOutput.ReadLineAsync()
            while (-not $read.Wait(100)) {
                if ([DateTime]::UtcNow -gt $deadline) {
                    $process.Kill($true)
                    throw "worker did not finish within $TimeoutSeconds seconds."
                }
            }
            $line = $read.Result
            if ($null -eq $line) { break }
            $workerEvent = $line | ConvertFrom-Json -AsHashtable
            $events.Add($workerEvent)
            if ($OnEvent) { & $OnEvent $workerEvent $send }
            switch ($workerEvent.type) {
                'process-started' {
                    & $send ([ordered]@{
                            schemaVersion = 1; id = [guid]::NewGuid().ToString(); cmd = 'process-registration-ack'
                            runId = $workerEvent.runId; processToken = $workerEvent.processToken; processId = $workerEvent.processId
                            processStartedAtUtc = $workerEvent.processStartedAtUtc; accepted = $true; reason = $null
                        })
                }
                'temporary-output' {
                    & $send ([ordered]@{
                            schemaVersion = 1; id = [guid]::NewGuid().ToString(); cmd = 'temporary-file-registration-ack'
                            runId = $workerEvent.runId; temporaryPath = $workerEvent.temporaryPath; accepted = $true; reason = $null
                        })
                }
            }
        }
        try { $process.StandardInput.Close() } catch [IO.IOException] { }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            throw 'worker did not exit after closing stdout.'
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Events = $events.ToArray()
            StderrText = $stderr.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function New-WorkerPlannedScanCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$OutputSelection,
        [string]$OutputDir,
        [string]$AudioOutputFormat = 'mp3',
        [ValidateSet('rename', 'overwrite', 'skip')][string]$CollisionPolicy = 'rename',
        [switch]$AnalyzeOnly,
        [bool]$PreserveHierarchy = $true
    )

    return [ordered]@{
        schemaVersion = 1; id = [guid]::NewGuid().ToString(); cmd = 'scan'; paths = $Paths; recurse = $true
        outputSelection = $OutputSelection; audioOutputFormat = $AudioOutputFormat; outputDir = $OutputDir
        analyzeOnly = [bool]$AnalyzeOnly; preserveHierarchy = $PreserveHierarchy; collisionPolicy = $CollisionPolicy
        runId = [guid]::NewGuid().ToString()
    }
}

function New-WorkerPlannedNormalizeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Scan,
        [Parameter(Mandatory)][Collections.IDictionary]$ScanResult,
        [Parameter(Mandatory)][string[]]$SelectedPaths,
        [int]$SpeedPercent = 100
    )

    $rows = @($ScanResult.files | Where-Object { $_.path -in $SelectedPaths })
    return [ordered]@{
        schemaVersion = 1; id = [guid]::NewGuid().ToString(); cmd = 'normalize'; runId = [guid]::NewGuid().ToString()
        inputPaths = @($rows | ForEach-Object { $_.path }); outputDir = $Scan.outputDir
        target = -16.0; truePeak = -1.0; bitrate = '192k'; sampleRate = '48000'
        collisionPolicy = $Scan.collisionPolicy; speedPercent = $SpeedPercent; speedPercentByPath = @{}
        audioOutputFormat = $Scan.audioOutputFormat; analyzeOnly = $Scan.analyzeOnly; skipIfNormalized = $true
        normalizationTolerance = 0.5; recurse = $Scan.recurse; preserveHierarchy = $Scan.preserveHierarchy; reportPath = $null
        inputRoot = $ScanResult.inputRoot; scanPaths = $Scan.paths
        protectedInputs = @($ScanResult.files | ForEach-Object { $_.path })
        plannedFiles = @($rows | ForEach-Object {
                [ordered]@{ path = $_.path; formats = @($_.formats); size = $_.size; modifiedTicks = $_.modifiedTicks }
            })
        outputSelection = $Scan.outputSelection
    }
}

Export-ModuleMember -Function Invoke-WorkerProtocolCommand, New-WorkerPlannedScanCommand, New-WorkerPlannedNormalizeCommand
