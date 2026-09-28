#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:libRoot = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib')
    Import-Module ([IO.Path]::Combine($script:libRoot, 'MediaNormalizer.Core.psm1')) -Force
}

AfterAll {
    Remove-Module MediaNormalizer.Core -Force -ErrorAction SilentlyContinue
}

Describe 'Find-FfmpegNormalize' {
    Context 'ネイティブ ffmpeg-normalize ランチャが見つかる場合' {
        It '.exe を最優先で返す（拡張子なし引数なし）' {
            Mock -ModuleName MediaNormalizer.Core Get-Command {
                param($Name)
                if ($Name -eq 'ffmpeg-normalize.exe') {
                    return [pscustomobject]@{ Source = 'C:\fake\ffmpeg-normalize.exe' }
                }
                return $null
            }
            $r = Find-FfmpegNormalize -Platform Windows
            $r | Should -Not -BeNullOrEmpty
            $r.Cmd | Should -Be 'C:\fake\ffmpeg-normalize.exe'
            ,$r.Args | Should -BeOfType ([object[]])
            $r.Args.Count | Should -Be 0
        }

        It '.exe が無く .cmd のみある場合は .cmd を返す' {
            Mock -ModuleName MediaNormalizer.Core Get-Command {
                param($Name)
                if ($Name -eq 'ffmpeg-normalize.cmd') {
                    return [pscustomobject]@{ Source = 'C:\fake\ffmpeg-normalize.cmd' }
                }
                return $null
            }
            $r = Find-FfmpegNormalize -Platform Windows
            $r.Cmd | Should -Be 'C:\fake\ffmpeg-normalize.cmd'
            $r.Args.Count | Should -Be 0
        }

        It '.exe/.cmd が無く .bat のみある場合は .bat を返す' {
            Mock -ModuleName MediaNormalizer.Core Get-Command {
                param($Name)
                if ($Name -eq 'ffmpeg-normalize.bat') {
                    return [pscustomobject]@{ Source = 'C:\fake\ffmpeg-normalize.bat' }
                }
                return $null
            }
            $r = Find-FfmpegNormalize -Platform Windows
            $r.Cmd | Should -Be 'C:\fake\ffmpeg-normalize.bat'
            $r.Args.Count | Should -Be 0
        }
    }

    Context 'Python launcher 経由でのフォールバック' {
        BeforeEach {
            Mock -ModuleName MediaNormalizer.Core Test-FfmpegNormalizePython { $true }
        }

        It 'ネイティブが無く py のみあれば py -m ffmpeg_normalize を返す' {
            Mock -ModuleName MediaNormalizer.Core Get-Command {
                param($Name)
                if ($Name -eq 'py') {
                    return [pscustomobject]@{ Source = 'C:\fake\py.exe' }
                }
                return $null
            }
            $r = Find-FfmpegNormalize -Platform Windows
            $r.Cmd | Should -Be 'C:\fake\py.exe'
            $r.Args.Count | Should -Be 2
            $r.Args[0] | Should -Be '-m'
            $r.Args[1] | Should -Be 'ffmpeg_normalize'
        }

        It 'ネイティブ/py が無く python のみあれば python -m ffmpeg_normalize を返す' {
            Mock -ModuleName MediaNormalizer.Core Get-Command {
                param($Name)
                if ($Name -eq 'python') {
                    return [pscustomobject]@{ Source = 'C:\fake\python.exe' }
                }
                return $null
            }
            $r = Find-FfmpegNormalize -Platform Windows
            $r.Cmd | Should -Be 'C:\fake\python.exe'
            $r.Args.Count | Should -Be 2
            $r.Args[0] | Should -Be '-m'
            $r.Args[1] | Should -Be 'ffmpeg_normalize'
        }

        It 'ネイティブと py の両方がある場合はネイティブが優先される' {
            Mock -ModuleName MediaNormalizer.Core Get-Command {
                param($Name)
                if ($Name -eq 'ffmpeg-normalize.exe') {
                    return [pscustomobject]@{ Source = 'C:\fake\ffmpeg-normalize.exe' }
                }
                if ($Name -eq 'py') {
                    return [pscustomobject]@{ Source = 'C:\fake\py.exe' }
                }
                return $null
            }
            $r = Find-FfmpegNormalize -Platform Windows
            $r.Cmd | Should -Be 'C:\fake\ffmpeg-normalize.exe'
            $r.Args.Count | Should -Be 0
        }

        It 'py と python の両方がある場合は py が優先される' {
            Mock -ModuleName MediaNormalizer.Core Get-Command {
                param($Name)
                if ($Name -eq 'py') {
                    return [pscustomobject]@{ Source = 'C:\fake\py.exe' }
                }
                if ($Name -eq 'python') {
                    return [pscustomobject]@{ Source = 'C:\fake\python.exe' }
                }
                return $null
            }
            $r = Find-FfmpegNormalize -Platform Windows
            $r.Cmd | Should -Be 'C:\fake\py.exe'
            $r.Args[1] | Should -Be 'ffmpeg_normalize'
        }

        It 'py が存在しても ffmpeg_normalize を import できなければ採用しない' {
            Mock -ModuleName MediaNormalizer.Core Get-Command {
                param($Name)
                if ($Name -eq 'py') {
                    return [pscustomobject]@{ Source = 'C:\fake\py.exe' }
                }
                return $null
            }
            Mock -ModuleName MediaNormalizer.Core Test-FfmpegNormalizePython { $false }

            Find-FfmpegNormalize -Platform Windows | Should -BeNullOrEmpty
        }
    }

    Context 'ポータブルランタイム' {
        It '内蔵Pythonをシステム上の候補より優先する' {
            $oldRuntimeRoot = $env:MEDIA_NORMALIZER_RUNTIME_ROOT
            $oldPythonPath = $env:MEDIA_NORMALIZER_PYTHON
            $runtimeRoot = Join-Path ([IO.Path]::GetTempPath()) ("mn-bundled-python-" + [guid]::NewGuid().ToString('N'))
            $pythonPath = Join-Path $runtimeRoot 'python/bin/python3'
            try {
                New-Item -ItemType Directory -Path (Split-Path -Parent $pythonPath) -Force | Out-Null
                [IO.File]::WriteAllText($pythonPath, '# bundled python fixture')
                $env:MEDIA_NORMALIZER_RUNTIME_ROOT = $runtimeRoot
                Remove-Item Env:MEDIA_NORMALIZER_PYTHON -ErrorAction SilentlyContinue
                Mock -ModuleName MediaNormalizer.Core Test-FfmpegNormalizePython { $true }
                Mock -ModuleName MediaNormalizer.Core Get-Command {
                    return [pscustomobject]@{ Source = '/system/ffmpeg-normalize' }
                }

                $r = Find-FfmpegNormalize -Platform macOS
                $r.Cmd | Should -Be $pythonPath
                $r.Args | Should -Be @('-m', 'ffmpeg_normalize')
            }
            finally {
                if ($null -eq $oldRuntimeRoot) { Remove-Item Env:MEDIA_NORMALIZER_RUNTIME_ROOT -ErrorAction SilentlyContinue } else { $env:MEDIA_NORMALIZER_RUNTIME_ROOT = $oldRuntimeRoot }
                if ($null -eq $oldPythonPath) { Remove-Item Env:MEDIA_NORMALIZER_PYTHON -ErrorAction SilentlyContinue } else { $env:MEDIA_NORMALIZER_PYTHON = $oldPythonPath }
                Remove-Item -LiteralPath $runtimeRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It '同梱pythonが欠落またはimportできなければPATHへfallbackしない' {
            $oldRuntimeRoot = $env:MEDIA_NORMALIZER_RUNTIME_ROOT
            $oldPythonPath = $env:MEDIA_NORMALIZER_PYTHON
            $runtimeRoot = Join-Path ([IO.Path]::GetTempPath()) ("mn-missing-python-" + [guid]::NewGuid().ToString('N'))
            try {
                $env:MEDIA_NORMALIZER_RUNTIME_ROOT = $runtimeRoot
                Remove-Item Env:MEDIA_NORMALIZER_PYTHON -ErrorAction SilentlyContinue
                Mock -ModuleName MediaNormalizer.Core Get-Command { return [pscustomobject]@{ Source = '/system/ffmpeg-normalize' } }
                { Find-FfmpegNormalize -Platform macOS } | Should -Throw '*PATH上の別実体へfallbackしません*'
            } finally {
                if ($null -eq $oldRuntimeRoot) { Remove-Item Env:MEDIA_NORMALIZER_RUNTIME_ROOT -ErrorAction SilentlyContinue } else { $env:MEDIA_NORMALIZER_RUNTIME_ROOT = $oldRuntimeRoot }
                if ($null -eq $oldPythonPath) { Remove-Item Env:MEDIA_NORMALIZER_PYTHON -ErrorAction SilentlyContinue } else { $env:MEDIA_NORMALIZER_PYTHON = $oldPythonPath }
                Remove-Item -LiteralPath $runtimeRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context '一切見つからない場合' {
        It '$null を返す' {
            Mock -ModuleName MediaNormalizer.Core Get-Command { return $null }
            $r = Find-FfmpegNormalize -Platform Windows
            $r | Should -BeNullOrEmpty
        }
    }

    Context 'POSIX launcher' {
        It '拡張子なし ffmpeg-normalize entry pointを探索する' {
            Mock -ModuleName MediaNormalizer.Core Get-Command {
                param($Name)
                if ($Name -eq 'ffmpeg-normalize') {
                    return [pscustomobject]@{ Source = '/portable/bin/ffmpeg-normalize' }
                }
                return $null
            }
            $r = Find-FfmpegNormalize -Platform macOS
            $r.Cmd | Should -Be '/portable/bin/ffmpeg-normalize'
            $r.Args.Count | Should -Be 0
        }
    }

}
