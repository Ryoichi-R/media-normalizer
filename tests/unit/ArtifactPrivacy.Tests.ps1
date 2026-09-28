#Requires -Version 7.0
#Requires -Modules Pester

Describe 'Media Normalizer portable ZIP privacy inspection' {
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $script:projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $script:privacyScript = Join-Path $script:projectRoot 'scripts\test-zip-privacy.ps1'

        function New-TestZip {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][hashtable]$Entries
            )

            $file = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
            try {
                $archive = [IO.Compression.ZipArchive]::new(
                    $file,
                    [IO.Compression.ZipArchiveMode]::Create,
                    $true)
                try {
                    foreach ($entryName in $Entries.Keys) {
                        $entry = $archive.CreateEntry($entryName)
                        $stream = $entry.Open()
                        try {
                            $bytes = [byte[]]$Entries[$entryName]
                            $stream.Write($bytes, 0, $bytes.Length)
                        }
                        finally {
                            $stream.Dispose()
                        }
                    }
                }
                finally {
                    $archive.Dispose()
                }
            }
            finally {
                $file.Dispose()
            }
        }
    }

    It 'accepts binary entries without bytecode or local user paths' {
        $zip = Join-Path $TestDrive 'clean.zip'
        New-TestZip -Path $zip -Entries @{
            'runtime/python/module.py' = [Text.Encoding]::UTF8.GetBytes('value = 1')
            'runtime/python/data.bin' = [byte[]](0, 1, 2, 3, 255)
        }

        $receipt = & $script:privacyScript -ZipPath $zip

        $receipt.Status | Should -Be 'OK'
        $receipt.EntriesScanned | Should -Be 2
        $receipt.BytecodeEntries | Should -Be 0
        $receipt.LocalWindowsUserPathCandidates | Should -Be 0
    }

    It 'rejects a pyc entry regardless of its contents' {
        $zip = Join-Path $TestDrive 'bytecode.zip'
        New-TestZip -Path $zip -Entries @{
            'runtime/python/Lib/site-packages/pkg/__pycache__/module.cpython-313.pyc' =
                [byte[]](1, 2, 3)
        }

        { & $script:privacyScript -ZipPath $zip } |
            Should -Throw '*excluded Python bytecode*'
    }

    It 'rejects an ASCII local Windows user path embedded in binary data' {
        $zip = Join-Path $TestDrive 'ascii-path.zip'
        $payload = [byte[]](0, 255) +
            [Text.Encoding]::UTF8.GetBytes('C:\Users\sample-user\AppData\Local\Temp\stage') +
            [byte[]](254, 1)
        New-TestZip -Path $zip -Entries @{ 'runtime/python/module.bin' = $payload }

        { & $script:privacyScript -ZipPath $zip } |
            Should -Throw '*local Windows user path candidate*'
    }

    It 'rejects a UTF-16 local Windows user path embedded in binary data' {
        $zip = Join-Path $TestDrive 'utf16-path.zip'
        $payload = [Text.Encoding]::Unicode.GetBytes(
            'C:\Users\sample-user\AppData\Local\Temp\stage')
        New-TestZip -Path $zip -Entries @{ 'runtime/python/module.bin' = $payload }

        { & $script:privacyScript -ZipPath $zip } |
            Should -Throw '*local Windows user path candidate*'
    }

    It 'accepts a clean macOS app archive' {
        $zip = Join-Path $TestDrive 'mac-clean.zip'
        New-TestZip -Path $zip -Entries @{ 'Example.app/Contents/Resources/data.bin' = [byte[]](1,2,3) }
        (& $script:privacyScript -ZipPath $zip -MacArchive).Status | Should -Be 'OK'
    }
    It 'rejects macOS local paths, state and escaping archive entries' -ForEach @(
        @{ Name='Example.app/Contents/Resources/data.bin'; Text='/Users/sample-owner/local'; Error='*path candidate*' },
        @{ Name='Example.app/Contents/Resources/settings.json'; Text='{}'; Error='*Excluded artifact*' },
        @{ Name='Example.app/../outside'; Text='x'; Error='*Unsafe archive path*' },
        @{ Name='Example.app/Contents/Resources/id_rsa'; Text='x'; Error='*Secret-like file*' }
    ) {
        $zip = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.zip')
        New-TestZip -Path $zip -Entries @{ $Name = [Text.Encoding]::UTF8.GetBytes($Text) }
        { & $script:privacyScript -ZipPath $zip -MacArchive } | Should -Throw $Error
    }
    It 'rejects local paths and state from app directories' {
        $app = Join-Path $TestDrive 'Test.app'
        $null = New-Item -ItemType Directory -Path $app
        Set-Content (Join-Path $app 'payload.bin') '/Users/sample-owner/private'
        { & $script:privacyScript -AppPath $app } | Should -Throw '*path candidate*'
        Set-Content (Join-Path $app 'payload.bin') 'safe'
        Set-Content (Join-Path $app 'settings.json') '{}'
        { & $script:privacyScript -AppPath $app } | Should -Throw '*Excluded artifact*'
    }
}
