#Requires -Modules Pester

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\lib\MediaNormalizer.Ui.psm1') -Force
}

AfterAll {
    Remove-Module MediaNormalizer.Ui -Force -ErrorAction SilentlyContinue
}

Describe 'Write-LogBuffer persistent log' {
    BeforeEach {
        $script:testRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'mn-log-' + [Guid]::NewGuid().ToString('N'))
        New-Item -Path $script:testRoot -ItemType Directory | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'GUIコントロールがなくてもログを永続化する' {
        $state = [pscustomobject]@{
            LogBuffer = [Text.StringBuilder]::new()
            LogPath = Join-Path $script:testRoot 'media-normalizer.log'
            LogPersistenceWarningIssued = $false
            Controls = @{ TxtLog = $null }
        }
        [void]$state.LogBuffer.AppendLine('[INFO ] persisted')

        InModuleScope MediaNormalizer.Ui -Parameters @{ s = $state } {
            param($s)
            Write-LogBuffer -State $s
        }

        (Get-Content -LiteralPath $state.LogPath -Raw) | Should -Match '\[INFO \] persisted'
        $state.LogBuffer.Length | Should -Be 0
    }
}
