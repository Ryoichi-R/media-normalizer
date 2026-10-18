Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'MediaNormalizer.Platform.psm1') -Scope Local -DisableNameChecking

function New-MediaNormalizerRunRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('running', 'recovering', 'completed', 'recovery-required')][string]$Status,
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$StartedAtUtc,
        [string]$UpdatedAtUtc,
        [Nullable[int]]$ResultCode
    )

    [pscustomobject]@{
        schemaVersion = 1
        runId = $RunId
        entrypoint = 'cli'
        status = $Status
        ownerProcessId = $ProcessId
        startedAtUtc = $StartedAtUtc
        updatedAtUtc = if ($UpdatedAtUtc) { $UpdatedAtUtc } else { [DateTime]::UtcNow.ToString('o') }
        resultCode = $ResultCode
    }
}

function Test-MediaNormalizerGuiRunRecord {
    param([Parameter(Mandatory)][pscustomobject]$Record)

    $required = @('schemaVersion', 'runId', 'entrypoint', 'status', 'ownerProcessId', 'startedAtUtc', 'updatedAtUtc', 'resultCode',
        'hostStartedAtUtc', 'workerProcessId', 'workerStartedAtUtc', 'processes', 'intermediatePaths', 'pendingProcessStarts', 'recoveryMessage')
    if (@($required | Where-Object { $Record.PSObject.Properties.Name -notcontains $_ }).Count -gt 0) { return $false }
    if ([int]$Record.schemaVersion -ne 2 -or [string]$Record.entrypoint -ne 'gui') { return $false }
    $allowed = @('schemaVersion', 'runId', 'entrypoint', 'status', 'ownerProcessId', 'startedAtUtc', 'updatedAtUtc', 'resultCode',
        'hostStartedAtUtc', 'workerProcessId', 'workerStartedAtUtc', 'processes', 'intermediatePaths', 'pendingProcessStarts', 'recoveryMessage')
    if (@($Record.PSObject.Properties.Name | Where-Object { $_ -notin $allowed }).Count -gt 0) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Record.runId) -or [int]$Record.ownerProcessId -lt 1) { return $false }
    if ($null -ne $Record.resultCode -and $Record.resultCode -isnot [int] -and $Record.resultCode -isnot [long]) { return $false }
    foreach ($dateProperty in @('startedAtUtc', 'updatedAtUtc', 'hostStartedAtUtc')) {
        $parsed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$Record.$dateProperty, [ref]$parsed)) { return $false }
    }
    if ($null -ne $Record.workerProcessId -and [int]$Record.workerProcessId -lt 1) { return $false }
    if (($null -eq $Record.workerProcessId) -ne ($null -eq $Record.workerStartedAtUtc)) { return $false }
    if ($null -ne $Record.workerStartedAtUtc) {
        $parsedWorkerStart = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$Record.workerStartedAtUtc, [ref]$parsedWorkerStart)) { return $false }
    }
    if ($Record.processes -isnot [System.Collections.IList] -or $Record.intermediatePaths -isnot [System.Collections.IList] -or
        $Record.pendingProcessStarts -isnot [System.Collections.IList]) { return $false }
    foreach ($process in $Record.processes) {
        if ($null -eq $process -or $process -isnot [pscustomobject]) { return $false }
        $processProperties = @($process.PSObject.Properties.Name)
        $requiredProcessFields = @('processId', 'parentProcessId', 'startedAtUtc')
        $allowedProcessFields = $requiredProcessFields + @('processToken', 'executablePath')
        if (@($requiredProcessFields | Where-Object { $processProperties -notcontains $_ }).Count -gt 0 -or
            @($processProperties | Where-Object { $_ -notin $allowedProcessFields }).Count -gt 0) { return $false }
        if (($process.processId -isnot [int] -and $process.processId -isnot [long]) -or
            ($process.parentProcessId -isnot [int] -and $process.parentProcessId -isnot [long]) -or
            [int]$process.processId -lt 1 -or [int]$process.parentProcessId -lt 1) { return $false }
        $parsedProcessStart = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$process.startedAtUtc, [ref]$parsedProcessStart)) { return $false }
        $processToken = if ($processProperties -contains 'processToken') { $process.processToken } else { $null }
        $executablePath = if ($processProperties -contains 'executablePath') { $process.executablePath } else { $null }
        if ($null -ne $processToken) {
            $parsedToken = [guid]::Empty
            if ($processToken -isnot [string] -or -not [guid]::TryParse([string]$processToken, [ref]$parsedToken)) { return $false }
        }
        if ($null -ne $executablePath -and $executablePath -isnot [string]) { return $false }
    }
    foreach ($path in $Record.intermediatePaths) {
        if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path)) { return $false }
    }
    foreach ($pending in $Record.pendingProcessStarts) {
        if ($null -eq $pending -or $pending -isnot [pscustomobject]) { return $false }
        $pendingProperties = @($pending.PSObject.Properties.Name)
        $requiredPendingFields = @('processToken', 'executablePath', 'arguments', 'parentProcessId', 'parentStartedAtUtc')
        $allowedPendingFields = $requiredPendingFields
        if (@($requiredPendingFields | Where-Object { $pendingProperties -notcontains $_ }).Count -gt 0 -or
            @($pendingProperties | Where-Object { $_ -notin $allowedPendingFields }).Count -gt 0) { return $false }
        $parsedPendingToken = [guid]::Empty
        if ($pending.processToken -isnot [string] -or -not [guid]::TryParse([string]$pending.processToken, [ref]$parsedPendingToken) -or
            $pending.executablePath -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$pending.executablePath)) { return $false }
        $parsedParentStart = [DateTimeOffset]::MinValue
        if (($pending.parentProcessId -isnot [int] -and $pending.parentProcessId -isnot [long]) -or [int]$pending.parentProcessId -lt 1 -or
            -not [DateTimeOffset]::TryParse([string]$pending.parentStartedAtUtc, [ref]$parsedParentStart) -or
            $pending.arguments -isnot [System.Collections.IList] -or @($pending.arguments | Where-Object { $_ -isnot [string] }).Count -gt 0) { return $false }
    }
    if ($null -ne $Record.recoveryMessage -and $Record.recoveryMessage -isnot [string]) { return $false }
    return $true
}

function Read-MediaNormalizerRunRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $safePath = Assert-MediaNormalizerWritablePath -Path $Path
    if (-not (Test-Path -LiteralPath $safePath -PathType Leaf)) { return $null }
    try {
        $record = Get-Content -LiteralPath $safePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "[RECOVERY_REQUIRED] run記録を読み取れません。手動削除せず診断が必要です: $safePath"
    }
    if ($record -isnot [pscustomobject]) { throw "[RECOVERY_REQUIRED] run記録のschemaが不正です: $safePath" }
    $properties = @($record.PSObject.Properties.Name)
    $isCliRecord = $false
    $cliRequired = @('schemaVersion', 'runId', 'entrypoint', 'status', 'ownerProcessId', 'startedAtUtc', 'updatedAtUtc')
    $missingCliFields = @($cliRequired | Where-Object { $properties -notcontains $_ })
    if ($missingCliFields.Count -eq 0) {
        $isCliRecord = [int]$record.schemaVersion -eq 1 -and [string]$record.entrypoint -eq 'cli' -and
            -not [string]::IsNullOrWhiteSpace([string]$record.runId) -and [int]$record.ownerProcessId -gt 0 -and
            [string]$record.status -in @('running', 'recovering', 'completed', 'recovery-required') -and
            -not [string]::IsNullOrWhiteSpace([string]$record.startedAtUtc) -and
            -not [string]::IsNullOrWhiteSpace([string]$record.updatedAtUtc)
    }
    $isGuiRecord = $false
    $guiIdentityFields = @('schemaVersion', 'entrypoint', 'status')
    $hasGuiIdentity = @($guiIdentityFields | Where-Object { $properties -contains $_ }).Count -eq 3
    if ($hasGuiIdentity) {
        if ([string]$record.status -in @('running', 'recovering', 'completed', 'recovery-required')) {
            $isGuiRecord = Test-MediaNormalizerGuiRunRecord -Record $record
        }
    }
    if (-not $isCliRecord -and -not $isGuiRecord) {
        throw "[RECOVERY_REQUIRED] run記録のschemaが不正です: $safePath"
    }
    return $record
}

function Write-MediaNormalizerRunRecordAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Record,
        [Parameter(Mandatory)][string]$Path
    )

    $safePath = Assert-MediaNormalizerWritablePath -Path $Path
    $directory = Split-Path -Parent $safePath
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = "$safePath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ConvertTo-Json -InputObject $Record -Depth 8
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($safePath)) {
            [IO.File]::Move($temporaryPath, $safePath, $true)
        } else {
            [IO.File]::Move($temporaryPath, $safePath)
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
}

function Enter-MediaNormalizerFileLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GuiLock', 'JobLock', 'RecoveryGuard')][string]$Kind,
        [string]$StorageRoot
    )

    $path = Get-MediaNormalizerStoragePath -Kind $Kind -StorageRoot $StorageRoot
    [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    try {
        return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        if ($Kind -eq 'JobLock') { throw '[JOB_ALREADY_RUNNING] 別の正規化処理が実行中です。' }
        if ($Kind -eq 'RecoveryGuard') { throw '[JOB_ALREADY_RUNNING] run/recovery guardを別processが保持しています。' }
        throw '[GUI_ALREADY_RUNNING] Media Normalizer GUIは既に起動しています。'
    }
}

function Enter-MediaNormalizerCliRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StorageRoot)

    $guardLock = Enter-MediaNormalizerFileLock -Kind RecoveryGuard -StorageRoot $StorageRoot
    $jobLock = $null
    $recordPath = Get-MediaNormalizerStoragePath -Kind RunRecord -StorageRoot $StorageRoot
    try {
        $existingRecord = Read-MediaNormalizerRunRecord -Path $recordPath
        if ($existingRecord -and $existingRecord.status -ne 'completed') {
            throw "[RECOVERY_REQUIRED] 未解決run記録が残っています (status=$($existingRecord.status), runId=$($existingRecord.runId))。"
        }
        $jobLock = Enter-MediaNormalizerFileLock -Kind JobLock -StorageRoot $StorageRoot
        $now = [DateTime]::UtcNow.ToString('o')
        $record = New-MediaNormalizerRunRecord -RunId ([guid]::NewGuid().ToString('D')) -Status running `
            -ProcessId $PID -StartedAtUtc $now -UpdatedAtUtc $now
        Write-MediaNormalizerRunRecordAtomic -Record $record -Path $recordPath
        return [pscustomobject]@{
            RunId = $record.runId
            RecordPath = $recordPath
            Record = $record
            GuardLock = $guardLock
            JobLock = $jobLock
        }
    } catch {
        if ($jobLock) { $jobLock.Dispose() }
        $guardLock.Dispose()
        throw
    }
}

function Complete-MediaNormalizerCliRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Run,
        [Parameter(Mandatory)][int]$ExitCode,
        [switch]$RecoveryRequired
    )

    try {
        $record = Read-MediaNormalizerRunRecord -Path $Run.RecordPath
        if (-not $record -or [string]$record.runId -ne [string]$Run.RunId -or [string]$record.status -ne 'running') {
            throw '[RECOVERY_REQUIRED] run記録が現在のCLI runと一致しません。'
        }
        $record.status = if ($RecoveryRequired) { 'recovery-required' } else { 'completed' }
        $record.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        $record.resultCode = $ExitCode
        Write-MediaNormalizerRunRecordAtomic -Record $record -Path $Run.RecordPath
        return $record
    } finally {
        if ($Run.JobLock) { $Run.JobLock.Dispose(); $Run.JobLock = $null }
        if ($Run.GuardLock) { $Run.GuardLock.Dispose(); $Run.GuardLock = $null }
    }
}

Export-ModuleMember -Function New-MediaNormalizerRunRecord, Read-MediaNormalizerRunRecord, Write-MediaNormalizerRunRecordAtomic, Enter-MediaNormalizerFileLock, Enter-MediaNormalizerCliRun, Complete-MediaNormalizerCliRun
