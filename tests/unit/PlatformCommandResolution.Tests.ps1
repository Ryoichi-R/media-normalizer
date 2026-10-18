#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.Platform.psm1') -Force -DisableNameChecking
}

Describe 'Media Normalizer runtime command resolution' {
    It 'prioritizes an explicit tool path over the bundled runtime root' {
        $oldToolPath = [Environment]::GetEnvironmentVariable('FFMPEG_PATH')
        $oldRuntimeRoot = [Environment]::GetEnvironmentVariable('MEDIA_NORMALIZER_RUNTIME_ROOT')
        $root = Join-Path ([IO.Path]::GetTempPath()) ("mn-empty-runtime-" + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $sentinel = '/bin/echo'
            $env:MEDIA_NORMALIZER_RUNTIME_ROOT = $root
            $env:FFMPEG_PATH = $sentinel
            Resolve-MediaNormalizerCommand -Name FFmpeg | Should -Be ([IO.Path]::GetFullPath($sentinel))
        } finally {
            if ($null -eq $oldToolPath) { Remove-Item Env:FFMPEG_PATH -ErrorAction SilentlyContinue } else { $env:FFMPEG_PATH = $oldToolPath }
            if ($null -eq $oldRuntimeRoot) { Remove-Item Env:MEDIA_NORMALIZER_RUNTIME_ROOT -ErrorAction SilentlyContinue } else { $env:MEDIA_NORMALIZER_RUNTIME_ROOT = $oldRuntimeRoot }
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects a missing explicit override instead of falling back to PATH' {
        $oldToolPath = [Environment]::GetEnvironmentVariable('FFPROBE_PATH')
        try {
            $env:FFPROBE_PATH = Join-Path ([IO.Path]::GetTempPath()) ("missing-ffprobe-" + [guid]::NewGuid().ToString('N'))
            { Resolve-MediaNormalizerCommand -Name FFprobe } | Should -Throw '*FFPROBE_PATH*'
        } finally {
            if ($null -eq $oldToolPath) { Remove-Item Env:FFPROBE_PATH -ErrorAction SilentlyContinue } else { $env:FFPROBE_PATH = $oldToolPath }
        }
    }

    It 'does not fall back to a PATH executable when bundled mode lacks the pinned tool' {
        $oldToolPath = [Environment]::GetEnvironmentVariable('FFMPEG_PATH')
        $oldRuntimeRoot = [Environment]::GetEnvironmentVariable('MEDIA_NORMALIZER_RUNTIME_ROOT')
        $oldPath = $env:PATH
        $root = Join-Path ([IO.Path]::GetTempPath()) ("mn-empty-runtime-" + [guid]::NewGuid().ToString('N'))
        $pathRoot = Join-Path ([IO.Path]::GetTempPath()) ("mn-fake-path-" + [guid]::NewGuid().ToString('N'))
        try {
            if ((Get-MediaNormalizerPlatform) -eq 'Windows') { Set-ItResult -Skipped -Because 'PATH fixture uses a POSIX executable name' }
            New-Item -ItemType Directory -Path $root,$pathRoot -Force | Out-Null
            $fake = Join-Path $pathRoot 'ffmpeg'
            [IO.File]::WriteAllText($fake, "#!/bin/sh`nexit 0`n")
            [IO.File]::SetUnixFileMode($fake, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
            $env:PATH = "$pathRoot$([IO.Path]::PathSeparator)$oldPath"
            Remove-Item Env:FFMPEG_PATH -ErrorAction SilentlyContinue
            $env:MEDIA_NORMALIZER_RUNTIME_ROOT = $root
            { Resolve-MediaNormalizerCommand -Name FFmpeg } | Should -Throw '*PATH上の別実体へfallbackしません*'
        } finally {
            if ($null -eq $oldToolPath) { Remove-Item Env:FFMPEG_PATH -ErrorAction SilentlyContinue } else { $env:FFMPEG_PATH = $oldToolPath }
            if ($null -eq $oldRuntimeRoot) { Remove-Item Env:MEDIA_NORMALIZER_RUNTIME_ROOT -ErrorAction SilentlyContinue } else { $env:MEDIA_NORMALIZER_RUNTIME_ROOT = $oldRuntimeRoot }
            $env:PATH = $oldPath
            Remove-Item -LiteralPath $root,$pathRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
