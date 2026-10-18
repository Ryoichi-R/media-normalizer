#Requires -Version 7.4

[CmdletBinding()]
param([Parameter(Mandatory)][string]$CorpusDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($CorpusDirectory)
$manifestPath = Join-Path $root 'fixture-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Comparison fixture manifest was not found: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
if ($manifest.schemaVersion -ne 1 -or $manifest.fixtureSetId -ne 'media-normalizer-p0-8-sample-v1') {
    throw 'Comparison fixture manifest has an unsupported schema or fixture set ID.'
}

$expectedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($fixture in @($manifest.fixtures)) {
    $relativePath = [string]$fixture.path
    if ([string]::IsNullOrWhiteSpace($relativePath) -or
        [IO.Path]::IsPathRooted($relativePath) -or
        $relativePath -ne [IO.Path]::GetFileName($relativePath)) {
        throw "Unsafe fixture path in manifest: $relativePath"
    }
    if (-not $expectedNames.Add($relativePath)) {
        throw "Duplicate fixture path in manifest: $relativePath"
    }

    $path = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Comparison fixture is missing: $relativePath"
    }
    $item = Get-Item -LiteralPath $path
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($item.Length -ne [long]$fixture.byteLength -or $hash -ne [string]$fixture.sha256) {
        throw "Comparison fixture hash/size mismatch: $relativePath"
    }
}

$actualNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse -Force) {
    $relativePath = [IO.Path]::GetRelativePath($root, $file.FullName).Replace([IO.Path]::DirectorySeparatorChar, '/')
    if ($relativePath -ne 'fixture-manifest.json') {
        [void]$actualNames.Add($relativePath)
    }
}

if (-not $actualNames.SetEquals($expectedNames)) {
    $unexpected = @($actualNames | Where-Object { -not $expectedNames.Contains($_) })
    $missing = @($expectedNames | Where-Object { -not $actualNames.Contains($_) })
    throw "Comparison fixture set has unexpected files [$($unexpected -join ', ')] or missing files [$($missing -join ', ')]."
}

Write-Output "Comparison fixture set verified: $($expectedNames.Count) files; all sizes and SHA-256 values match."
