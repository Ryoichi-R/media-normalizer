#Requires -Modules Pester

Set-StrictMode -Version Latest

Describe 'macOS arm64 portable dependency pins' {
    BeforeAll {
        $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $script:dependencies = Get-Content -LiteralPath (
            Join-Path $projectRoot 'portable-dependencies.json') -Raw |
            ConvertFrom-Json -AsHashtable
    }

    It 'pins the macOS FFmpeg and ffprobe archives with measured hashes' {
        $runtime = $script:dependencies.ffmpeg.runtimes['osx-arm64']
        $runtime.version | Should -Be '8.1.2'
        $runtime.license | Should -Be 'GPL-3.0-or-later'
        $runtime.url | Should -BeLike 'https://ffmpeg.martin-riedl.de/download/macos/arm64/*/ffmpeg.zip'
        $runtime.ffprobeUrl | Should -BeLike 'https://ffmpeg.martin-riedl.de/download/macos/arm64/*/ffprobe.zip'
        $runtime.sha256 | Should -Match '^[a-f0-9]{64}$'
        $runtime.ffprobeSha256 | Should -Match '^[a-f0-9]{64}$'
    }

    It 'pins the macOS Python archive to a dated immutable release' {
        $runtime = $script:dependencies.python.runtimes['osx-arm64']
        $runtime.version | Should -Be '3.13.15'
        $runtime.releaseTag | Should -Be '20260924'
        $runtime.archiveName | Should -BeLike 'cpython-3.13.15+20260924-aarch64-apple-darwin-install_only.tar.gz'
        $runtime.url | Should -Match '/releases/download/20260924/'
        $runtime.sha256 | Should -Match '^[a-f0-9]{64}$'
    }

    It 'pins the official PowerShell arm64 archive and hash' {
        $runtime = $script:dependencies.powershell.runtimes['osx-arm64']
        $runtime.version | Should -Be '7.6.6'
        $runtime.license | Should -Be 'MIT'
        $runtime.url | Should -Be 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell-7.6.6-osx-arm64.tar.gz'
        $runtime.sha256 | Should -Match '^[a-f0-9]{64}$'
    }
}
