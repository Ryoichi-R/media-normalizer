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
            $r = Find-FfmpegNormalize
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
            $r = Find-FfmpegNormalize
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
            $r = Find-FfmpegNormalize
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
            $r = Find-FfmpegNormalize
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
            $r = Find-FfmpegNormalize
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
            $r = Find-FfmpegNormalize
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
            $r = Find-FfmpegNormalize
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

            Find-FfmpegNormalize | Should -BeNullOrEmpty
        }
    }

    Context 'ポータブルランタイム' {
        It '内蔵Pythonをシステム上の候補より優先する' {
            $oldRuntimeRoot = $env:MEDIA_NORMALIZER_RUNTIME_ROOT
            try {
                $env:MEDIA_NORMALIZER_RUNTIME_ROOT = 'C:\portable\runtime'
                Mock -ModuleName MediaNormalizer.Core Test-Path { $true }
                Mock -ModuleName MediaNormalizer.Core Test-FfmpegNormalizePython { $true }
                Mock -ModuleName MediaNormalizer.Core Get-Command {
                    return [pscustomobject]@{ Source = 'C:\system\ffmpeg-normalize.exe' }
                }

                $r = Find-FfmpegNormalize
                $r.Cmd | Should -Be 'C:\portable\runtime\python\python.exe'
                $r.Args | Should -Be @('-m', 'ffmpeg_normalize')
            }
            finally {
                $env:MEDIA_NORMALIZER_RUNTIME_ROOT = $oldRuntimeRoot
            }
        }
    }

    Context '一切見つからない場合' {
        It '$null を返す' {
            Mock -ModuleName MediaNormalizer.Core Get-Command { return $null }
            $r = Find-FfmpegNormalize
            $r | Should -BeNullOrEmpty
        }
    }

    Context '候補リストの整理（P2-6: 拡張子なし候補の削除）' {
        It '拡張子なし ffmpeg-normalize（Linux 形式）は探索対象外で、結果に影響しない' {
            # P2-6 で `'ffmpeg-normalize'`（拡張子なし）が候補から削除されたことを固定化する。
            # 拡張子なしを引数に与えても、.exe/.cmd/.bat/py/python 経路で見つけられる関数になる。
            Mock -ModuleName MediaNormalizer.Core Get-Command {
                param($Name)
                if ($Name -eq 'ffmpeg-normalize') {
                    return [pscustomobject]@{ Source = 'C:\fake\ffmpeg-normalize' }
                }
                return $null
            }
            $r = Find-FfmpegNormalize
            # 拡張子なしは候補ではないため、結果は $null
            $r | Should -BeNullOrEmpty
        }
    }
}
