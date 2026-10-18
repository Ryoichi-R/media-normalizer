#Requires -Modules Pester
Describe 'macOS runtime archive helpers' -Tag 'MacOnly' -Skip:(-not $IsMacOS) {
    BeforeAll {
        $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'scripts/prepare-macos-runtime.ps1'),[ref]$tokens,[ref]$errors)
        $errors.Count | Should -Be 0
        foreach ($name in @('Test-MacMachO','Expand-MacPinnedTar')) {
            $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
            . ([scriptblock]::Create($node.Extent.Text))
        }
    }
    It 'recognizes the real arm64 PowerShell Mach-O executable' {
        Test-MacMachO (Get-Process -Id $PID).Path | Should -BeTrue
    }
    It 'excludes ordinary text from code signing' {
        $path=Join-Path $TestDrive 'notice.txt'
        Set-Content $path 'license notice'
        Test-MacMachO $path | Should -BeFalse
    }
    It 'extracts a pinned-style tar with internal symbolic links intact' {
        $source=Join-Path $TestDrive 'source'
        New-Item -ItemType Directory $source | Out-Null
        Set-Content (Join-Path $source 'python3.13') 'fixture'
        & /bin/ln -s python3.13 (Join-Path $source 'python3')
        $archive=Join-Path $TestDrive 'python.tar.gz'
        & /usr/bin/tar -czf $archive -C $source .
        $LASTEXITCODE | Should -Be 0
        $destination=Join-Path $TestDrive 'output'
        Expand-MacPinnedTar $archive $destination
        (Get-Item (Join-Path $destination 'python3')).LinkType | Should -Be SymbolicLink
        Get-Content (Join-Path $destination 'python3') | Should -Be fixture
    }
}
