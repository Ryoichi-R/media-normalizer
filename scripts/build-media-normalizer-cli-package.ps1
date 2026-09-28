#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][string]$CacheRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsMacOS -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64') {
    throw 'The macOS CLI package must be built on Apple Silicon.'
}
$source = Split-Path -Parent $PSScriptRoot
$output = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $output) { throw 'OutputRoot must be a new directory.' }
$null = New-Item -ItemType Directory -Path $output
foreach ($relative in @('media-normalizer.ps1','media-normalizer.sh','runtime-env.sh','runtime-check.sh','diagnose.sh',
        'README.md','LICENSE','THIRD-PARTY-NOTICES.md','assets/presets.json',
        'docs/MACOS-PORT.md','docs/PORTABLE-DISTRIBUTION.md',
        'diagnostics/runtime-check.ps1','diagnostics/runtime-check-macos.ps1','diagnostics/diagnose.ps1')) {
    $destination = Join-Path $output $relative
    $null = New-Item -ItemType Directory -Path (Split-Path $destination) -Force
    Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $destination
}
$null = New-Item -ItemType Directory -Path (Join-Path $output 'lib')
Get-ChildItem -LiteralPath (Join-Path $source 'lib') -File -Filter '*.psm1' | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $output 'lib')
}
foreach ($name in @('media-normalizer.sh','runtime-env.sh','runtime-check.sh','diagnose.sh')) {
    & /bin/chmod +x (Join-Path $output $name)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot set shell entrypoint permissions.' }
}
& (Join-Path $PSScriptRoot 'prepare-portable-runtime.ps1') -Runtime osx-arm64 -PackageRoot $output -CacheRoot $CacheRoot
& /bin/sh (Join-Path $output 'runtime-check.sh')
if ($LASTEXITCODE -ne 0) { throw 'The completed CLI package failed runtime validation.' }
Write-Output "macOS CLI package: $output"
