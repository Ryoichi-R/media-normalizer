#Requires -Modules Pester

Describe 'Media Normalizer launcher safety contract' {
    BeforeAll {
        $script:projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    }

    It '全例外表示・System32 fallback・mutex解放を保持する' {
        $source = Get-Content -LiteralPath (
            Join-Path $script:projectRoot 'src\MediaNormalizer.Launcher\Program.cs') -Raw

        $source | Should -Match 'catch \(Exception ex\)'
        $source | Should -Match 'Environment\.SystemDirectory'
        $source | Should -Match 'ReleaseMutex\(\)'
    }

    It 'FormClosingは直接killせずキャンセル要求へ統一する' {
        $source = Get-Content -LiteralPath (
            Join-Path $script:projectRoot 'lib\MediaNormalizer.Ui.psm1') -Raw
        $formClosing = [regex]::Match(
            $source,
            '(?s)# === FormClosing:.*?# === Apply persisted settings ===').Value

        $formClosing | Should -Match '\$eventArgs\.Cancel = \$true'
        $formClosing | Should -Match '\$stateRef\.CancelRequested = \$true'
        $formClosing | Should -Not -Match '\.Kill\('
    }
}
