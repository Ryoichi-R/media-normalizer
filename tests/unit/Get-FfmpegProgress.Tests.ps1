#Requires -Modules Pester

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\lib\MediaNormalizer.Progress.psm1') -Force
}

Describe 'Get-FfmpegProgress' {
    It '不正なログ入力とInvariant変換の既定値を処理する' {
        InModuleScope MediaNormalizer.Progress {
            ConvertTo-InvariantDouble -Value 'not-a-number' -Default 7.0 | Should -Be 7.0
        }
        $directory = [IO.Path]::GetTempPath()
        MediaNormalizer.Progress\Get-FfmpegProgress -StderrPath $directory -StdoutPath $directory -CurrentFileDurationSec 10 |
            Should -Be -1
    }

    It 'time= 形式を解釈できる' {
        $stderr = [System.IO.Path]::GetTempFileName()
        $stdout = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $stderr -Value "frame=1 time=00:00:05.50 bitrate=1000k" -Encoding UTF8
        Set-Content -LiteralPath $stdout -Value '' -Encoding UTF8
        try {
            $sec = MediaNormalizer.Progress\Get-FfmpegProgress -StderrPath $stderr -StdoutPath $stdout -CurrentFileDurationSec 10
            [math]::Abs($sec - 5.5) | Should -BeLessThan 0.01
        } finally {
            Remove-Item -LiteralPath $stderr, $stdout -Force -ErrorAction SilentlyContinue
        }
    }

    It 'out_time_us= 形式を解釈できる' {
        $stderr = [System.IO.Path]::GetTempFileName()
        $stdout = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $stderr -Value "out_time_us=1230000" -Encoding UTF8
        Set-Content -LiteralPath $stdout -Value '' -Encoding UTF8
        try {
            $sec = MediaNormalizer.Progress\Get-FfmpegProgress -StderrPath $stderr -StdoutPath $stdout -CurrentFileDurationSec 10
            [math]::Abs($sec - 1.23) | Should -BeLessThan 0.01
        } finally {
            Remove-Item -LiteralPath $stderr, $stdout -Force -ErrorAction SilentlyContinue
        }
    }

    It 'time= 由来の秒を SpeedFactor で元動画長タイムラインへ補正する' {
        $stderr = [System.IO.Path]::GetTempFileName()
        $stdout = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $stderr -Value "frame=1 time=00:00:05.00 bitrate=1000k" -Encoding UTF8
        Set-Content -LiteralPath $stdout -Value '' -Encoding UTF8
        try {
            $sec = MediaNormalizer.Progress\Get-FfmpegProgress -StderrPath $stderr -StdoutPath $stdout -CurrentFileDurationSec 10 -SpeedFactor 1.5
            [math]::Abs($sec - 7.5) | Should -BeLessThan 0.01
        } finally {
            Remove-Item -LiteralPath $stderr, $stdout -Force -ErrorAction SilentlyContinue
        }
    }

    It 'SpeedFactor 補正後の秒を元動画長でクランプする' {
        $stderr = [System.IO.Path]::GetTempFileName()
        $stdout = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $stderr -Value "frame=1 time=00:00:09.00 bitrate=1000k" -Encoding UTF8
        Set-Content -LiteralPath $stdout -Value '' -Encoding UTF8
        try {
            $sec = MediaNormalizer.Progress\Get-FfmpegProgress -StderrPath $stderr -StdoutPath $stdout -CurrentFileDurationSec 10 -SpeedFactor 1.5
            $sec | Should -Be 10
        } finally {
            Remove-Item -LiteralPath $stderr, $stdout -Force -ErrorAction SilentlyContinue
        }
    }

    It 'File: 50% を解釈できる' {
        $stderr = [System.IO.Path]::GetTempFileName()
        $stdout = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $stderr -Value "File: 50%" -Encoding UTF8
        Set-Content -LiteralPath $stdout -Value '' -Encoding UTF8
        try {
            $sec = MediaNormalizer.Progress\Get-FfmpegProgress -StderrPath $stderr -StdoutPath $stdout -CurrentFileDurationSec 10
            [math]::Abs($sec - 5.0) | Should -BeLessThan 0.01
        } finally {
            Remove-Item -LiteralPath $stderr, $stdout -Force -ErrorAction SilentlyContinue
        }
    }

    It '百分率ログには SpeedFactor を掛けない' {
        $stderr = [System.IO.Path]::GetTempFileName()
        $stdout = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $stderr -Value "File: 50%" -Encoding UTF8
        Set-Content -LiteralPath $stdout -Value '' -Encoding UTF8
        try {
            $sec = MediaNormalizer.Progress\Get-FfmpegProgress -StderrPath $stderr -StdoutPath $stdout -CurrentFileDurationSec 10 -SpeedFactor 1.5
            [math]::Abs($sec - 5.0) | Should -BeLessThan 0.01
        } finally {
            Remove-Item -LiteralPath $stderr, $stdout -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Second Pass: 80% を解釈できる' {
        $stderr = [System.IO.Path]::GetTempFileName()
        $stdout = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $stderr -Value "Second Pass: 80%" -Encoding UTF8
        Set-Content -LiteralPath $stdout -Value '' -Encoding UTF8
        try {
            $sec = MediaNormalizer.Progress\Get-FfmpegProgress -StderrPath $stderr -StdoutPath $stdout -CurrentFileDurationSec 10
            [math]::Abs($sec - 9.0) | Should -BeLessThan 0.01
        } finally {
            Remove-Item -LiteralPath $stderr, $stdout -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Stream N/N: X% を解釈できる' {
        $stderr = [System.IO.Path]::GetTempFileName()
        $stdout = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $stderr -Value "Stream 1/1: 60%" -Encoding UTF8
        Set-Content -LiteralPath $stdout -Value '' -Encoding UTF8
        try {
            $sec = MediaNormalizer.Progress\Get-FfmpegProgress -StderrPath $stderr -StdoutPath $stdout -CurrentFileDurationSec 10
            [math]::Abs($sec - 3.0) | Should -BeLessThan 0.01
        } finally {
            Remove-Item -LiteralPath $stderr, $stdout -Force -ErrorAction SilentlyContinue
        }
    }
}
