#Requires -Modules Pester

Describe 'Media Normalizer portable dependency downloads' {
    BeforeAll {
        $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\'))
        $prepareScript = Join-Path $projectRoot 'scripts\prepare-portable-runtime.ps1'
        $tokens = $null
        $parseErrors = $null
        $scriptAst = [Management.Automation.Language.Parser]::ParseFile(
            $prepareScript,
            [ref]$tokens,
            [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0

        foreach ($functionName in @(
                'ConvertTo-CanonicalPath',
                'Assert-PathWithinRoot',
                'New-DependencyWebRequestParameters',
                'Invoke-DependencyTransfer',
                'Get-VerifiedArtifact')) {
            $functionAst = $scriptAst.Find(
                {
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $functionName
                },
                $true)
            $functionAst | Should -Not -BeNullOrEmpty
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }
    }

    BeforeEach {
        $script:downloadAttempts = 0
        $script:fixtureBytes = [Text.Encoding]::UTF8.GetBytes(
            'verified portable dependency fixture')
        Mock Start-Sleep {}
    }

    It 'retries failed downloads and verifies the successful artifact' {
        Mock Invoke-DependencyTransfer {
            $script:downloadAttempts++
            if ($script:downloadAttempts -lt 3) {
                throw "simulated attempt $script:downloadAttempts failure"
            }
            [IO.File]::WriteAllBytes($OutFile, $script:fixtureBytes)
        }
        $expectedHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($script:fixtureBytes))

        $result = Get-VerifiedArtifact `
            -Url 'https://example.invalid/dependency.zip' `
            -FileName 'dependency.zip' `
            -Sha256 $expectedHash `
            -CacheDirectory $TestDrive `
            -DownloadTimeoutSeconds 30 `
            -DownloadRetryCount 2

        $script:downloadAttempts | Should -Be 3
        Test-Path -LiteralPath $result -PathType Leaf | Should -BeTrue
        (Get-FileHash -LiteralPath $result -Algorithm SHA256).Hash |
            Should -Be $expectedHash
        Should -Invoke Invoke-DependencyTransfer -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'fails after the bounded attempts and removes partial downloads' {
        Mock Invoke-DependencyTransfer {
            $script:downloadAttempts++
            [IO.File]::WriteAllText($OutFile, 'partial')
            throw 'simulated persistent failure'
        }

        {
            Get-VerifiedArtifact `
                -Url 'https://example.invalid/dependency.zip' `
                -FileName 'dependency.zip' `
                -Sha256 ('0' * 64) `
                -CacheDirectory $TestDrive `
                -DownloadTimeoutSeconds 30 `
                -DownloadRetryCount 2
        } | Should -Throw '*failed after 3 attempts*'

        $script:downloadAttempts | Should -Be 3
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.download' -Force).Count |
            Should -Be 0
        Should -Invoke Invoke-DependencyTransfer -Times 3 -Exactly
    }

    It 'normalizes multiple curl command candidates to one executable' {
        $functionAst = $scriptAst.Find(
            {
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Invoke-DependencyTransfer'
            },
            $true)

        $functionAst.Extent.Text |
            Should -Match '\@\(Get-Command curl\.exe[\s\S]*\)\s*\|\s*Select-Object -First 1'
    }
}
