[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'Zip')][string]$ZipPath,
    [Parameter(Mandatory, ParameterSetName = 'MacApp')][string]$AppPath,
    [Parameter(ParameterSetName = 'Zip')][switch]$MacArchive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSCmdlet.ParameterSetName -eq 'MacApp') {
    & (Join-Path $PSScriptRoot 'test-macos-artifact.ps1') -AppPath $AppPath -PrivacyOnly
    return
}

. (Join-Path $PSScriptRoot 'shared\secret-patterns.ps1')

$zipFull = [IO.Path]::GetFullPath($ZipPath)
if (Test-SecretFilePath -FilePath $zipFull) {
    throw 'MEDIA_NORMALIZER_SECRET_PATH_REJECTED'
}
if (-not (Test-Path -LiteralPath $zipFull -PathType Leaf) -or
    [IO.Path]::GetExtension($zipFull) -ine '.zip') {
    throw 'A portable ZIP file is required for privacy inspection.'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
. (Join-Path $PSScriptRoot 'shared/artifact-privacy-stream.ps1')

$patterns = [Collections.Generic.List[byte[]]]::new()
foreach ($root in @('C:\Users\', 'C:/Users/', 'c:\users\', 'c:/users/')) {
    $patterns.Add([Text.Encoding]::UTF8.GetBytes($root))
    $patterns.Add([Text.Encoding]::Unicode.GetBytes($root))
}
$patternArray = [byte[][]]$patterns.ToArray()

if ($MacArchive) {
    & (Join-Path $PSScriptRoot 'test-macos-archive-privacy.ps1') -ZipPath $zipFull
    return
}
$archive = [IO.Compression.ZipFile]::OpenRead($zipFull)
$entryCount = 0
try {
    foreach ($entry in $archive.Entries) {
        if ([string]::IsNullOrEmpty($entry.Name)) { continue }
        $entryCount++
        $normalizedName = $entry.FullName.Replace('\', '/')
        if ($normalizedName -match '(?i)(^|/)__pycache__(/|$)' -or
            $normalizedName.EndsWith('.pyc', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Portable ZIP contains excluded Python bytecode: $normalizedName"
        }

        $stream = $entry.Open()
        try {
            if ([MediaNormalizerZipPrivacyScanner]::ContainsAny($stream, $patternArray)) {
                throw "Portable ZIP contains a local Windows user path candidate: $normalizedName"
            }
        }
        finally {
            $stream.Dispose()
        }
    }
}
finally {
    $archive.Dispose()
}

[pscustomobject]@{
    ZipFile = [IO.Path]::GetFileName($zipFull)
    EntriesScanned = $entryCount
    BytecodeEntries = 0
    LocalWindowsUserPathCandidates = 0
    Status = 'OK'
}
