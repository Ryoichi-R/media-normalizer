#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:modulePath = [IO.Path]::Combine(
        $PSScriptRoot, '..', '..', 'lib', 'MediaNormalizer.Ui.psm1')
    Import-Module $script:modulePath -Force
}

AfterAll {
    Remove-Module MediaNormalizer.Ui -Force -ErrorAction SilentlyContinue
}

Describe 'MediaNormalizer.Ui public surface' {
    It 'exports only the four GUI entrypoint functions' {
        $actual = @(
            Get-Command -Module MediaNormalizer.Ui -CommandType Function |
                Select-Object -ExpandProperty Name |
                Sort-Object)
        $actual | Should -Be @(
            'Initialize-UiState',
            'New-MainForm',
            'Set-ConsoleWindowHidden',
            'Show-MainForm')
    }
}
