Set-StrictMode -Version Latest

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N1} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -lt 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) {
        return '--:--'
    }
    $total = [int][math]::Round($Seconds)
    $h = [int][math]::Floor($total / 3600)
    $m = [int][math]::Floor(($total % 3600) / 60)
    $s = [int]($total % 60)
    if ($h -gt 0) {
        return '{0}:{1:D2}:{2:D2}' -f $h, $m, $s
    }
    return '{0}:{1:D2}' -f $m, $s
}

function Test-FfprobeAvailable {
    param([pscustomobject]$State)
    if ($null -eq $State.FfprobeAvailable) {
        $State.FfprobeAvailable = [bool](Get-Command ffprobe -ErrorAction SilentlyContinue)
    }
    return $State.FfprobeAvailable
}

function Get-MediaDuration {
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][string]$FilePath
    )
    if (-not (Test-FfprobeAvailable -State $State)) { return -1.0 }
    try {
        $ffprobeArgs = @('-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', $FilePath)
        $result = & ffprobe @ffprobeArgs 2>$null
        $resultStr = (@($result) -join '').Trim()
        if ([string]::IsNullOrWhiteSpace($resultStr)) { return -1.0 }
        $dur = 0.0
        $parsed = [double]::TryParse(
            $resultStr,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$dur)
        if ($parsed -and $dur -gt 0) { return $dur }
        return -1.0
    } catch {
        return -1.0
    }
}

Export-ModuleMember -Function Format-FileSize, Format-Duration, Test-FfprobeAvailable, Get-MediaDuration
