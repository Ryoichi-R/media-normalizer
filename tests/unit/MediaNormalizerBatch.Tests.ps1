#Requires -Modules Pester

Set-StrictMode -Version Latest

Describe 'media-normalizer.bat launcher contract' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
    BeforeAll {
        $script:template = [IO.Path]::Combine(
            $PSScriptRoot, '..', '..', 'scripts', 'package-templates', 'media-normalizer.bat')
    }

    It 'keeps console code page unchanged and quotes the launcher path' {
        $content = Get-Content -LiteralPath $script:template -Raw
        $content | Should -Not -Match '(?im)^\s*chcp\b'
        $content | Should -Match '"%~dp0MediaNormalizer\.exe" %\*'
    }

    It 'launches successfully from a Unicode path without changing code page' {
        $testRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'mn-bat-日本語 経路-' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $testRoot -ItemType Directory | Out-Null
        try {
            $batch = Join-Path $testRoot 'media-normalizer.bat'
            Copy-Item -LiteralPath $script:template -Destination $batch
            Copy-Item -LiteralPath $env:ComSpec -Destination (Join-Path $testRoot 'MediaNormalizer.exe')

            & $env:ComSpec /d /c "`"$batch`" /d /c exit /b 0"
            $LASTEXITCODE | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
