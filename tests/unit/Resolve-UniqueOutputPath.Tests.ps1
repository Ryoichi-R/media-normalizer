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

Describe 'Input identity through filesystem aliases' {
    It 'protects a path through a Windows junction in PowerShell 5.1 and 7' -Tag WindowsOnly -Skip:(
        $PSVersionTable.PSEdition -ne 'Desktop' -and -not (Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue)
    ) {
        $originalDirectory = (New-Item -ItemType Directory (Join-Path $TestDrive 'original')).FullName
        $original = Join-Path $originalDirectory 'Original name.wav'
        [IO.File]::WriteAllText($original, 'original')
        $junction = (New-Item -ItemType Junction -Path (Join-Path $TestDrive 'junction') -Target $originalDirectory).FullName
        $check = New-MediaNormalizerInputProtection -Paths $original
        (& $check (Join-Path $junction 'Original name.wav')) | Should -BeTrue
        (& $check (Join-Path $originalDirectory 'ORIGINAL NAME.WAV')) | Should -BeTrue
    }

    It 'protects a path through a Unix directory link and refreshes file identity' -Skip:(
        $PSVersionTable.PSEdition -eq 'Desktop' -or (Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue)
    ) {
        $directory = (New-Item -ItemType Directory (Join-Path $TestDrive 'original')).FullName
        $original = Join-Path $directory 'tone.wav'
        [IO.File]::WriteAllText($original, 'original')
        $alias = (New-Item -ItemType SymbolicLink -Path (Join-Path $TestDrive 'alias') -Target $directory).FullName
        $destination = Join-Path $TestDrive 'out.wav'
        [IO.File]::WriteAllText($destination, 'output')
        $check = New-MediaNormalizerInputProtection -Paths $original
        (& $check (Join-Path $alias 'tone.wav')) | Should -BeTrue
        (& $check $destination) | Should -BeFalse
        Remove-Item -LiteralPath $destination
        $null = New-Item -ItemType SymbolicLink -Path $destination -Target $original
        (& $check $destination) | Should -BeTrue
    }
}
