#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

    function Get-FunctionAst {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Name
        )

        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $Path,
            [ref]$tokens,
            [ref]$errors)
        $errors.Count | Should -Be 0
        return $ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
            }, $true) | Select-Object -First 1
    }
}

Describe 'MN-8 maintainability seams' {
    It 'Invoke-Normalize delegates discovery and per-file context construction' {
        $path = Join-Path $script:projectRoot 'lib\MediaNormalizer.Core.psm1'
        foreach ($name in @(
                'Get-NormalizationRunFiles',
                'New-NormalizationReportRecord',
                'Get-NormalizationCurrentSpeedPercent',
                'Get-NormalizationCurrentDuration')) {
            Get-FunctionAst -Path $path -Name $name | Should -Not -BeNullOrEmpty
        }

        $orchestrator = Get-FunctionAst -Path $path -Name 'Invoke-Normalize'
        ($orchestrator.Extent.EndLineNumber - $orchestrator.Extent.StartLineNumber + 1) |
            Should -BeLessOrEqual 500
    }

    It 'New-MainForm delegates event wiring to a private helper' {
        $path = Join-Path $script:projectRoot 'lib\MediaNormalizer.Ui.psm1'
        $eventWiring = Get-FunctionAst -Path $path -Name 'Register-MainFormEventHandlers'
        $eventWiring | Should -Not -BeNullOrEmpty
        $eventWiring.Extent.Text | Should -Match 'Add_Click'
        $eventWiring.Extent.Text | Should -Match 'Add_FormClosing'

        $formBuilder = Get-FunctionAst -Path $path -Name 'New-MainForm'
        ($formBuilder.Extent.EndLineNumber - $formBuilder.Extent.StartLineNumber + 1) |
            Should -BeLessOrEqual 700
    }

    It 'new seams remain private and do not expand either module public surface' {
        Import-Module (Join-Path $script:projectRoot 'lib\MediaNormalizer.Core.psm1') -Force
        Import-Module (Join-Path $script:projectRoot 'lib\MediaNormalizer.Ui.psm1') -Force

        Get-Command -Module MediaNormalizer.Core -CommandType Function |
            Select-Object -ExpandProperty Name |
            Should -Not -Contain 'Get-NormalizationRunFiles'
        Get-Command -Module MediaNormalizer.Ui -CommandType Function |
            Select-Object -ExpandProperty Name |
            Should -Not -Contain 'Register-MainFormEventHandlers'
    }
}
