Set-StrictMode -Version Latest

# 小数点記号がカルチャ依存（例: de-DE では ',' )の環境で [double] キャストが
# 失敗するのを避けるための InvariantCulture パースヘルパー。
function ConvertTo-InvariantDouble {
    param([string]$Value, [double]$Default = 0.0)
    $result = 0.0
    if ([double]::TryParse(
            $Value,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$result)) {
        return $result
    }
    return $Default
}

function Get-FfmpegProgress {
    param(
        [string]$StderrPath,
        [string]$StdoutPath,
        [double]$CurrentFileDurationSec = -1.0,
        [double]$SpeedFactor = 1.0
    )

    function Read-LogTail {
        param(
            [string]$Path,
            [int]$MaxBytes = 8192
        )
        if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
        try {
            $fs = [System.IO.FileStream]::new(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
            try {
                $seekPos = [math]::Max(0, $fs.Length - $MaxBytes)
                $fs.Seek($seekPos, [System.IO.SeekOrigin]::Begin) | Out-Null
                $bufSize = [int][math]::Min($MaxBytes, $fs.Length - $seekPos)
                if ($bufSize -le 0) { return '' }
                $buf = New-Object byte[] $bufSize
                $bytesRead = $fs.Read($buf, 0, $bufSize)
                if ($bytesRead -le 0) { return '' }
                return [System.Text.Encoding]::UTF8.GetString($buf, 0, $bytesRead)
            } finally {
                $fs.Close()
            }
        } catch {
            return ''
        }
    }

    $stderrTail = Read-LogTail -Path $StderrPath
    $stdoutTail = Read-LogTail -Path $StdoutPath
    $chunk = "$stderrTail`n$stdoutTail"
    if ([string]::IsNullOrWhiteSpace($chunk)) { return -1.0 }

    $ansiPattern = [string]([char]27) + '\[[0-9;?]*[ -/]*[@-~]'
    $clean = [regex]::Replace($chunk, $ansiPattern, '')

    $bestSec = -1.0
    foreach ($pat in @(
            'time=(\d{2}):(\d{2}):(\d{2})(?:[.,](\d+))?',
            'out_time=(\d{2}):(\d{2}):(\d{2})(?:[.,](\d+))?'
        )) {
        $rxMatches = [regex]::Matches($clean, $pat)
        if ($rxMatches.Count -gt 0) {
            $last = $rxMatches[$rxMatches.Count - 1]
            $frac = 0.0
            if ($last.Groups[4].Success -and $last.Groups[4].Value.Length -gt 0) {
                $frac = ConvertTo-InvariantDouble -Value "0.$($last.Groups[4].Value)"
            }
            $sec = [int]$last.Groups[1].Value * 3600 +
                   [int]$last.Groups[2].Value * 60 +
                   [int]$last.Groups[3].Value + $frac
            if ($sec -gt $bestSec) { $bestSec = $sec }
        }
    }
    $outUsMatches = [regex]::Matches($clean, 'out_time_us=(\d+)')
    if ($outUsMatches.Count -gt 0) {
        $us = ConvertTo-InvariantDouble -Value $outUsMatches[$outUsMatches.Count - 1].Groups[1].Value
        $secFromUs = $us / 1000000.0
        if ($secFromUs -gt $bestSec) { $bestSec = $secFromUs }
    }
    if ($bestSec -ge 0) {
        if ($SpeedFactor -le 0) { $SpeedFactor = 1.0 }
        $sec = [math]::Max(0.0, $bestSec * $SpeedFactor)
        if ($CurrentFileDurationSec -gt 0) {
            return [math]::Min($CurrentFileDurationSec, $sec)
        }
        return $sec
    }

    if ($CurrentFileDurationSec -gt 0) {
        $secondPassMatches = [regex]::Matches($clean, 'Second Pass:\s*([0-9]+(?:\.[0-9]+)?)%')
        if ($secondPassMatches.Count -gt 0) {
            $pct = ConvertTo-InvariantDouble -Value $secondPassMatches[$secondPassMatches.Count - 1].Groups[1].Value
            $ratio = 0.5 + ($pct / 200.0)
            $sec = $CurrentFileDurationSec * $ratio
            return [math]::Max(0.0, [math]::Min($CurrentFileDurationSec, $sec))
        }

        $streamMatches = [regex]::Matches($clean, 'Stream\s+\d+/\d+:\s*([0-9]+(?:\.[0-9]+)?)%')
        if ($streamMatches.Count -gt 0) {
            $pct = ConvertTo-InvariantDouble -Value $streamMatches[$streamMatches.Count - 1].Groups[1].Value
            $ratio = $pct / 200.0
            $sec = $CurrentFileDurationSec * $ratio
            return [math]::Max(0.0, [math]::Min($CurrentFileDurationSec, $sec))
        }
        # Per-file task counters stay at 0 while inner passes run; prefer the pass progress.
        $fileMatches = [regex]::Matches($clean, 'File:\s*([0-9]+(?:\.[0-9]+)?)%')
        if ($fileMatches.Count -gt 0) {
            $pct = ConvertTo-InvariantDouble -Value $fileMatches[$fileMatches.Count - 1].Groups[1].Value
            $sec = $CurrentFileDurationSec * $pct / 100.0
            return [math]::Max(0.0, [math]::Min($CurrentFileDurationSec, $sec))
        }
    }

    return -1.0
}

Export-ModuleMember -Function Get-FfmpegProgress
