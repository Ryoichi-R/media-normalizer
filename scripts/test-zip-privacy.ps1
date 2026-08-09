[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ZipPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
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
if ($null -eq ('MediaNormalizerZipPrivacyScanner' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;

public static class MediaNormalizerZipPrivacyScanner
{
    public static bool ContainsAny(Stream stream, byte[][] patterns)
    {
        if (patterns == null || patterns.Length == 0) return false;
        var maximumPatternLength = 0;
        foreach (var pattern in patterns)
        {
            if (pattern != null && pattern.Length > maximumPatternLength)
                maximumPatternLength = pattern.Length;
        }
        if (maximumPatternLength == 0) return false;

        const int chunkLength = 65536;
        var buffer = new byte[chunkLength + maximumPatternLength - 1];
        var carry = 0;
        while (true)
        {
            var read = stream.Read(buffer, carry, chunkLength);
            if (read == 0) return false;
            var available = carry + read;
            var haystack = new ReadOnlySpan<byte>(buffer, 0, available);
            foreach (var pattern in patterns)
            {
                if (pattern != null && pattern.Length > 0 && haystack.IndexOf(pattern) >= 0)
                    return true;
            }

            carry = Math.Min(maximumPatternLength - 1, available);
            if (carry > 0)
                Buffer.BlockCopy(buffer, available - carry, buffer, 0, carry);
        }
    }
}
'@
}

$patterns = [Collections.Generic.List[byte[]]]::new()
foreach ($root in @('C:\Users\', 'C:/Users/', 'c:\users\', 'c:/users/')) {
    $patterns.Add([Text.Encoding]::UTF8.GetBytes($root))
    $patterns.Add([Text.Encoding]::Unicode.GetBytes($root))
}
$patternArray = [byte[][]]$patterns.ToArray()

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
