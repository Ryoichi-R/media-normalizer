#Requires -Modules Pester

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\lib\MediaNormalizer.Probe.psm1') -Force
}

Describe 'Format-FileSize' {
    It 'B境界を返す' {
        MediaNormalizer.Probe\Format-FileSize -Bytes 1023 | Should -Be '1023 B'
    }

    It 'KB境界を返す' {
        (MediaNormalizer.Probe\Format-FileSize -Bytes 1024) | Should -Match '^1[.,]0 KB$'
    }

    It 'MB境界を返す' {
        (MediaNormalizer.Probe\Format-FileSize -Bytes 1048576) | Should -Match '^1[.,]0 MB$'
    }

    It 'GB境界を返す' {
        (MediaNormalizer.Probe\Format-FileSize -Bytes 1073741824) | Should -Match '^1[.,]0 GB$'
    }
}
