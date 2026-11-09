#Requires -Modules Pester

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\lib\MediaNormalizer.Core.psm1') -Force
}

Describe 'Resolve-UniqueOutputPath' {
    BeforeEach {
        $script:tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mn-resolve-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
        $script:state = MediaNormalizer.Core\New-MediaNormalizerState
        $script:logs = New-Object System.Collections.Generic.List[string]
    }

    AfterEach {
        Remove-Item -LiteralPath $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'preserves the reserved output when overwrite is selected for a later input' {
        $options = @{ State = $script:state; Directory = $script:tmpDir; BaseName = 'a'; Extension = '.mp3'; Policy = 'overwrite' }
        (Resolve-UniqueOutputPath @options) | Should -Be (Join-Path $script:tmpDir 'a.mp3')
        (Resolve-UniqueOutputPath @options) | Should -Be (Join-Path $script:tmpDir 'a (2).mp3')
    }

    It 'refuses to replace a protected input and supports skip and rename' {
        $protected = Join-Path $script:tmpDir 'a.mp3'
        $options = @{ State = $script:state; Directory = $script:tmpDir; BaseName = 'a'; Extension = '.mp3' }
        $options.IsProtectedInput = { param($path) $path -ceq $protected }.GetNewClosure()
        { Resolve-UniqueOutputPath @options -Policy overwrite } | Should -Throw '*入力原本*'
        (Resolve-UniqueOutputPath @options -Policy skip) | Should -BeNullOrEmpty
        (Resolve-UniqueOutputPath @options -Policy rename) | Should -Be (Join-Path $script:tmpDir 'a (2).mp3')
    }

    It '衝突なしで元名を返す' {
        $out = MediaNormalizer.Core\Resolve-UniqueOutputPath -State $script:state -Directory $script:tmpDir -BaseName 'a' -Extension '.mp3'
        $out | Should -Be (Join-Path $script:tmpDir 'a.mp3')
    }

    It '既存ファイル衝突時に (2) を返す' {
        New-Item -ItemType File -Path (Join-Path $script:tmpDir 'a.mp3') | Out-Null
        $out = MediaNormalizer.Core\Resolve-UniqueOutputPath -State $script:state -Directory $script:tmpDir -BaseName 'a' -Extension '.mp3'
        $out | Should -Be (Join-Path $script:tmpDir 'a (2).mp3')
    }

    It '同一セッション予約衝突を回避する' {
        $first = MediaNormalizer.Core\Resolve-UniqueOutputPath -State $script:state -Directory $script:tmpDir -BaseName 'a' -Extension '.mp3'
        $second = MediaNormalizer.Core\Resolve-UniqueOutputPath -State $script:state -Directory $script:tmpDir -BaseName 'a' -Extension '.mp3'
        $first | Should -Be (Join-Path $script:tmpDir 'a.mp3')
        $second | Should -Be (Join-Path $script:tmpDir 'a (2).mp3')
    }

    It '上限到達時はtimestamp fallbackを返す' {
        New-Item -ItemType File -Path (Join-Path $script:tmpDir 'a.mp3') | Out-Null
        New-Item -ItemType File -Path (Join-Path $script:tmpDir 'a (2).mp3') | Out-Null
        $out = MediaNormalizer.Core\Resolve-UniqueOutputPath -State $script:state -Directory $script:tmpDir -BaseName 'a' -Extension '.mp3' -MaxAttempts 2 -Logger { param($m) $script:logs.Add($m) | Out-Null }
        $pattern = ([regex]::Escape((Join-Path $script:tmpDir 'a ('))) + '\d{17}\)\.mp3$'
        $out | Should -Match $pattern
        ($script:logs -join "`n") | Should -Match 'max attempts reached'
    }
}
