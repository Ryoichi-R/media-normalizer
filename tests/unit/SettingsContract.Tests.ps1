#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:contractRoot = Join-Path $script:repoRoot 'contracts/fixtures/settings'
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.Core.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'lib/MediaNormalizer.Ui.psm1') -Force
}

Describe 'Settings schema 2 PowerShell contract' {
    It 'schema describes the five canonical fields and permits forward extension fields' {
        $schema = Get-Content -LiteralPath (Join-Path $script:repoRoot 'contracts/settings.schema.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $schema.properties.version.type | Should -Be 'integer'
        $schema.properties.lastMode.enum | Should -Contain 'audio'
        $schema.additionalProperties | Should -BeTrue
        @($schema.properties.Keys | Sort-Object) | Should -Be @('inputDir', 'lastMode', 'lastPreset', 'outputDir', 'version')
    }

    It 'reads schema 2 known fields and retains an unknown extension object separately' {
        $path = Join-Path $script:contractRoot 'settings-v2-unknown.json'
        $result = InModuleScope MediaNormalizer.Ui -Parameters @{ p = $path } {
            param($p)
            Read-Settings -SettingsPath $p
        }
        $result.Values.InputDir | Should -Be '/Users/fixtures/input'
        $result.Values.OutputDir | Should -Be '/Users/fixtures/output'
        $result.Values.LastPreset | Should -Be 'broadcast-custom'
        $result.Values.LastMode | Should -Be 'video'
        @($result.Values.Keys | Sort-Object) | Should -Be @('InputDir', 'LastMode', 'LastPreset', 'OutputDir')
        $result.ExtensionFields.extensionState.selectedTab | Should -Be 'advanced'
        @($result.ExtensionFields.extensionState.futureFlags) | Should -Be @('safe-fixture-value')
        @($result.Warnings).Count | Should -Be 0
    }

    It 'preserves unknown input fields while updating canonical values on rewrite' {
        $fixture = Join-Path $script:contractRoot 'settings-v2-unknown.json'
        $expectedPath = Join-Path $script:contractRoot 'settings-save-v2-unknown.json'
        $tempPath = Join-Path ([IO.Path]::GetTempPath()) ("mn-settings-contract-" + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $loaded = InModuleScope MediaNormalizer.Ui -Parameters @{ p = $fixture } {
                param($p)
                Read-Settings -SettingsPath $p
            }
            InModuleScope MediaNormalizer.Ui -Parameters @{ p = $tempPath; v = $loaded } {
                param($p, $v)
                Save-Settings -SettingsPath $p -InputDir $v.Values.InputDir -OutputDir $v.Values.OutputDir -LastPreset $v.Values.LastPreset -LastMode $v.Values.LastMode -ExtensionFields $v.ExtensionFields
            }
            $saved = Get-Content -LiteralPath $tempPath -Raw | ConvertFrom-Json
            $expected = Get-Content -LiteralPath $expectedPath -Raw | ConvertFrom-Json
            ConvertTo-Json -InputObject $saved -Depth 5 -Compress | Should -Be (ConvertTo-Json -InputObject $expected -Depth 5 -Compress)
            @($saved.PSObject.Properties.Name | Sort-Object) | Should -Be @('extensionState', 'inputDir', 'lastMode', 'lastPreset', 'outputDir', 'version')
        } finally {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'migrates matching v1 auto paths to unset while retaining a user-selected output path' {
        $path = Join-Path $script:contractRoot 'settings-v1-legacy.json'
        $result = InModuleScope MediaNormalizer.Ui -Parameters @{ p = $path } {
            param($p)
            Read-Settings -SettingsPath $p -LegacyAutoDefaults @{
                InputDir = '/Users/fixtures/pre-normalization data'
                OutputDir = '/Users/fixtures/normalization data'
            }
        }
        $result.Values.InputDir | Should -Be ''
        $result.Values.OutputDir | Should -Be '/Users/fixtures/custom-output'
        $result.Values.LastMode | Should -Be 'both'
    }

    It 'falls back to supplied defaults for a future schema version' {
        $path = Join-Path $script:contractRoot 'settings-v99-future.json'
        $defaults = @{ InputDir = '/Users/default/in'; OutputDir = '/Users/default/out'; LastPreset = 'デフォルト'; LastMode = 'audio' }
        $result = InModuleScope MediaNormalizer.Ui -Parameters @{ p = $path; d = $defaults } {
            param($p, $d)
            Read-Settings -SettingsPath $p -Defaults $d
        }
        $result.Values.InputDir | Should -Be '/Users/default/in'
        $result.Values.LastMode | Should -Be 'audio'
        @($result.Warnings | Where-Object { $_ -match '未知' }).Count | Should -Be 1
    }

    It 'falls back to default values and records a warning for a missing version' {
        $path = Join-Path $script:contractRoot 'settings-missing-version.json'
        $result = InModuleScope MediaNormalizer.Ui -Parameters @{ p = $path } {
            param($p)
            Read-Settings -SettingsPath $p
        }
        $result.Values.InputDir | Should -Be ''
        $result.Values.LastMode | Should -Be 'audio'
        @($result.Warnings | Where-Object { $_ -match 'version' }).Count | Should -Be 1
    }

    It 'falls back to default values and records a warning for malformed JSON' {
        $path = Join-Path $script:contractRoot 'settings-invalid.txt'
        $result = InModuleScope MediaNormalizer.Ui -Parameters @{ p = $path } {
            param($p)
            Read-Settings -SettingsPath $p
        }
        $result.Values.InputDir | Should -Be ''
        $result.Values.LastPreset | Should -Be 'デフォルト'
        @($result.Warnings | Where-Object { $_ -match '解析に失敗' }).Count | Should -Be 1
    }
}
