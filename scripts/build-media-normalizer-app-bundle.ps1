#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputAppPath,
    [Parameter(Mandatory)][string]$CacheRoot,
    [string]$PreparedRuntimeRoot,
    [switch]$RemoveQuarantine
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsMacOS -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64') { throw 'Build requires an Apple Silicon Mac.' }
$source = Split-Path $PSScriptRoot -Parent
$app = [IO.Path]::GetFullPath($OutputAppPath).TrimEnd('/')
if (-not $app.EndsWith('.app',[StringComparison]::Ordinal) -or (Test-Path -LiteralPath $app)) { throw 'OutputAppPath must be a new .app directory.' }
$mac = Join-Path $app 'Contents/MacOS'
$res = Join-Path $app 'Contents/Resources'
$gui = Join-Path $res 'gui'
$null = New-Item -ItemType Directory -Path $mac,$res,$gui -Force
$buildArtifacts = Join-Path ([IO.Path]::GetFullPath($CacheRoot)) 'gui-build'
$previousTelemetry = $env:AVALONIA_TELEMETRY_OPTOUT
try {
$env:AVALONIA_TELEMETRY_OPTOUT = '1'
& dotnet publish (Join-Path $source 'src/MediaNormalizer.Gui/MediaNormalizer.Gui.csproj') -c Release -r osx-arm64 --self-contained true --artifacts-path $buildArtifacts -o $gui -p:DebugType=None -p:DebugSymbols=false -p:RestoreLockedMode=true
if ($LASTEXITCODE -ne 0) { throw 'GUI publish failed.' }
} finally { $env:AVALONIA_TELEMETRY_OPTOUT = $previousTelemetry }
foreach ($relative in @('media-normalizer.ps1','media-normalizer.sh','runtime-env.sh','runtime-check.sh','diagnose.sh','LICENSE','THIRD-PARTY-NOTICES.md',
        'assets/presets.json','assets/MediaNormalizer.icns','scripts/mn-worker.ps1','diagnostics/runtime-check.ps1','diagnostics/runtime-check-macos.ps1','diagnostics/diagnose.ps1')) {
    $destination = Join-Path $res $(if ($relative -eq 'assets/MediaNormalizer.icns') { 'MediaNormalizer.icns' } else { $relative })
    $null = New-Item -ItemType Directory -Path (Split-Path $destination) -Force
    Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $destination
}
$null = New-Item -ItemType Directory -Path (Join-Path $res 'lib')
Get-ChildItem -LiteralPath (Join-Path $source 'lib') -File -Filter '*.psm1' | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $res 'lib') }
if ($PreparedRuntimeRoot) {
    $prepared = [IO.Path]::GetFullPath($PreparedRuntimeRoot)
    $manifest = Get-Content -LiteralPath (Join-Path $prepared 'dependency-manifest.json') -Raw | ConvertFrom-Json
    $pins = Get-Content -LiteralPath (Join-Path $source 'portable-dependencies.json') -Raw | ConvertFrom-Json
    if ($manifest.runtime -cne 'osx-arm64' -or $manifest.ffmpeg.binarySha256 -cne $pins.ffmpeg.runtimes.'osx-arm64'.sha256 -or
        $manifest.ffmpeg.ffprobeArchiveSha256 -cne $pins.ffmpeg.runtimes.'osx-arm64'.ffprobeSha256 -or
        $manifest.python.binarySha256 -cne $pins.python.runtimes.'osx-arm64'.sha256 -or
        $manifest.powershell.binarySha256 -cne $pins.powershell.runtimes.'osx-arm64'.sha256) { throw 'Prepared runtime does not match pinned archives.' }
    if (@($manifest.pythonPackages).Count -ne @($pins.pythonPackages).Count) { throw 'Prepared runtime package set does not match pins.' }
    foreach ($package in $pins.pythonPackages) {
        $actual = @($manifest.pythonPackages | Where-Object name -CEQ $package.name)
        if ($actual.Count -ne 1 -or $actual[0].version -cne $package.version -or $actual[0].sha256 -cne $package.sha256) { throw "Prepared runtime package differs from pins: $($package.name)" }
    }
    & /usr/bin/ditto $prepared (Join-Path $res 'runtime')
    if ($LASTEXITCODE -ne 0) { throw 'Runtime copy failed.' }
} else {
    & (Join-Path $PSScriptRoot 'prepare-portable-runtime.ps1') -Runtime osx-arm64 -PackageRoot $res -CacheRoot $CacheRoot
}
# Only newly generated runtime files are pruned; never modify the input cache/runtime.
$generatedRuntime = (Join-Path $res 'runtime')
Get-ChildItem -LiteralPath $generatedRuntime -Recurse -File -Filter '*.pyc' | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
Get-ChildItem -LiteralPath $generatedRuntime -Recurse -Directory -Filter '__pycache__' | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
    if (@(Get-ChildItem -LiteralPath $_.FullName -Force).Count -eq 0) { Remove-Item -LiteralPath $_.FullName -Force }
}
@'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>media-normalizer</string>
<key>CFBundleIdentifier</key><string>local.media-normalizer.app</string>
<key>CFBundleIconFile</key><string>MediaNormalizer.icns</string>
<key>CFBundleName</key><string>Media Normalizer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
'@ | Set-Content -LiteralPath (Join-Path $app 'Contents/Info.plist') -Encoding utf8NoBOM
# Sign only the published host native files; prepared runtime hashes already describe signed bytes.
foreach ($file in Get-ChildItem -LiteralPath $gui -Recurse -File | Sort-Object { $_.FullName.Length } -Descending) {
    $stream = [IO.File]::OpenRead($file.FullName)
    try { $header = [byte[]]::new(4); $count = $stream.Read($header,0,4) } finally { $stream.Dispose() }
    if ($count -eq 4 -and [BitConverter]::ToString($header) -in @('CF-FA-ED-FE','CE-FA-ED-FE','CA-FE-BA-BE','BE-BA-FE-CA')) {
        & /usr/bin/codesign --force --sign - --timestamp=none $file.FullName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Host signing failed: $($file.Name)" }
    }
}
@'
#!/bin/sh
set -eu
app_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../Resources" && pwd -P)
exec "$app_dir/gui/MediaNormalizer.Gui" "$@"
'@ | Set-Content -LiteralPath (Join-Path $mac 'media-normalizer') -Encoding utf8NoBOM
& /bin/chmod +x (Join-Path $mac 'media-normalizer')
if ($LASTEXITCODE -ne 0) { throw 'Launcher permission failed.' }
& /bin/sh (Join-Path $res 'runtime-check.sh')
if ($LASTEXITCODE -ne 0) { throw 'Bundled runtime diagnostic failed.' }
& /usr/bin/codesign --force --sign - --timestamp=none $app 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Outer app signing failed.' }
& /usr/bin/codesign --verify --deep --strict $app
if ($LASTEXITCODE -ne 0) { throw 'App signature verification failed.' }
if ($RemoveQuarantine) {
    # This explicit switch applies only to the new, normalized completed .app.
    & /usr/bin/xattr -dr com.apple.quarantine $app
    if ($LASTEXITCODE -ne 0) { throw 'Cannot remove quarantine from the completed app.' }
}
& (Join-Path $PSScriptRoot 'test-artifact-integrity.ps1') -AppPath $app | Out-Host
Write-Output $app
