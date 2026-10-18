[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PublishDirectory,
    [Parameter(Mandatory)][string]$OutputAppPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsMacOS) {
    throw 'The macOS PoC bundle layout can only be generated on macOS.'
}

$publishRoot = [IO.Path]::GetFullPath($PublishDirectory)
if (-not [IO.Directory]::Exists($publishRoot)) {
    throw "Publish directory does not exist: $publishRoot"
}

$outputPath = [IO.Path]::GetFullPath($OutputAppPath)
if (-not $outputPath.EndsWith('.app', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputAppPath must end in .app.'
}
if ([IO.Directory]::Exists($outputPath) -or [IO.File]::Exists($outputPath)) {
    throw "Refusing to overwrite an existing path: $outputPath"
}

$contentsPath = Join-Path $outputPath 'Contents'
$macOsPath = Join-Path $contentsPath 'MacOS'
$resourcesPath = Join-Path $contentsPath 'Resources'
[IO.Directory]::CreateDirectory($macOsPath) | Out-Null
[IO.Directory]::CreateDirectory($resourcesPath) | Out-Null

foreach ($item in Get-ChildItem -LiteralPath $publishRoot -Force) {
    if ($item.Extension -eq '.pdb') {
        continue
    }
    Copy-Item -LiteralPath $item.FullName -Destination $macOsPath -Recurse -Force
}

$executablePath = Join-Path $macOsPath 'MediaNormalizer.MacPoc'
if (-not [IO.File]::Exists($executablePath)) {
    throw "Published executable is missing: $executablePath"
}
$executeBits = [IO.UnixFileMode]::UserExecute -bor `
    [IO.UnixFileMode]::GroupExecute -bor `
    [IO.UnixFileMode]::OtherExecute
$currentMode = [IO.File]::GetUnixFileMode($executablePath)
[IO.File]::SetUnixFileMode($executablePath, $currentMode -bor $executeBits)

$plist = @'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>MediaNormalizer.MacPoc</string>
  <key>CFBundleIdentifier</key><string>org.example.medianormalizer.macpoc</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>MediaNormalizer.MacPoc</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>0.0.1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
'@
[IO.File]::WriteAllText(
    (Join-Path $contentsPath 'Info.plist'),
    $plist,
    [Text.UTF8Encoding]::new($false))

Write-Output $outputPath
