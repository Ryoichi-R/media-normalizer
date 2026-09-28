#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ZipPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'shared/secret-patterns.ps1')
. (Join-Path $PSScriptRoot 'shared/artifact-privacy-stream.ps1')
$allowed = @{}
foreach ($entry in (Get-Content (Join-Path $PSScriptRoot 'macos-privacy-baseline.json') -Raw | ConvertFrom-Json).files) { $allowed[$entry.path] = $entry }
$patterns = [Collections.Generic.List[byte[]]]::new()
foreach ($prefix in @('/Users/','/private/var/folders/','~/Library/','C:\Users\','C:/Users/','c:\users\','c:/users/')) {
    $patterns.Add([Text.Encoding]::UTF8.GetBytes($prefix)); $patterns.Add([Text.Encoding]::Unicode.GetBytes($prefix))
}
$localPatterns = [Collections.Generic.List[byte[]]]::new()
$userHome = [Environment]::GetFolderPath('UserProfile')
if ($userHome) { $localPatterns.Add([Text.Encoding]::UTF8.GetBytes($userHome + '/')); $localPatterns.Add([Text.Encoding]::Unicode.GetBytes($userHome + '/')) }
$archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($ZipPath))
$count = 0; $roots = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
try {
    foreach ($entry in $archive.Entries) {
        $name = $entry.FullName
        if ($name.StartsWith('/') -or $name.Contains('\') -or $name.Split('/') -contains '..' -or -not $names.Add($name)) { throw "Unsafe archive path: $name" }
        if ($name -notmatch '^([^/]+\.app)/(.*)$') { throw "Archive entry outside app: $name" }
        $appRootName = $Matches[1]; $null = $roots.Add($appRootName); $relative = $Matches[2]
        if ($roots.Count -ne 1) { throw 'Archive must contain one app.' }
        if (-not $entry.Name) { continue }
        if ($relative -match '(?i)(^|/)(__pycache__|\.git|\.env)(/|$)|\.pyc$|(^|/)(settings|presets\.user)\.json$|\.log$') { throw "Excluded artifact: $relative" }
        $count++
        $exception = $allowed[$relative]
        $stream = $entry.Open()
        try { $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) } finally { $stream.Dispose() }
        $hashMatches = $null -ne $exception -and $hash -ieq $exception.sha256
        if ((Test-SecretFilePath $relative) -and -not ($hashMatches -and $exception.allowSecretLikeName)) { throw "Secret-like file rejected: $relative" }
        $stream = $entry.Open()
        try { if ([MediaNormalizerZipPrivacyScanner]::ContainsAny($stream,[byte[][]]$localPatterns.ToArray())) { throw "Local user path rejected: $relative" } } finally { $stream.Dispose() }
        $stream = $entry.Open()
        try { if ([MediaNormalizerZipPrivacyScanner]::ContainsAny($stream,[byte[][]]$patterns.ToArray()) -and -not $hashMatches) { throw "Unreviewed path candidate: $relative" } } finally { $stream.Dispose() }
        # Unix symbolic links are stored as their target bytes. Reject escapes without extracting.
        if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
            $reader = [IO.StreamReader]::new($entry.Open())
            try { $target = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $virtualRoot = [IO.Path]::GetFullPath('/archive/' + $appRootName)
            $resolved = [IO.Path]::GetFullPath([IO.Path]::Combine('/archive', [IO.Path]::GetDirectoryName($name), $target))
            if (-not $resolved.StartsWith($virtualRoot + '/', [StringComparison]::Ordinal)) { throw "Archive symlink escapes app: $name" }
        }
    }
    if ($count -eq 0) { throw 'Archive is empty.' }
} finally { $archive.Dispose() }
[pscustomobject]@{Status='OK'; EntriesScanned=$count; LocalUserPaths=0; SecretFiles=0}
