#Requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\installer\MediaNormalizer.Installer.Common.ps1')
}

Describe 'Media Normalizer installer managed path safety' -Tag 'WindowsOnly' {
    BeforeEach {
        $script:testRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'mn-installer-path-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '旧マーカーの親ディレクトリ脱出を拒否する' {
        { Resolve-SafeChildPath -Root $script:testRoot -RelativePath '..\victim.txt' } |
            Should -Throw '*危険な相対パス*'
    }

    It '重複したmanagedFilesを拒否する' {
        $files = @(
            [pscustomobject]@{ name = 'lib/core.psm1' },
            [pscustomobject]@{ name = 'LIB\CORE.PSM1' })
        { ConvertTo-ValidatedManagedFileMap -ManagedFiles $files -Root $script:testRoot } |
            Should -Throw '*重複パス*'
    }

    It '安全な相対パスをルート配下へ解決する' {
        $resolved = Resolve-SafeChildPath -Root $script:testRoot -RelativePath 'lib/core.psm1'
        $resolved | Should -Be (Join-Path $script:testRoot 'lib\core.psm1')
    }
}
