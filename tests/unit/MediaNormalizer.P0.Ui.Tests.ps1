#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:libRoot = [IO.Path]::Combine(
        $PSScriptRoot,
        '..',
        '..',
        'lib')
    Import-Module ([IO.Path]::Combine(
            $script:libRoot,
            'MediaNormalizer.Core.psm1')) -Force
    Import-Module ([IO.Path]::Combine(
            $script:libRoot,
            'MediaNormalizer.Probe.psm1')) -Force
    Import-Module ([IO.Path]::Combine(
            $script:libRoot,
            'MediaNormalizer.Ui.psm1')) -Force
}

Describe 'P0 preset safety information' {
    It 'keeps purpose, basis, warning, and output format in the preset map' {
        InModuleScope MediaNormalizer.Ui {
            $map = ConvertTo-PresetMap -PresetList @(
                [pscustomobject]@{
                    name = '配信用'
                    target = -14
                    truePeak = -1
                    bitrate = '192k'
                    sampleRate = 48000
                    outputFormat = 'm4a'
                    purpose = '配信'
                    basis = '運用目安'
                    warning = '公式規格ではない'
                })

            $map['配信用'].OutputFormat | Should -Be 'm4a'
            (Get-PresetRationaleText -Preset $map['配信用']) |
                Should -Match '公式規格ではない'
        }
    }

    It 'detects values that diverge from the selected preset' {
        InModuleScope MediaNormalizer.Ui {
            $preset = @{
                Target = -16
                TruePeak = -1
                Bitrate = '192k'
                SampleRate = '48000'
                OutputFormat = 'mp3'
            }
            Test-PresetConfigurationMatches `
                -Preset $preset `
                -Target -14 `
                -TruePeak -1 `
                -Bitrate 192k `
                -SampleRate 48000 `
                -OutputFormat mp3 |
                Should -BeFalse
        }
    }
}

Describe 'P0 dropped input roots' {
    It 'finds a common root for multiple dropped files' {
        $root = Join-Path $TestDrive 'library'
        $firstDirectory = Join-Path $root 'album-a'
        $secondDirectory = Join-Path $root 'album-b'
        New-Item -ItemType Directory -Path $firstDirectory, $secondDirectory -Force |
            Out-Null
        $first = Join-Path $firstDirectory 'a.wav'
        $second = Join-Path $secondDirectory 'b.wav'
        Set-Content -LiteralPath $first -Value 'a'
        Set-Content -LiteralPath $second -Value 'b'

        InModuleScope MediaNormalizer.Ui -Parameters @{
            first = $first
            second = $second
            expected = $root
        } {
            param($first, $second, $expected)
            Get-CommonInputRoot -Paths @($first, $second) |
                Should -Be ([IO.Path]::GetFullPath($expected))
        }
    }
}

Describe 'P0 single-folder scan' {
    BeforeEach {
        $inputFolder = Join-Path $TestDrive 'single-folder'
        New-Item -ItemType Directory -Path $inputFolder -Force | Out-Null
        1..4 | ForEach-Object {
            Set-Content -LiteralPath (Join-Path $inputFolder "$_.wav") -Value "audio-$_"
        }
    }

    It 'scans four media files when one folder is selected explicitly' {
        InModuleScope MediaNormalizer.Ui -Parameters @{
            inputFolder = $inputFolder
        } {
            param($inputFolder)
            Mock Update-FileGrid {}
            $state = [pscustomobject]@{
                Controls = @{
                    TxtInput = [pscustomobject]@{ Text = $inputFolder }
                    ChkRecurse = [pscustomobject]@{ Checked = $true }
                }
                InputSelectionPaths = @($inputFolder)
                ScanValid = $false
                CachedFiles = @()
            }

            Update-FileList -State $state

            $state.ScanValid | Should -BeTrue
            $state.CachedFiles.Count | Should -Be 4
            Should -Invoke Update-FileGrid -Times 1 -Exactly
        }
    }

    It 'scans four media files when one folder is entered in the text box' {
        InModuleScope MediaNormalizer.Ui -Parameters @{
            inputFolder = $inputFolder
        } {
            param($inputFolder)
            Mock Update-FileGrid {}
            $state = [pscustomobject]@{
                Controls = @{
                    TxtInput = [pscustomobject]@{ Text = $inputFolder }
                    ChkRecurse = [pscustomobject]@{ Checked = $true }
                }
                InputSelectionPaths = @()
                ScanValid = $false
                CachedFiles = @()
            }

            Update-FileList -State $state

            $state.ScanValid | Should -BeTrue
            $state.CachedFiles.Count | Should -Be 4
            Should -Invoke Update-FileGrid -Times 1 -Exactly
        }
    }
}

Describe 'P0 input drop targets' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
    It 'accepts file drops on the form, input box, and file grid' {
        InModuleScope MediaNormalizer.Ui {
            $state = New-MediaNormalizerState
            $state = Initialize-UiState -State $state
            $form = $null
            try {
                $form = New-MainForm -State $state
                $form.AllowDrop | Should -BeTrue
                $state.Controls.TxtInput.AllowDrop | Should -BeTrue
                $state.Controls.Dgv.AllowDrop | Should -BeTrue
            } finally {
                if ($state.LogTimer) {
                    $state.LogTimer.Stop()
                    $state.LogTimer.Dispose()
                    $state.LogTimer = $null
                }
                if ($null -ne $form) { $form.Dispose() }
            }
        }
    }
}
