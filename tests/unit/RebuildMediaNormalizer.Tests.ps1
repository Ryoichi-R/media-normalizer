#Requires -Modules Pester

Describe 'Media Normalizer build contract' {
    BeforeAll {
        $script:projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\'))
        $script:contractScript = Join-Path $script:projectRoot 'scripts\test-build-contract.ps1'
        $script:runtimeEnvironment = Join-Path $script:projectRoot 'launcher-legacy\runtime-env.bat'
    }

    It 'runtime-specific portable build paths and safety guards pass their contract' {
        $output = & pwsh -NoLogo -NoProfile -File $script:contractScript 2>&1
        $exitCode = $LASTEXITCODE

        $output | Out-String | Should -Match 'build contract checks passed'
        $exitCode | Should -Be 0
    }

    It 'fails closed when a portable package loses its runtime manifest' {
        $packageRoot = Join-Path $TestDrive 'missing-runtime-package'
        New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
        $batchPath = Join-Path $packageRoot 'runtime-env.bat'
        Copy-Item -LiteralPath $script:runtimeEnvironment -Destination $batchPath
        [IO.File]::WriteAllText(
            (Join-Path $packageRoot 'portable-package.marker'),
            "media-normalizer-portable`r`n",
            [Text.UTF8Encoding]::new($false))

        $output = & $env:ComSpec /d /c "call `"$batchPath`"" 2>&1

        $LASTEXITCODE | Should -Be 1
        $output | Out-String | Should -Match 'Bundled runtime manifest was not found'
    }
}
