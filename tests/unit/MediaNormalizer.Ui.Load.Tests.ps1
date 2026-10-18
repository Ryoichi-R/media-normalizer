#Requires -Modules Pester

Set-StrictMode -Version Latest

# MediaNormalizer.Ui.psm1 が Linux/Windows どちらでも例外無くロードできることを
# 保証する回帰テスト。Linux runner で WinForms / System.Drawing を Add-Type
# しないこと（=トップレベル副作用が無いこと）を担保する。
Describe 'MediaNormalizer.Ui module load' {
    BeforeAll {
        $script:libRoot = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib')
    }

    It 'Core / Probe / Ui を Import-Module してもロードが throw しない' {
        $coreModule  = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Core.psm1')
        $probeModule = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Probe.psm1')
        $uiModule    = [IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Ui.psm1')
        {
            Import-Module $coreModule  -Force -ErrorAction Stop
            Import-Module $probeModule -Force -ErrorAction Stop
            Import-Module $uiModule    -Force -ErrorAction Stop
        } | Should -Not -Throw
    }

    It 'Initialize-UiAssemblies は Linux で明確な例外メッセージで失敗する' -Skip:$IsWindows {
        InModuleScope MediaNormalizer.Ui {
            { Initialize-UiAssemblies } | Should -Throw -ExpectedMessage '*Windows でのみ利用可能*'
        }
    }
}
