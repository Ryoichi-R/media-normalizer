#Requires -Modules Pester
Describe 'macOS bundled CLI bootstrap' -Tag 'MacOnly' -Skip:(-not $IsMacOS) {
    BeforeAll {
        $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $pwsh = (Get-Process -Id $PID).Path
    }
    BeforeEach {
        $package = Join-Path $TestDrive ('日本語 package ' + [guid]::NewGuid().ToString('N'))
        $runtime = Join-Path $package 'runtime'
        New-Item -ItemType Directory -Path (Join-Path $runtime 'powershell'), (Join-Path $package 'diagnostics') -Force | Out-Null
        foreach ($name in @('runtime-env.sh','runtime-check.sh','diagnose.sh','media-normalizer.sh')) {
            Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $package
        }
        Copy-Item -LiteralPath (Join-Path $projectRoot 'diagnostics/runtime-check.ps1') -Destination (Join-Path $package 'diagnostics')
        Copy-Item -LiteralPath (Join-Path $projectRoot 'diagnostics/runtime-check-macos.ps1') -Destination (Join-Path $package 'diagnostics')
        $fake = Join-Path $runtime 'powershell/pwsh'
        [IO.File]::WriteAllText($fake, "#!/bin/sh`nprintf 'ARG:%s\n' `"`$@`"`n")
        & /bin/chmod +x $fake
        $manifest = @{
            schemaVersion = 1
            runtime = 'osx-arm64'
            criticalFiles = @(@{ name='PowerShell'; path='powershell/pwsh'; sha256=(Get-FileHash $fake).Hash.ToLowerInvariant() })
        }
        $manifestPath = Join-Path $runtime 'dependency-manifest.json'
        $manifest | ConvertTo-Json -Depth 8 | Set-Content $manifestPath
    }
    It 'keeps platform commands available after loading dependent modules' {
        $scriptPath = Join-Path $TestDrive 'imports.ps1'
        @'
param([string]$ProjectRoot)
$ErrorActionPreference = 'Stop'
$modules = Join-Path $ProjectRoot 'lib'
Import-Module (Join-Path $modules 'MediaNormalizer.Platform.psm1') -Force -DisableNameChecking
foreach ($name in @('Probe','Core','UiLogic','RunRecovery')) {
    Import-Module (Join-Path $modules "MediaNormalizer.$name.psm1") -Force -DisableNameChecking
    if ((Get-MediaNormalizerPlatform) -ne 'macOS') { throw 'Platform command lost.' }
    $null = Get-Command Resolve-MediaNormalizerCommand -ErrorAction Stop
    $null = Get-MediaNormalizerStoragePath -Kind Settings
}
'@ | Set-Content $scriptPath
        & $pwsh -NoProfile -File $scriptPath -ProjectRoot $projectRoot
        $LASTEXITCODE | Should -Be 0
    }
    It 'preserves Unicode, spaces and literal shell syntax in CLI arguments after preflight' {
        $inputFile = '日本語 space/$literal;"quote".wav'
        $output = & /bin/sh (Join-Path $package 'media-normalizer.sh') -InputPath $inputFile -OutputDir 'output space' 2>&1
        $LASTEXITCODE | Should -Be 0
        @($output | Where-Object { $_ -ceq "ARG:$inputFile" }).Count | Should -Be 1
        @($output | Where-Object { $_ -ceq 'ARG:-Quiet' }).Count | Should -Be 1
        @($output | Where-Object { $_ -ceq 'ARG:-Cli' }).Count | Should -Be 1
    }
    It 'stops before launching PowerShell when its hash differs' {
        Add-Content $fake '# modified'
        $output = & /bin/sh (Join-Path $package 'runtime-check.sh') 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match 'SHA-256 mismatch'
        ($output | Out-String) | Should -Not -Match 'ARG:'
    }
    It 'rejects a missing bundled executable without searching PATH' {
        Move-Item $fake ($fake + '.saved')
        $output = & /bin/sh (Join-Path $package 'runtime-check.sh') 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match 'missing or not executable'
    }
    It 'rejects a nonexecutable bundled PowerShell' {
        & /bin/chmod -x $fake
        $output = & /bin/sh (Join-Path $package 'runtime-check.sh') 2>&1
        $LASTEXITCODE | Should -Be 1
    }
    It 'rejects duplicate PowerShell manifest entries' {
        $manifest.criticalFiles += $manifest.criticalFiles[0]
        $manifest | ConvertTo-Json -Depth 8 | Set-Content $manifestPath
        $output = & /bin/sh (Join-Path $package 'runtime-check.sh') 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match 'Duplicate'
    }
    It 'propagates preflight failure and never invokes the CLI' {
        [IO.File]::WriteAllText($fake, "#!/bin/sh`nexit 7`n")
        $manifest.criticalFiles[0].sha256 = (Get-FileHash $fake).Hash.ToLowerInvariant()
        $manifest | ConvertTo-Json -Depth 8 | Set-Content $manifestPath
        & /bin/sh (Join-Path $package 'media-normalizer.sh') -InputPath anything -OutputDir output
        $LASTEXITCODE | Should -Be 7
    }
    It 'rejects an incomplete manifest from the real PowerShell diagnostic' {
        $output = & $pwsh -NoProfile -File (Join-Path $package 'diagnostics/runtime-check.ps1') -RuntimeRoot $runtime 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match 'Incomplete critical file manifest'
    }
    It 'checks hashes before executing any runtime binary' {
        foreach ($entry in @(@('FFmpeg','ffmpeg/bin/ffmpeg'), @('ffprobe','ffmpeg/bin/ffprobe'), @('Python','python/bin/python3'))) {
            $path = Join-Path $runtime $entry[1]
            New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
            [IO.File]::WriteAllText($path, 'must not execute')
            $manifest.criticalFiles += @{ name=$entry[0]; path=$entry[1]; sha256=('0' * 64) }
        }
        $manifest | ConvertTo-Json -Depth 8 | Set-Content $manifestPath
        $output = & $pwsh -NoProfile -File (Join-Path $package 'diagnostics/runtime-check.ps1') -RuntimeRoot $runtime 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match 'SHA-256 mismatch'
        ($output | Out-String) | Should -Not -Match 'ARG:'
    }
}
