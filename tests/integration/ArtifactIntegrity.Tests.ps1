#Requires -Modules Pester

Describe 'Media Normalizer canonical artifact integrity' -Tag 'Integration' {
    BeforeAll {
        $script:projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $script:auditScript = Join-Path $script:projectRoot 'scripts\test-artifact-integrity.ps1'
    }

    It 'x64とARM64の既存成果物実体を検証できる' {
        { & $script:auditScript } | Should -Not -Throw
    }
}
