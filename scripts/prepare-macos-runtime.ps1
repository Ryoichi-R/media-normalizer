# Internal macOS branch of prepare-portable-runtime.ps1; shared download/ZIP
# helpers and the parsed pinned dependency manifest come from that entrypoint.
if (-not $IsMacOS -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64') {
    throw 'Preparing osx-arm64 requires an Apple Silicon Mac (including local signing).'
}
$runtimeRoot = Join-Path $packageRootFull 'runtime'
if (Test-Path -LiteralPath $runtimeRoot) { throw "Refusing to overwrite runtime: $runtimeRoot" }
$null = New-Item -ItemType Directory -Path $runtimeRoot
$extractRoot = Join-Path $runtimeRoot '.extract'
$null = New-Item -ItemType Directory -Path $extractRoot

function Get-MacPinnedArchive {
    param($Pin)
    Get-VerifiedArtifact -Url $Pin.url -FileName $Pin.archiveName -Sha256 $Pin.sha256 `
        -CacheDirectory $cacheRootFull -DownloadTimeoutSeconds $DownloadTimeoutSeconds `
        -DownloadRetryCount $DownloadRetryCount
}
function Expand-MacPinnedTar {
    param([string]$Archive, [string]$Destination)
    $null = New-Item -ItemType Directory -Path $Destination -Force
    $entries = & /usr/bin/tar -tzf $Archive
    if ($LASTEXITCODE -ne 0) { throw 'Cannot list pinned tar archive.' }
    foreach ($entry in $entries) {
        if ($entry.StartsWith('/') -or $entry.Split('/') -contains '..') { throw 'Unsafe tar entry.' }
    }
    & /usr/bin/tar -xzf $Archive -C $Destination
    if ($LASTEXITCODE -ne 0) { throw 'Cannot extract pinned tar archive.' }
}
function Test-MacMachO {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $bytes = [byte[]]::new(4)
        if ($stream.Read($bytes,0,4) -ne 4) { return $false }
        return [BitConverter]::ToString($bytes) -in @('CF-FA-ED-FE','CE-FA-ED-FE','FE-ED-FA-CF','FE-ED-FA-CE','CA-FE-BA-BE','BE-BA-FE-CA')
    } finally { $stream.Dispose() }
}
$ffmpegPin = $dependencies.ffmpeg.runtimes.'osx-arm64'
$pythonPin = $dependencies.python.runtimes.'osx-arm64'
$pwshPin = $dependencies.powershell.runtimes.'osx-arm64'
$probePin = @{url=$ffmpegPin.ffprobeUrl; archiveName=$ffmpegPin.ffprobeArchiveName; sha256=$ffmpegPin.ffprobeSha256}
$archives = [ordered]@{}
foreach ($entry in @(@('ffmpeg',$ffmpegPin),@('ffprobe',$probePin),@('python',$pythonPin),@('powershell',$pwshPin))) {
    $archives[$entry[0]] = Get-MacPinnedArchive $entry[1]
}
$bin = Join-Path $runtimeRoot 'ffmpeg/bin'
$null = New-Item -ItemType Directory -Path $bin -Force
foreach ($name in @('ffmpeg','ffprobe')) {
    $destination = Join-Path $extractRoot $name
    Expand-VerifiedZip -ArchivePath $archives[$name] -Destination $destination
    $matches = @(Get-ChildItem -LiteralPath $destination -Recurse -File | Where-Object { $_.Name -ceq $name })
    if ($matches.Count -ne 1) { throw "Expected one $name executable in pinned ZIP." }
    Copy-Item -LiteralPath $matches[0].FullName -Destination (Join-Path $bin $name)
    Copy-LicenseFiles -SourceRoot (Split-Path $matches[0].FullName) -Destination (Join-Path $runtimeRoot "licenses/$name")
}
Expand-MacPinnedTar -Archive $archives.python -Destination $extractRoot
if (-not (Test-Path (Join-Path $extractRoot 'python/bin/python3'))) { throw 'Pinned Python layout differs.' }
Move-Item -LiteralPath (Join-Path $extractRoot 'python') -Destination (Join-Path $runtimeRoot 'python')
Expand-MacPinnedTar -Archive $archives.powershell -Destination (Join-Path $runtimeRoot 'powershell')
$pythonMinor = ([version]$pythonPin.version).ToString(2)
$sitePackages = Join-Path $runtimeRoot "python/lib/python$pythonMinor/site-packages"
foreach ($package in $dependencies.pythonPackages) {
    $wheel = Get-MacPinnedArchive $package
    if ($package.archiveName -notmatch '-(py3|py2\.py3)-none-any\.whl$') { throw 'Expected a pure Python wheel.' }
    Expand-VerifiedZip -ArchivePath $wheel -Destination $sitePackages
}
foreach ($relative in @('powershell/LICENSE.txt','powershell/ThirdPartyNotices.txt',"python/lib/python$pythonMinor/LICENSE.txt")) {
    if (-not (Test-Path -LiteralPath (Join-Path $runtimeRoot $relative))) { throw "Missing runtime notice: $relative" }
}
# Only newly generated runtime files are pruned; never modify the input cache/runtime.
$generatedRuntime = $runtimeRoot
Get-ChildItem -LiteralPath $generatedRuntime -Recurse -File -Filter '*.pyc' | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
Get-ChildItem -LiteralPath $generatedRuntime -Recurse -Directory -Filter '__pycache__' | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
    if (@(Get-ChildItem -LiteralPath $_.FullName -Force).Count -eq 0) { Remove-Item -LiteralPath $_.FullName -Force }
}
# Sign real files only. Symlink targets remain in this newly generated runtime.
$machFiles = @(Get-ChildItem -LiteralPath $runtimeRoot -Recurse -File | Where-Object {
    -not $_.LinkType -and -not $_.FullName.StartsWith($extractRoot + '/') -and (Test-MacMachO $_.FullName)
} | Sort-Object { $_.FullName.Length } -Descending)
foreach ($file in $machFiles) {
    & /bin/chmod u+x $file.FullName
    if ($LASTEXITCODE -ne 0) { throw 'Cannot set runtime execution permission.' }
    & /usr/bin/codesign --force --sign - --timestamp=none $file.FullName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Cannot sign runtime file: $($file.Name)" }
    & /usr/bin/codesign --verify --strict $file.FullName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Runtime signature verification failed: $($file.Name)" }
}
$required = [ordered]@{FFmpeg='ffmpeg/bin/ffmpeg'; ffprobe='ffmpeg/bin/ffprobe'; Python='python/bin/python3'; PowerShell='powershell/pwsh'}
$critical = [Collections.Generic.List[object]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($entry in $required.GetEnumerator()) {
    $path = Join-Path $runtimeRoot $entry.Value
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing $($entry.Key)." }
    $critical.Add(@{name=$entry.Key; path=$entry.Value; sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()})
    $null = $seen.Add($entry.Value)
}
foreach ($file in $machFiles) {
    $relative = [IO.Path]::GetRelativePath($runtimeRoot,$file.FullName)
    if ($seen.Add($relative)) { $critical.Add(@{name=$relative; path=$relative; sha256=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()}) }
}
$manifest = [ordered]@{
    schemaVersion=1; runtime='osx-arm64'; signature='ad-hoc'
    ffmpeg=@{version=$ffmpegPin.version; license=$ffmpegPin.license; binarySha256=$ffmpegPin.sha256; ffprobeArchiveSha256=$ffmpegPin.ffprobeSha256}
    python=@{version=$pythonPin.version; license=$pythonPin.license; binarySha256=$pythonPin.sha256}
    powershell=@{version=$pwshPin.version; license=$pwshPin.license; binarySha256=$pwshPin.sha256}
    ffmpegNormalize=@{version=$dependencies.pythonPackages[0].version; license=$dependencies.pythonPackages[0].license}
    pythonPackages=@($dependencies.pythonPackages | Select-Object name,version,license,sha256)
    criticalFiles=@($critical.ToArray())
}
# Hashes above describe the signed bytes, independently of the archive pins.
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runtimeRoot 'dependency-manifest.json') -Encoding utf8NoBOM
# .extract contains only this invocation's pinned archive staging files.
Remove-Item -LiteralPath $extractRoot -Recurse -Force
$checker = Join-Path (Split-Path $PSScriptRoot -Parent) 'diagnostics/runtime-check.ps1'
& (Join-Path $runtimeRoot 'powershell/pwsh') -NoProfile -File $checker -RuntimeRoot $runtimeRoot
if ($LASTEXITCODE -ne 0) { throw 'Prepared macOS runtime failed its diagnostic.' }
Write-Host 'Portable runtime prepared and validated: osx-arm64'
