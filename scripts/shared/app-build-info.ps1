# Build-time helpers. Runtime parsing/formatting remains in UiLogic (PS 5.1 compatible).
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../../lib/MediaNormalizer.UiLogic.psm1') -Scope Local -DisableNameChecking

function Get-MediaNormalizerProduct {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $values = foreach ($relative in @('src/MediaNormalizer.Gui/MediaNormalizer.Gui.csproj','src/MediaNormalizer.Launcher/MediaNormalizer.Launcher.csproj')) {
        $output = & dotnet msbuild (Join-Path $ProjectRoot $relative) -nologo -getProperty:Version -getProperty:Product 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'BUILD_INFO_PRODUCT_EVALUATION_FAILED' }
        ($output -join "`n" | ConvertFrom-Json).Properties
    }
    if ($values[0].Version -cne $values[1].Version -or $values[0].Product -cne $values[1].Product) { throw 'BUILD_INFO_PRODUCT_MISMATCH' }
    return $values[0]
}

function Get-MediaNormalizerGitInfo {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $result = [ordered]@{ sourceRevision=$null; hasUncommittedChanges=$null }
    try {
        $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $top = @(& $git.Source -C $ProjectRoot rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -ne 0 -or $top.Count -ne 1 -or
            [IO.Path]::GetFullPath($top[0]).TrimEnd('/','\') -cne [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('/','\')) { return [pscustomobject]$result }
        $revision = @(& $git.Source -C $ProjectRoot rev-parse --short=12 HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $revision.Count -eq 1 -and $revision[0] -cmatch '^[0-9a-f]{12,64}$') { $result.sourceRevision = $revision[0] }
        $status = @(& $git.Source -C $ProjectRoot status --porcelain=v1 --untracked-files=normal 2>$null)
        if ($LASTEXITCODE -eq 0) { $result.hasUncommittedChanges = ($status.Count -gt 0) }
    } catch { return [pscustomobject]$result }
    return [pscustomobject]$result
}

function Get-MediaNormalizerSourceSnapshot {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $files = @()
    foreach ($directory in @('src','lib','scripts','assets','contracts','installer','docs','diagnostics','launcher-legacy')) {
        $path = Join-Path $ProjectRoot $directory
        if (Test-Path -LiteralPath $path) {
            $files += Get-ChildItem -LiteralPath $path -File -Recurse | Where-Object {
                $_.FullName -notmatch '[/\\](bin|obj|payload|\.work)[/\\]' -and
                $_.Name -notmatch '^(\.env|secrets?\.|settings\.json$|presets\.user\.json$)' -and
                $_.Extension -in @('.cs','.csproj','.props','.ps1','.psm1','.psd1','.json','.md','.png','.icns','.manifest','.bat','.sh')
            }
        }
    }
    foreach ($name in @('Directory.Build.props','portable-dependencies.json','media-normalizer.ps1','media-normalizer.sh','runtime-env.sh','runtime-check.sh','diagnose.sh','README.md','CONTRIBUTING.md','LICENSE','THIRD-PARTY-NOTICES.md')) {
        $path = Join-Path $ProjectRoot $name
        if (Test-Path -LiteralPath $path) { $files += Get-Item -LiteralPath $path }
    }
    $rows = foreach ($file in ($files | Sort-Object FullName)) {
        [IO.Path]::GetRelativePath($ProjectRoot, $file.FullName).Replace('\','/') + ':' + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $digest = [Convert]::ToHexString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($rows -join "`n")))) }
    finally { $hash.Dispose() }
    $git = Get-MediaNormalizerGitInfo -ProjectRoot $ProjectRoot
    return [pscustomobject]@{ Digest=$digest; Revision=$git.sourceRevision }
}

function Assert-MediaNormalizerSourceSnapshot {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)]$Snapshot)
    $after = Get-MediaNormalizerSourceSnapshot -ProjectRoot $ProjectRoot
    if ($after.Digest -cne $Snapshot.Digest -or $after.Revision -cne $Snapshot.Revision) { throw 'BUILD_INFO_SOURCE_CHANGED_DURING_BUILD' }
}

function New-MediaNormalizerBuildInfo {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidateSet('win-x64','win-arm64','osx-arm64')][string]$Runtime,
        [Parameter(Mandatory)][string]$Destination)
    $product = Get-MediaNormalizerProduct -ProjectRoot $ProjectRoot
    $git = Get-MediaNormalizerGitInfo -ProjectRoot $ProjectRoot
    $info = [ordered]@{ schemaVersion=1; appName=$product.Product; productVersion=$product.Version;
        sourceRevision=$git.sourceRevision; hasUncommittedChanges=$git.hasUncommittedChanges;
        builtAtUtc=[DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture);
        targetRuntime=$Runtime }
    $json = ($info | ConvertTo-Json) + "`n"
    $validated = ConvertFrom-AppBuildInfoJson -Json $json
    if ($PSCmdlet.ShouldProcess('build-info.json', 'Write generated build information')) {
        [IO.File]::WriteAllText($Destination, $json, [Text.UTF8Encoding]::new($false))
    }
    return $validated
}

function Assert-MediaNormalizerPackageBuildInfo {
    param([Parameter(Mandatory)][string]$PackageRoot, [Parameter(Mandatory)][string]$Runtime,
        [string]$ExpectedVersion)
    $info = Read-AppBuildInfo -Path (Join-Path $PackageRoot 'build-info.json') -Strict
    if ($info.targetRuntime -cne $Runtime -or ($ExpectedVersion -and $info.productVersion -cne $ExpectedVersion)) { throw 'BUILD_INFO_PACKAGE_MISMATCH' }
    if ($Runtime -like 'win-*') {
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $PackageRoot 'MediaNormalizer.exe'))
        if ($version.ProductVersion -cne $info.productVersion -or $version.FileVersion -cne ($info.productVersion + '.0') -or $version.ProductName -cne $info.appName) { throw 'BUILD_INFO_PE_MISMATCH' }
    }
    return $info
}

function Assert-MediaNormalizerMacBuildInfo {
    param([Parameter(Mandatory)][string]$AppPath)
    $resources = Join-Path $AppPath 'Contents/Resources'
    $info = Assert-MediaNormalizerPackageBuildInfo -PackageRoot $resources -Runtime osx-arm64
    [xml]$plist = [IO.File]::ReadAllText((Join-Path $AppPath 'Contents/Info.plist'))
    $values = @{}
    $nodes = @($plist.SelectSingleNode('/plist/dict').ChildNodes)
    for ($i=0; $i -lt $nodes.Count - 1; $i++) { if ($nodes[$i].Name -eq 'key') { $values[$nodes[$i].InnerText] = $nodes[$i+1].InnerText } }
    if ($values.CFBundleShortVersionString -cne $info.productVersion -or $values.CFBundleVersion -cne $info.productVersion -or $values.CFBundleName -cne $info.appName) { throw 'BUILD_INFO_PLIST_MISMATCH' }
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $resources 'gui/MediaNormalizer.Gui.dll')))
    $stream = $assembly.GetManifestResourceStream('MediaNormalizer.BuildInfo')
    if ($null -eq $stream) { throw 'BUILD_INFO_RESOURCE_MISSING' }
    $memory = [IO.MemoryStream]::new()
    try { $stream.CopyTo($memory); $embedded = $memory.ToArray() } finally { $stream.Dispose(); $memory.Dispose() }
    $diskBytes = [IO.File]::ReadAllBytes((Join-Path $resources 'build-info.json'))
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($embedded)) -cne
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($diskBytes))) { throw 'BUILD_INFO_RESOURCE_MISMATCH' }
    $attributes = $assembly.GetCustomAttributesData()
    $product = @($attributes | Where-Object AttributeType -EQ ([Reflection.AssemblyProductAttribute]))[0].ConstructorArguments[0].Value
    $version = @($attributes | Where-Object AttributeType -EQ ([Reflection.AssemblyInformationalVersionAttribute]))[0].ConstructorArguments[0].Value
    if ($version -cne $info.productVersion -or $product -cne $info.appName -or $assembly.GetName().Version.ToString() -cne ($info.productVersion + '.0')) { throw 'BUILD_INFO_ASSEMBLY_MISMATCH' }
    return $info
}
