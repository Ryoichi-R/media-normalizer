Set-StrictMode -Version Latest

function ConvertTo-MediaNormalizerWorkerHashtable {
    param([Parameter(Mandatory)][object]$Message)

    if ($Message -is [string]) {
        try { return ,([string]$Message | ConvertFrom-Json -AsHashtable -ErrorAction Stop) }
        catch { return $null }
    }
    if ($Message -is [Collections.IDictionary]) { return ,$Message }
    try { return ,(ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Message -Depth 16 -Compress) -AsHashtable -ErrorAction Stop) }
    catch { return $null }
}

function New-MediaNormalizerWorkerValidationResult {
    param([System.Collections.Generic.List[string]]$Errors)
    return [pscustomobject]@{ IsValid = $Errors.Count -eq 0; Errors = $Errors.ToArray() }
}

function Test-MediaNormalizerWorkerString {
    param([object]$Value, [switch]$AllowEmpty)
    if ($Value -isnot [string]) { return $false }
    return $AllowEmpty -or -not [string]::IsNullOrWhiteSpace($Value)
}

function Test-MediaNormalizerWorkerNumber {
    param([object]$Value, [switch]$Integer)
    if ($Value -is [bool]) { return $false }
    $numericTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64], [single], [double], [decimal])
    if ($Value -isnot [ValueType] -or $Value.GetType() -notin $numericTypes) { return $false }
    if ($Integer -and ([double]$Value -ne [math]::Truncate([double]$Value))) { return $false }
    return $true
}

function Test-MediaNormalizerWorkerBoolean {
    param([object]$Value)
    return $Value -is [bool]
}

function Test-MediaNormalizerWorkerArray {
    param([object]$Value)
    return $Value -is [System.Collections.IList]
}

function Test-MediaNormalizerWorkerGuid {
    param([object]$Value)
    $parsed = [guid]::Empty
    return (Test-MediaNormalizerWorkerString $Value) -and [guid]::TryParse([string]$Value, [ref]$parsed)
}

function Test-MediaNormalizerWorkerDateTime {
    param([object]$Value)
    if ($Value -is [DateTime] -or $Value -is [DateTimeOffset]) { return $true }
    $parsed = [DateTimeOffset]::MinValue
    return (Test-MediaNormalizerWorkerString $Value) -and [DateTimeOffset]::TryParse([string]$Value, [ref]$parsed)
}

function Test-MediaNormalizerWorkerEnum {
    param([object]$Value, [string[]]$Allowed)
    return (Test-MediaNormalizerWorkerString $Value) -and [string]$Value -cin $Allowed
}

function Get-MediaNormalizerWorkerShapeErrors {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Message,
        [Parameter(Mandatory)][string[]]$Required,
        [Parameter(Mandatory)][string[]]$Allowed
    )

    $errors = [Collections.Generic.List[string]]::new()
    foreach ($name in $Required) {
        if (-not $Message.Contains($name)) { $errors.Add("missing required field: $name") }
    }
    foreach ($name in $Message.Keys) {
        if ([string]$name -notin $Allowed) { $errors.Add("unexpected field: $name") }
    }
    if (-not $Message.Contains('schemaVersion') -or
        -not (Test-MediaNormalizerWorkerNumber $Message.schemaVersion -Integer) -or
        [int]$Message['schemaVersion'] -ne 1) {
        $errors.Add('schemaVersion must be integer 1')
    }
    return ,$errors
}

function Test-MediaNormalizerWorkerMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Message,
        [Parameter(Mandatory)][ValidateSet('Command', 'Event')][string]$Kind
    )

    $data = ConvertTo-MediaNormalizerWorkerHashtable $Message
    $errors = [Collections.Generic.List[string]]::new()
    if ($data -isnot [Collections.IDictionary]) {
        $errors.Add('message must be a JSON object')
        return New-MediaNormalizerWorkerValidationResult $errors
    }

    if ($Kind -eq 'Command') {
        $name = [string]$data.cmd
        $idRequired = @('schemaVersion', 'id', 'cmd')
        switch ($name) {
            'capabilities' { $required = $idRequired; $allowed = $idRequired }
            'scan' { $required = $idRequired + @('paths', 'mode', 'recurse'); $allowed = $required }
            'normalize' {
                $required = $idRequired + @('runId', 'inputPaths', 'outputDir', 'mode', 'target', 'truePeak', 'bitrate', 'sampleRate', 'collisionPolicy', 'speedPercent', 'audioOutputFormat', 'analyzeOnly', 'skipIfNormalized', 'normalizationTolerance', 'recurse', 'preserveHierarchy')
                $allowed = $required + @('speedPercentByPath', 'reportPath')
            }
            'cancel' { $required = $idRequired + @('runId'); $allowed = $required }
            'process-registration-ack' { $required = $idRequired + @('runId', 'processToken', 'processId', 'processStartedAtUtc', 'accepted'); $allowed = $required + @('reason') }
            'temporary-file-registration-ack' { $required = $idRequired + @('runId', 'temporaryPath', 'accepted'); $allowed = $required + @('reason') }
            default {
                $errors.Add('cmd is unknown')
                return New-MediaNormalizerWorkerValidationResult $errors
            }
        }
        $errors = Get-MediaNormalizerWorkerShapeErrors -Message $data -Required $required -Allowed $allowed
        if ($errors.Count -gt 0) { return New-MediaNormalizerWorkerValidationResult $errors }
        if (-not (Test-MediaNormalizerWorkerGuid $data.id)) { $errors.Add('id must be a UUID') }
        switch ($name) {
            { $_ -in 'scan', 'normalize' } {
                if (-not (Test-MediaNormalizerWorkerArray $data[$name -eq 'scan' ? 'paths' : 'inputPaths'])) { $errors.Add('input paths must be an array') }
                else {
                    $pathKey = if ($name -eq 'scan') { 'paths' } else { 'inputPaths' }
                    $paths = @($data[$pathKey])
                    if ($paths.Count -lt 1 -or @($paths | Where-Object { -not (Test-MediaNormalizerWorkerString $_) }).Count -gt 0) { $errors.Add("$pathKey must contain non-empty strings") }
                }
                if (-not (Test-MediaNormalizerWorkerEnum $data.mode @('audio', 'video', 'both'))) { $errors.Add('mode is invalid') }
            }
        }
        switch ($name) {
            'scan' { if (-not (Test-MediaNormalizerWorkerBoolean $data.recurse)) { $errors.Add('recurse must be boolean') } }
            'normalize' {
                if (-not (Test-MediaNormalizerWorkerGuid $data['runId'])) { $errors.Add('runId must be a UUID') }
                if (-not (Test-MediaNormalizerWorkerString $data.outputDir)) { $errors.Add('outputDir must be a non-empty string') }
                foreach ($numberName in @('target', 'truePeak', 'normalizationTolerance')) {
                    if (-not (Test-MediaNormalizerWorkerNumber $data[$numberName])) { $errors.Add("$numberName must be numeric") }
                }
                if ([double]$data.normalizationTolerance -lt 0 -or [double]$data.normalizationTolerance -gt 10) { $errors.Add('normalizationTolerance is out of range') }
                if (-not (Test-MediaNormalizerWorkerNumber $data.speedPercent -Integer) -or [int]$data.speedPercent -lt 50 -or [int]$data.speedPercent -gt 200) { $errors.Add('speedPercent is out of range') }
                if (-not (Test-MediaNormalizerWorkerEnum $data.collisionPolicy @('rename', 'skip', 'overwrite'))) { $errors.Add('collisionPolicy is invalid') }
                if (-not (Test-MediaNormalizerWorkerEnum $data.audioOutputFormat @('mp3', 'm4a', 'aac', 'flac', 'wav', 'opus', 'ogg'))) { $errors.Add('audioOutputFormat is invalid') }
                foreach ($boolName in @('analyzeOnly', 'skipIfNormalized', 'recurse', 'preserveHierarchy')) {
                    if (-not (Test-MediaNormalizerWorkerBoolean $data[$boolName])) { $errors.Add("$boolName must be boolean") }
                }
                foreach ($stringName in @('bitrate', 'sampleRate')) {
                    if (-not (Test-MediaNormalizerWorkerString $data[$stringName])) { $errors.Add("$stringName must be a non-empty string") }
                }
                if ($data.Contains('reportPath') -and $null -ne $data['reportPath'] -and -not (Test-MediaNormalizerWorkerString $data['reportPath'])) { $errors.Add('reportPath must be a string or null') }
                if ($data.Contains('speedPercentByPath')) {
                    if ($data.speedPercentByPath -isnot [Collections.IDictionary]) { $errors.Add('speedPercentByPath must be an object') }
                    else {
                        foreach ($speed in $data.speedPercentByPath.Values) {
                            if (-not (Test-MediaNormalizerWorkerNumber $speed -Integer) -or [int]$speed -lt 50 -or [int]$speed -gt 200) { $errors.Add('speedPercentByPath values must be integers from 50 to 200'); break }
                        }
                    }
                }
            }
            'cancel' { if (-not (Test-MediaNormalizerWorkerGuid $data['runId'])) { $errors.Add('runId must be a UUID') } }
            'process-registration-ack' {
                if (-not (Test-MediaNormalizerWorkerGuid $data['runId']) -or -not (Test-MediaNormalizerWorkerGuid $data.processToken)) { $errors.Add('runId and processToken must be UUIDs') }
                if (-not (Test-MediaNormalizerWorkerNumber $data.processId -Integer) -or [int64]$data.processId -lt 1) { $errors.Add('processId must be a positive integer') }
                if (-not (Test-MediaNormalizerWorkerDateTime $data.processStartedAtUtc)) { $errors.Add('processStartedAtUtc must be a timestamp') }
                if (-not (Test-MediaNormalizerWorkerBoolean $data.accepted)) { $errors.Add('accepted must be boolean') }
                if ($data.Contains('reason') -and $null -ne $data['reason'] -and -not (Test-MediaNormalizerWorkerString $data['reason'] -AllowEmpty)) { $errors.Add('reason must be string or null') }
            }
            'temporary-file-registration-ack' {
                if (-not (Test-MediaNormalizerWorkerGuid $data['runId'])) { $errors.Add('runId must be a UUID') }
                if (-not (Test-MediaNormalizerWorkerString $data.temporaryPath)) { $errors.Add('temporaryPath must be a non-empty string') }
                if (-not (Test-MediaNormalizerWorkerBoolean $data.accepted)) { $errors.Add('accepted must be boolean') }
                if ($data.Contains('reason') -and $null -ne $data['reason'] -and -not (Test-MediaNormalizerWorkerString $data['reason'] -AllowEmpty)) { $errors.Add('reason must be string or null') }
            }
        }
    } else {
        $name = [string]$data.type
        $common = @('schemaVersion', 'type')
        switch ($name) {
            'capabilities-result' { $required = $common + @('id', 'modes', 'audioInputExtensions', 'videoInputExtensions', 'audioOutputFormats'); $allowed = $required }
            'scan-result' { $required = $common + @('id', 'files'); $allowed = $required }
            'run-start' { $required = $common + @('runId', 'mode'); $allowed = $required }
            'file-start' { $required = $common + @('runId', 'fileIndex', 'total', 'inputPath'); $allowed = $required }
            'progress' { $required = $common + @('runId', 'percent', 'phase', 'eta', 'inputPath'); $allowed = $required }
            'log' { $required = $common + @('runId', 'level', 'message'); $allowed = $required }
            'file-done' { $required = $common + @('runId', 'inputPath', 'outputPath', 'status', 'measurements', 'message'); $allowed = $required }
            'run-done' { $required = $common + @('runId', 'success', 'analyzed', 'fail', 'skipped', 'cancelled', 'reportPath', 'reportSucceeded'); $allowed = $required }
            'error' { $required = $common + @('code', 'message'); $allowed = $required + @('runId', 'inputPath') }
            'process-starting' { $required = $common + @('runId', 'processToken', 'executablePath', 'arguments', 'parentProcessId', 'parentStartedAtUtc'); $allowed = $required }
            'process-started' { $required = $common + @('runId', 'processToken', 'processId', 'processStartedAtUtc', 'executablePath', 'parentProcessId', 'parentStartedAtUtc'); $allowed = $required }
            'process-exited' { $required = $common + @('runId', 'processToken', 'processId', 'processStartedAtUtc', 'exitCode'); $allowed = $required }
            'temporary-output' { $required = $common + @('runId', 'inputPath', 'temporaryPath', 'finalPath', 'role'); $allowed = $required }
            default {
                $errors.Add('type is unknown')
                return New-MediaNormalizerWorkerValidationResult $errors
            }
        }
        $errors = Get-MediaNormalizerWorkerShapeErrors -Message $data -Required $required -Allowed $allowed
        if ($errors.Count -gt 0) { return New-MediaNormalizerWorkerValidationResult $errors }
        if ($name -in @('capabilities-result', 'scan-result')) {
            if (-not (Test-MediaNormalizerWorkerGuid $data.id)) { $errors.Add('id must be a UUID') }
        } elseif ($name -ne 'error') {
            if (-not (Test-MediaNormalizerWorkerGuid $data['runId'])) { $errors.Add('runId must be a UUID') }
        }
        switch ($name) {
            'capabilities-result' {
                foreach ($arrayName in @('modes', 'audioInputExtensions', 'videoInputExtensions', 'audioOutputFormats')) {
                    if (-not (Test-MediaNormalizerWorkerArray $data[$arrayName])) { $errors.Add("$arrayName must be an array"); continue }
                    if (@($data[$arrayName] | Where-Object { -not (Test-MediaNormalizerWorkerString $_) }).Count -gt 0) { $errors.Add("$arrayName must contain strings") }
                }
                if (@($data.modes | Where-Object { $_ -notin @('audio', 'video', 'both') }).Count -gt 0) { $errors.Add('modes contains an invalid mode') }
                if (@($data.audioOutputFormats | Where-Object { $_ -notin @('mp3', 'm4a', 'aac', 'flac', 'wav', 'opus', 'ogg') }).Count -gt 0) { $errors.Add('audioOutputFormats contains an invalid format') }
            }
            'scan-result' {
                if (-not (Test-MediaNormalizerWorkerArray $data.files)) { $errors.Add('files must be an array') }
                else { foreach ($file in $data.files) {
                    $requiredFileFields = @('path', 'extension', 'audioEligible', 'videoEligible')
                    if ($file -isnot [Collections.IDictionary] -or @($requiredFileFields | Where-Object { -not $file.Contains($_) }).Count -gt 0) { $errors.Add('each file needs path, extension, audioEligible, and videoEligible'); break }
                    if (-not (Test-MediaNormalizerWorkerString $file.path) -or -not (Test-MediaNormalizerWorkerString $file.extension -AllowEmpty) -or -not (Test-MediaNormalizerWorkerBoolean $file.audioEligible) -or -not (Test-MediaNormalizerWorkerBoolean $file.videoEligible)) { $errors.Add('scan file entry has invalid field types'); break }
                    if (@($file.Keys | Where-Object { $_ -notin @('path', 'extension', 'audioEligible', 'videoEligible') }).Count -gt 0) { $errors.Add('scan file entry has unexpected fields'); break }
                } }
            }
            'run-start' { if (-not (Test-MediaNormalizerWorkerEnum $data.mode @('audio', 'video', 'both'))) { $errors.Add('mode is invalid') } }
            'file-start' {
                if (-not (Test-MediaNormalizerWorkerNumber $data.fileIndex -Integer) -or [int]$data.fileIndex -lt 1 -or -not (Test-MediaNormalizerWorkerNumber $data.total -Integer) -or [int]$data.total -lt 1) { $errors.Add('fileIndex and total must be positive integers') }
                if (-not (Test-MediaNormalizerWorkerString $data['inputPath'])) { $errors.Add('inputPath is invalid') }
            }
            'progress' {
                if (-not (Test-MediaNormalizerWorkerNumber $data.percent) -or [double]$data.percent -lt 0 -or [double]$data.percent -gt 100) { $errors.Add('percent must be from 0 to 100') }
                if (-not (Test-MediaNormalizerWorkerString $data.phase)) { $errors.Add('phase must be a non-empty string') }
                if ($null -ne $data.eta -and (-not (Test-MediaNormalizerWorkerNumber $data.eta) -or [double]$data.eta -lt 0)) { $errors.Add('eta must be non-negative or null') }
                if ($null -ne $data.inputPath -and -not (Test-MediaNormalizerWorkerString $data['inputPath'])) { $errors.Add('inputPath must be string or null') }
            }
            'log' {
                if (-not (Test-MediaNormalizerWorkerEnum $data.level @('debug', 'info', 'warning', 'error'))) { $errors.Add('level is invalid') }
                if (-not (Test-MediaNormalizerWorkerString $data.message -AllowEmpty)) { $errors.Add('message must be a string') }
            }
            'file-done' {
                if (-not (Test-MediaNormalizerWorkerString $data['inputPath'])) { $errors.Add('inputPath is invalid') }
                if ($null -ne $data.outputPath -and -not (Test-MediaNormalizerWorkerString $data.outputPath)) { $errors.Add('outputPath must be string or null') }
                if (-not (Test-MediaNormalizerWorkerEnum $data.status @('normalized', 'analyzed', 'skipped', 'failed', 'cancelled'))) { $errors.Add('status is invalid') }
                if ($null -ne $data.measurements -and $data.measurements -isnot [Collections.IDictionary]) { $errors.Add('measurements must be object or null') }
                if ($null -ne $data.message -and -not (Test-MediaNormalizerWorkerString $data.message -AllowEmpty)) { $errors.Add('message must be string or null') }
            }
            'run-done' {
                foreach ($counter in @('success', 'analyzed', 'fail', 'skipped', 'cancelled')) {
                    if (-not (Test-MediaNormalizerWorkerNumber $data[$counter] -Integer) -or [int64]$data[$counter] -lt 0) { $errors.Add("$counter must be a non-negative integer") }
                }
                if ($null -ne $data['reportPath'] -and -not (Test-MediaNormalizerWorkerString $data['reportPath'])) { $errors.Add('reportPath must be string or null') }
                if ($null -ne $data.reportSucceeded -and -not (Test-MediaNormalizerWorkerBoolean $data.reportSucceeded)) { $errors.Add('reportSucceeded must be boolean or null') }
            }
            'error' {
                if (-not (Test-MediaNormalizerWorkerString $data.code) -or -not (Test-MediaNormalizerWorkerString $data.message)) { $errors.Add('error code and message must be non-empty strings') }
                if ($data.Contains('runId')) {
                    if (-not (Test-MediaNormalizerWorkerGuid $data['runId'])) { $errors.Add('runId must be a UUID') }
                }
                if ($data.Contains('inputPath')) {
                    if (-not (Test-MediaNormalizerWorkerString $data['inputPath'])) { $errors.Add('inputPath must be a non-empty string') }
                }
            }
            { $_ -in 'process-starting', 'process-started', 'process-exited' } {
                if (-not (Test-MediaNormalizerWorkerGuid $data.processToken)) { $errors.Add('processToken must be a UUID') }
                if ($name -ne 'process-starting' -and (-not (Test-MediaNormalizerWorkerNumber $data.processId -Integer) -or [int64]$data.processId -lt 1)) { $errors.Add('processId must be a positive integer') }
                if ($name -ne 'process-exited' -and -not (Test-MediaNormalizerWorkerString $data.executablePath)) { $errors.Add('executablePath must be a non-empty string') }
                if ($name -eq 'process-starting') {
                    if (-not (Test-MediaNormalizerWorkerArray $data.arguments)) { $errors.Add('arguments must be an array') }
                    elseif (@($data.arguments | Where-Object { -not (Test-MediaNormalizerWorkerString $_ -AllowEmpty) }).Count -gt 0) { $errors.Add('arguments must contain strings') }
                }
                if ($name -in @('process-starting', 'process-started')) {
                    if (-not (Test-MediaNormalizerWorkerNumber $data.parentProcessId -Integer) -or [int64]$data.parentProcessId -lt 1) { $errors.Add('parentProcessId must be positive') }
                    if (-not (Test-MediaNormalizerWorkerDateTime $data.parentStartedAtUtc)) { $errors.Add('parentStartedAtUtc must be a timestamp') }
                }
                if ($name -in @('process-started', 'process-exited') -and -not (Test-MediaNormalizerWorkerDateTime $data.processStartedAtUtc)) { $errors.Add('processStartedAtUtc must be a timestamp') }
                if ($name -eq 'process-exited' -and -not (Test-MediaNormalizerWorkerNumber $data.exitCode -Integer)) { $errors.Add('exitCode must be an integer') }
            }
            'temporary-output' {
                foreach ($pathName in @('inputPath', 'temporaryPath', 'finalPath')) {
                    if (-not (Test-MediaNormalizerWorkerString $data[$pathName])) { $errors.Add("$pathName must be a non-empty string") }
                }
                if (-not (Test-MediaNormalizerWorkerEnum $data.role @('primary', 'speed'))) { $errors.Add('role is invalid') }
            }
        }
    }
    return New-MediaNormalizerWorkerValidationResult $errors
}

function Test-MediaNormalizerWorkerCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Message)
    return Test-MediaNormalizerWorkerMessage -Message $Message -Kind Command
}

function Test-MediaNormalizerWorkerEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Message)
    return Test-MediaNormalizerWorkerMessage -Message $Message -Kind Event
}

Export-ModuleMember -Function Test-MediaNormalizerWorkerCommand, Test-MediaNormalizerWorkerEvent
