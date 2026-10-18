param([string]$AppPath)

Describe 'macOS build information artifacts' -Skip:([string]::IsNullOrWhiteSpace($AppPath)) {
    BeforeAll {
        $script:sourceApp = $AppPath
        $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        . (Join-Path $projectRoot 'scripts/shared/app-build-info.ps1')
        $script:expectedProduct = Get-MediaNormalizerProduct -ProjectRoot $projectRoot
        function New-InfoAppFixture {
            $fixture=Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.app')
            $resource=Join-Path $fixture 'Contents/Resources'
            $null=New-Item -ItemType Directory (Join-Path $resource 'gui') -Force
            Copy-Item (Join-Path $script:sourceApp 'Contents/Info.plist') (Join-Path $fixture 'Contents/Info.plist')
            Copy-Item (Join-Path $script:sourceApp 'Contents/Resources/build-info.json') (Join-Path $resource 'build-info.json')
            Copy-Item (Join-Path $script:sourceApp 'Contents/Resources/gui/MediaNormalizer.Gui.dll') (Join-Path $resource 'gui/MediaNormalizer.Gui.dll')
            return $fixture
        }
    }
    It 'matches product metadata and byte-identical embedded information' {
        $fixture=New-InfoAppFixture
        $info=Assert-MediaNormalizerMacBuildInfo -AppPath $fixture
        $info.productVersion | Should -Be $script:expectedProduct.Version
        $info.targetRuntime | Should -Be 'osx-arm64'
    }
    It 'rejects a package JSON changed after the GUI was built' {
        $fixture=New-InfoAppFixture
        $jsonPath=Join-Path $fixture 'Contents/Resources/build-info.json'
        $json=[IO.File]::ReadAllText($jsonPath)
        $json=[regex]::Replace($json, '("hasUncommittedChanges"\s*:\s*)(true|false|null)', { param($m); $m.Groups[1].Value + $(if($m.Groups[2].Value -eq 'true'){'false'}else{'true'}) })
        [IO.File]::WriteAllText($jsonPath,$json,[Text.UTF8Encoding]::new($false))
        { Assert-MediaNormalizerMacBuildInfo $fixture } | Should -Throw '*RESOURCE_MISMATCH*'
    }
    It 'compares bytes including a changed UTF-8 BOM' {
        $fixture=New-InfoAppFixture
        $jsonPath=Join-Path $fixture 'Contents/Resources/build-info.json'
        [IO.File]::WriteAllText($jsonPath,[IO.File]::ReadAllText($jsonPath),[Text.UTF8Encoding]::new($true))
        { Assert-MediaNormalizerMacBuildInfo $fixture } | Should -Throw '*RESOURCE_MISMATCH*'
    }
    It 'rejects a plist version mismatch' {
        $fixture=New-InfoAppFixture
        $path=Join-Path $fixture 'Contents/Info.plist'
        [xml]$plist=[IO.File]::ReadAllText($path)
        $versionNode=$plist.SelectSingleNode('/plist/dict/key[. = "CFBundleShortVersionString"]/following-sibling::*[1]')
        $versionNode.InnerText=$(if($versionNode.InnerText -ceq '0.0.0'){'0.0.1'}else{'0.0.0'})
        $plist.Save($path)
        { Assert-MediaNormalizerMacBuildInfo $fixture } | Should -Throw '*PLIST_MISMATCH*'
    }
    It 'rejects missing information and an invalid target runtime' {
        $fixture=New-InfoAppFixture
        $path=Join-Path $fixture 'Contents/Resources/build-info.json'
        [IO.File]::WriteAllText($path,[IO.File]::ReadAllText($path).Replace('osx-arm64','win-arm64'))
        { Assert-MediaNormalizerMacBuildInfo $fixture } | Should -Throw '*PACKAGE_MISMATCH*'
        [IO.File]::WriteAllText($path,'{}')
        { Assert-MediaNormalizerMacBuildInfo $fixture } | Should -Throw '*INVALID*'
    }
}
