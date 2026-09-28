#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$AppPath, [switch]$PrivacyOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'shared/secret-patterns.ps1')
. (Join-Path $PSScriptRoot 'shared/artifact-privacy-stream.ps1')
$app = [IO.Path]::GetFullPath($AppPath).TrimEnd('/')
if (-not $app.EndsWith('.app',[StringComparison]::Ordinal) -or -not (Test-Path -LiteralPath $app -PathType Container)) { throw 'A macOS .app directory is required.' }
if (-not $PrivacyOnly) {
    foreach ($relative in (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'media-normalizer-required-files.psd1')).MacAppRequiredRelativePaths) {
        if (-not (Test-Path -LiteralPath (Join-Path $app $relative) -PathType Leaf)) { throw "Missing required app file: $relative" }
    }
    & /usr/bin/codesign --verify --deep --strict $app
    if ($LASTEXITCODE -ne 0) { throw 'App signature failed.' }
    & /bin/sh (Join-Path $app 'Contents/Resources/runtime-check.sh')
    if ($LASTEXITCODE -ne 0) { throw 'App runtime verification failed.' }
}
$baseline = Get-Content (Join-Path $PSScriptRoot 'macos-privacy-baseline.json') -Raw | ConvertFrom-Json
$allowed = @{}
foreach ($entry in $baseline.files) { $allowed[$entry.path] = $entry }
$patterns = [Collections.Generic.List[byte[]]]::new()
foreach ($prefix in @('/Users/','/private/var/folders/','~/Library/','C:\Users\','C:/Users/','c:\users\','c:/users/')) {
    $patterns.Add([Text.Encoding]::UTF8.GetBytes($prefix))
    $patterns.Add([Text.Encoding]::Unicode.GetBytes($prefix))
}
$localPatterns = [Collections.Generic.List[byte[]]]::new()
$userHome = [Environment]::GetFolderPath('UserProfile')
if (-not [string]::IsNullOrWhiteSpace($userHome)) {
    $localPatterns.Add([Text.Encoding]::UTF8.GetBytes($userHome + '/'))
    $localPatterns.Add([Text.Encoding]::Unicode.GetBytes($userHome + '/'))
}
foreach ($link in Get-ChildItem -LiteralPath $app -Recurse -Force | Where-Object LinkType) {
    $target = $link.ResolveLinkTarget($true)
    if ($null -eq $target -or -not $target.FullName.StartsWith($app + '/', [StringComparison]::Ordinal)) { throw "App symlink escapes bundle: $([IO.Path]::GetRelativePath($app,$link.FullName))" }
}
$files = 0; $upstreamExceptions = 0
foreach ($file in Get-ChildItem -LiteralPath $app -Recurse -File -Force) {
    $relative = [IO.Path]::GetRelativePath($app,$file.FullName)
    if ($file.LinkType) {
        $target = $file.ResolveLinkTarget($true)
        if ($null -eq $target -or -not $target.FullName.StartsWith($app + '/',[StringComparison]::Ordinal)) { throw "App symlink escapes bundle: $relative" }
        continue
    }
    if ($relative -match '(?i)(^|/)(__pycache__|\.git|\.env)(/|$)|\.pyc$|(^|/)(settings|presets\.user)\.json$|\.log$') { throw "Excluded artifact: $relative" }
    $files++
    $exception = $allowed[$relative]
    $hashMatches = $null -ne $exception -and (Get-FileHash -LiteralPath $file.FullName).Hash -ieq $exception.sha256
    if ((Test-SecretFilePath $relative) -and -not ($hashMatches -and $exception.allowSecretLikeName)) { throw "Secret-like file rejected: $relative" }
    $stream = [IO.File]::OpenRead($file.FullName)
    try {
        if ([MediaNormalizerZipPrivacyScanner]::ContainsAny($stream,[byte[][]]$localPatterns.ToArray())) { throw "Local user path rejected: $relative" }
        $stream.Position = 0
        if ([MediaNormalizerZipPrivacyScanner]::ContainsAny($stream,[byte[][]]$patterns.ToArray())) {
            if (-not $hashMatches) { throw "Unreviewed path candidate: $relative" }
            $upstreamExceptions++
        }
    } finally { $stream.Dispose() }
}
[pscustomobject]@{Status='OK'; FilesScanned=$files; HashBoundUpstreamPathExceptions=$upstreamExceptions; LocalUserPaths=0; SecretFiles=0}
