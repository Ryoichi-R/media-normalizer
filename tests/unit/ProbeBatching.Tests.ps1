#Requires -Modules Pester

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\lib\MediaNormalizer.Ui.psm1') -Force
}

AfterAll {
    Remove-Module MediaNormalizer.Ui -Force -ErrorAction SilentlyContinue
}

Describe 'Split-ProbePathBatch' {
    It '100件を25件ずつ4ジョブへ分割する' {
        $paths = 1..100 | ForEach-Object { "C:\media\$_.mp4" }
        $batches = @(InModuleScope MediaNormalizer.Ui -Parameters @{ p = $paths } {
                param($p)
                Split-ProbePathBatch -FilePath $p -BatchSize 25
            })

        $batches.Count | Should -Be 4
        @($batches | ForEach-Object Count) | Should -Be @(25, 25, 25, 25)
        @($batches | ForEach-Object { $_ }) | Should -Be $paths
    }

    It '端数を最後のバッチへ保持する' {
        $paths = 1..52 | ForEach-Object { "C:\media\$_.mp4" }
        $batches = @(InModuleScope MediaNormalizer.Ui -Parameters @{ p = $paths } {
                param($p)
                Split-ProbePathBatch -FilePath $p -BatchSize 25
            })

        @($batches | ForEach-Object Count) | Should -Be @(25, 25, 2)
    }
}
