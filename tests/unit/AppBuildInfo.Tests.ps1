#Requires -Modules Pester

BeforeAll {
    $script:projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    . (Join-Path $script:projectRoot 'scripts/shared/app-build-info.ps1')
    function New-InfoFixture {
        param($Revision='0123456789ab', $Dirty=$false, [string]$Runtime='osx-arm64')
        [ordered]@{ schemaVersion=1; appName='Media Normalizer'; productVersion='1.1.0';
            sourceRevision=$Revision; hasUncommittedChanges=$Dirty; builtAtUtc='2026-10-18T03:00:00.1234567Z'; targetRuntime=$Runtime }
    }
    function fake-build-git {
        param([Parameter(ValueFromRemainingArguments)][object[]]$Items)
        $global:LASTEXITCODE=0
        if ($Items -contains '--show-toplevel') { return $script:gitRoot }
        if ($Items -contains '--short=12') {
            if ($script:gitMode -eq 'no-head') { $global:LASTEXITCODE=1; return }
            return '0123456789ab'
        }
        if ($script:gitMode -eq 'status-failed') { $global:LASTEXITCODE=1; return }
        switch ($script:gitMode) {
            'tracked' { ' M lib/example.psm1' }
            'staged' { 'M  lib/example.psm1' }
            'untracked' { '?? note.txt' }
        }
    }
}

Describe 'App build information contract and presentation' {
    It 'accepts nullable Git values and validates the shared JSON schema' {
        $json=New-InfoFixture -Revision $null -Dirty $null | ConvertTo-Json
        $json | Test-Json -SchemaFile (Join-Path $script:projectRoot 'contracts/app-build-info.schema.json') | Should -BeTrue
        $info=ConvertFrom-AppBuildInfoJson $json
        $info.sourceRevision | Should -BeNullOrEmpty
        $info.hasUncommittedChanges | Should -BeNullOrEmpty
        $text=Format-AppBuildInfo $info -Platform macOS -Architecture ARM64
        $text | Should -Match 'ソース識別子: 不明'
        $text | Should -Match '未コミット変更の有無: 不明'
    }
    It 'formats exactly six named fields in the specified order' {
        $info=ConvertFrom-AppBuildInfoJson (New-InfoFixture | ConvertTo-Json)
        $text=Format-AppBuildInfo $info -Platform Windows -Architecture x64
        $lines=$text -split "`n"
        $lines.Count | Should -Be 6
        @($lines | ForEach-Object { ($_ -split ': ',2)[0] }) | Should -Be @('アプリ名','バージョン','ソース識別子','未コミット変更の有無','ビルド日時','実行版')
        $lines[1] | Should -Be 'バージョン: 1.1.0'
        $lines[4] | Should -Be 'ビルド日時: 2026-10-18 03:00:00 UTC'
        $lines[5] | Should -Be '実行版: Windows／x64'
        $text | Should -Not -Match 'targetRuntime|osx-arm64'
    }
    It 'preserves the UTC date for both parsed DateTime and string paths under <Culture>' -ForEach @(@{Culture='en-US'},@{Culture='ja-JP'}) {
        $before=[Globalization.CultureInfo]::CurrentCulture
        try {
            [Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($Culture)
            $expected=[datetimeoffset]'2026-10-18T03:00:00.1234567Z'
            (ConvertTo-AppBuildDateUtc '2026-10-18T03:00:00.1234567Z').Ticks | Should -Be $expected.Ticks
            (ConvertTo-AppBuildDateUtc $expected.UtcDateTime).Ticks | Should -Be $expected.Ticks
            $info=ConvertFrom-AppBuildInfoJson (New-InfoFixture | ConvertTo-Json)
            (Format-AppBuildInfo $info) | Should -Match '2026-10-18 03:00:00 UTC'
        } finally { [Globalization.CultureInfo]::CurrentCulture=$before }
    }
    It 'rejects corrupted or unsafe fields: <Field>' -ForEach @(
        @{Field='schemaVersion';Value=2},@{Field='schemaVersion';Value='1'},@{Field='appName';Value='/Users/example'},
        @{Field='productVersion';Value='1.1.0+osx'},@{Field='sourceRevision';Value='/private/repository'},
        @{Field='hasUncommittedChanges';Value='false'},@{Field='builtAtUtc';Value='2026-10-18T12:00:00+09:00'},
        @{Field='targetRuntime';Value='other'}) {
        $fixture=New-InfoFixture
        $fixture[$Field]=$Value
        { ConvertFrom-AppBuildInfoJson ($fixture | ConvertTo-Json) } | Should -Throw '*BUILD_INFO_INVALID*'
    }
    It 'rejects extra fields rather than copying arbitrary build data' {
        $fixture=New-InfoFixture
        $fixture.path='private value'
        { ConvertFrom-AppBuildInfoJson ($fixture | ConvertTo-Json) } | Should -Throw
    }
    It 'handles missing and broken files without synthesizing build time or querying Git' {
        Mock Get-MediaNormalizerGitInfo { throw 'Runtime must not query Git' }
        $path=Join-Path $TestDrive 'missing.json'
        (Read-AppBuildInfo -Path $path).builtAtUtc | Should -BeNullOrEmpty
        { Read-AppBuildInfo -Path $path -Strict } | Should -Throw
        Set-Content $path '{broken'
        $info=Read-AppBuildInfo -Path $path
        $info.productVersion | Should -BeNullOrEmpty
        (Format-AppBuildInfo $info) | Should -Match 'ビルド日時: 不明'
        Should -Invoke Get-MediaNormalizerGitInfo -Times 0
    }
    It 'reports dirty true as あり and false as なし' {
        (Format-AppBuildInfo (ConvertFrom-AppBuildInfoJson (New-InfoFixture -Dirty $true | ConvertTo-Json))) | Should -Match '未コミット変更の有無: あり'
        (Format-AppBuildInfo (ConvertFrom-AppBuildInfoJson (New-InfoFixture -Dirty $false | ConvertTo-Json))) | Should -Match '未コミット変更の有無: なし'
    }
    It 'uses the real process API and never lets the environment override it' {
        Get-AppProcessArchitecture -ProcessArchitecture { 'Arm64' } -EnvironmentArchitecture { throw 'must not run' } -BinaryArchitecture { throw 'must not run' } | Should -Be 'ARM64'
    }
    It 'uses fallback only when process architecture cannot be obtained' {
        Get-AppProcessArchitecture -ProcessArchitecture { throw 'unavailable' } -EnvironmentArchitecture { 'AMD64' } | Should -Be x64
        Get-AppProcessArchitecture -ProcessArchitecture { $null } -EnvironmentArchitecture { $null } -BinaryArchitecture { 'arm64' } | Should -Be ARM64
        Get-AppProcessArchitecture -ProcessArchitecture { $null } -EnvironmentArchitecture { 'invalid' } -BinaryArchitecture { 'unknown' } | Should -Be '不明'
    }
    It 'retries clipboard contention and copies the same text once successful' {
        $state=@{Count=0;Text=$null}
        $writer={ param($value); $state.Count++; if($state.Count -lt 3){throw [Runtime.InteropServices.ExternalException]::new('busy')}; $state.Text=$value }.GetNewClosure()
        Invoke-AppInfoCopy -Text 'six fields' -Writer $writer -RetryDelayMilliseconds 0 | Should -BeTrue
        $state.Count | Should -Be 3
        $state.Text | Should -Be 'six fields'
    }
    It 'returns failure after bounded clipboard contention or another exception' {
        Invoke-AppInfoCopy -Text 'text' -Writer { throw [Runtime.InteropServices.ExternalException]::new('busy') } -RetryDelayMilliseconds 0 | Should -BeFalse
        Invoke-AppInfoCopy -Text 'text' -Writer { throw 'unsupported' } | Should -BeFalse
    }
}

Describe 'Build-time Git and generation' {
    BeforeEach {
        $script:gitRoot=$script:projectRoot
        $script:gitMode='clean'
        Mock Get-Command -ParameterFilter { $Name -eq 'git' } { [pscustomobject]@{Source='fake-build-git'} }
    }
    It 'evaluates the real product definition consistently for both applications' {
        $product=Get-MediaNormalizerProduct -ProjectRoot $script:projectRoot
        [xml]$definition=[IO.File]::ReadAllText((Join-Path $script:projectRoot 'Directory.Build.props'))
        $product.Version | Should -Be $definition.Project.PropertyGroup.Version
        $product.Product | Should -Be 'Media Normalizer'
    }
    It 'rejects differing evaluated versions instead of choosing one project silently' {
        foreach($entry in @(@('MediaNormalizer.Gui','1.2.0'),@('MediaNormalizer.Launcher','1.3.0'))) {
            $directory=Join-Path $TestDrive ('src/'+$entry[0])
            $null=New-Item -ItemType Directory -Path $directory -Force
            $xml='<Project><PropertyGroup><Product>Media Normalizer</Product><Version>'+$entry[1]+'</Version></PropertyGroup></Project>'
            [IO.File]::WriteAllText((Join-Path $directory ($entry[0]+'.csproj')),$xml)
        }
        { Get-MediaNormalizerProduct -ProjectRoot $TestDrive } | Should -Throw '*PRODUCT_MISMATCH*'
    }
    It 'records <Mode> source state without keeping filenames' -ForEach @(
        @{Mode='clean';Dirty=$false},@{Mode='tracked';Dirty=$true},@{Mode='staged';Dirty=$true},@{Mode='untracked';Dirty=$true}) {
        $script:gitMode=$Mode
        $info=Get-MediaNormalizerGitInfo $script:projectRoot
        $info.sourceRevision | Should -Be '0123456789ab'
        $info.hasUncommittedChanges | Should -Be $Dirty
        ($info | ConvertTo-Json) | Should -Not -Match 'example.psm1|note.txt'
    }
    It 'does not adopt a parent repository identity' {
        $script:gitRoot=Split-Path $script:projectRoot -Parent
        $info=Get-MediaNormalizerGitInfo $script:projectRoot
        $info.sourceRevision | Should -BeNullOrEmpty
        $info.hasUncommittedChanges | Should -BeNullOrEmpty
    }
    It 'records Git unavailable as unknown, never clean' {
        Mock Get-Command -ParameterFilter { $Name -eq 'git' } { throw 'missing' }
        $info=Get-MediaNormalizerGitInfo $script:projectRoot
        $info.sourceRevision | Should -BeNullOrEmpty
        $info.hasUncommittedChanges | Should -BeNullOrEmpty
    }
    It 'retains unknown state for failed status, independently of HEAD' {
        $script:gitMode='status-failed'
        $info=Get-MediaNormalizerGitInfo $script:projectRoot
        $info.sourceRevision | Should -Be '0123456789ab'
        $info.hasUncommittedChanges | Should -BeNullOrEmpty
        $script:gitMode='no-head'
        (Get-MediaNormalizerGitInfo $script:projectRoot).sourceRevision | Should -BeNullOrEmpty
    }
    It 'generates nullable and dirty packages without changing product version for RID or rebuild' {
        Mock Get-MediaNormalizerProduct { [pscustomobject]@{Version='1.1.0';Product='Media Normalizer'} }
        Mock Get-MediaNormalizerGitInfo { [pscustomobject]@{sourceRevision=$null;hasUncommittedChanges=$null} }
        $one=New-MediaNormalizerBuildInfo -ProjectRoot $script:projectRoot -Runtime osx-arm64 -Destination (Join-Path $TestDrive 'one.json')
        Mock Get-MediaNormalizerGitInfo { [pscustomobject]@{sourceRevision='0123456789ab';hasUncommittedChanges=$true} }
        $two=New-MediaNormalizerBuildInfo -ProjectRoot $script:projectRoot -Runtime win-arm64 -Destination (Join-Path $TestDrive 'two.json')
        $one.productVersion | Should -Be $two.productVersion
        $one.builtAtUtc | Should -Not -Be $two.builtAtUtc
        $two.hasUncommittedChanges | Should -BeTrue
        $one.sourceRevision | Should -BeNullOrEmpty
        Copy-Item (Join-Path $TestDrive 'one.json') (Join-Path $TestDrive 'build-info.json')
        (Assert-MediaNormalizerPackageBuildInfo -PackageRoot $TestDrive -Runtime osx-arm64).productVersion | Should -Be '1.1.0'
    }
    It 'rejects package target mismatch and source changes' {
        New-InfoFixture | ConvertTo-Json | Set-Content (Join-Path $TestDrive 'build-info.json')
        { Assert-MediaNormalizerPackageBuildInfo -PackageRoot $TestDrive -Runtime win-x64 } | Should -Throw '*MISMATCH*'
        { Assert-MediaNormalizerSourceSnapshot -ProjectRoot $script:projectRoot -Snapshot ([pscustomobject]@{Digest='wrong';Revision=$null}) } | Should -Throw '*SOURCE_CHANGED*'
    }
    It 'rejects a changed copied input: <Relative>' -ForEach @(
        @{Relative='diagnostics/runtime-check.ps1'},@{Relative='diagnostics/runtime-check-macos.ps1'},
        @{Relative='diagnostics/diagnose.ps1'},@{Relative='diagnostics/runtime-check.bat'},
        @{Relative='diagnostics/diagnose.bat'},@{Relative='launcher-legacy/runtime-env.bat'},
        @{Relative='LICENSE'},@{Relative='THIRD-PARTY-NOTICES.md'}) {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $path=Join-Path $root $Relative
        $null=New-Item -ItemType Directory -Path (Split-Path $path) -Force
        [IO.File]::WriteAllText($path,'initial fixture')
        $snapshot=Get-MediaNormalizerSourceSnapshot -ProjectRoot $root
        [IO.File]::WriteAllText($path,'changed fixture')
        { Assert-MediaNormalizerSourceSnapshot -ProjectRoot $root -Snapshot $snapshot } | Should -Throw '*SOURCE_CHANGED*'
    }
    It 'marks the information and runtime UI dependencies as required' {
        $required=Import-PowerShellDataFile (Join-Path $script:projectRoot 'scripts/media-normalizer-required-files.psd1')
        $required.RequiredRelativePaths | Should -Contain 'build-info.json'
        $required.RequiredRelativePaths | Should -Contain 'lib\MediaNormalizer.UiLogic.psm1'
        $required.RequiredRelativePaths | Should -Contain 'lib\MediaNormalizer.Platform.psm1'
        $required.MacAppRequiredRelativePaths | Should -Contain 'Contents/Resources/build-info.json'
    }
}

Describe 'Windows settings version window' -Tag WindowsOnly {
    BeforeAll { Import-Module (Join-Path $script:projectRoot 'lib/MediaNormalizer.Ui.psm1') -Force }
    It 'opens exactly one settings window with six information fields' {
        InModuleScope MediaNormalizer.Ui {
            Initialize-UiAssemblies
            $owner=New-Object System.Windows.Forms.Form
            try {
                $owner.Show()
                Show-AppSettings -Owner $owner
                Show-AppSettings -Owner $owner
                $owner.OwnedForms.Count | Should -Be 1
                $dialog=$owner.OwnedForms[0]
                $dialog.Text | Should -Be '設定'
                $text=@($dialog.Controls[0].Controls | Where-Object { $_ -is [Windows.Forms.TextBox] })[0]
                $text.Lines.Count | Should -Be 6
            } finally { $owner.Dispose() }
        }
    }
}
