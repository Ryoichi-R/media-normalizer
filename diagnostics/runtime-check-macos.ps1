#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [switch]$Quiet
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    if (-not $IsMacOS -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64') {
        throw 'This runtime requires macOS on Apple Silicon.'
    }
    $root = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('/')
    $manifest = Get-Content -LiteralPath (Join-Path $root 'dependency-manifest.json') -Raw |
        ConvertFrom-Json -AsHashtable
    if ($manifest.schemaVersion -ne 1 -or $manifest.runtime -cne 'osx-arm64') {
        throw 'Unsupported runtime manifest.'
    }
    $required = [ordered]@{
        FFmpeg = 'ffmpeg/bin/ffmpeg'
        ffprobe = 'ffmpeg/bin/ffprobe'
        Python = 'python/bin/python3'
        PowerShell = 'powershell/pwsh'
    }
    if (@($manifest.criticalFiles).Count -lt $required.Count) { throw 'Incomplete critical file manifest.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $manifest.criticalFiles) {
        $relative = [string]$entry.path
        if ([string]::IsNullOrWhiteSpace($relative) -or $relative.StartsWith('/') -or
            $relative.Contains('\') -or @($relative.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count) {
            throw 'Invalid critical file path.'
        }
        if (-not $seen.Add($relative)) { throw "Duplicate critical file: $relative" }
        $path = Join-Path $root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing runtime file: $relative" }
        # Resolve each symlink component before hashing or executing any runtime binary.
        $cursor = $root
        foreach ($segment in $relative.Split('/')) {
            $cursor = Join-Path $cursor $segment
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.LinkType) {
                $target = $item.ResolveLinkTarget($true)
                if ($null -eq $target -or -not $target.FullName.StartsWith($root + '/', [StringComparison]::Ordinal)) {
                    throw "Runtime link escapes its root: $relative"
                }
                $cursor = $target.FullName
            }
        }
        if ([string]$entry.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $entry.sha256) {
            throw "Runtime SHA-256 mismatch: $relative"
        }
    }
    foreach ($entry in $required.GetEnumerator()) {
        $matches = @($manifest.criticalFiles | Where-Object { $_.name -ceq $entry.Key -and $_.path -ceq $entry.Value })
        if ($matches.Count -ne 1) { throw "Missing required manifest entry: $($entry.Key)" }
        $path = Join-Path $root $entry.Value
        $header = [byte[]]::new(8)
        $stream = [IO.File]::OpenRead($path)
        try { $count = $stream.Read($header, 0, 8) } finally { $stream.Dispose() }
        if ($count -ne 8 -or [BitConverter]::ToString($header, 0, 4) -cne 'CF-FA-ED-FE' -or
            [BitConverter]::ToUInt32($header, 4) -ne 0x0100000c) { throw "Expected arm64 Mach-O: $($entry.Key)" }
        & /bin/test -x $path
        if ($LASTEXITCODE -ne 0) { throw "Runtime file is not executable: $($entry.Key)" }
    }
    # Everything above must pass before any bundled executable is invoked.
    $env:PYTHONHOME = Join-Path $root 'python'
    $env:PYTHONPATH = $null
    $env:PYTHONNOUSERSITE = '1'
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $env:FFMPEG_PATH = Join-Path $root $required.FFmpeg
    $env:FFPROBE_PATH = Join-Path $root $required.ffprobe
    $env:MEDIA_NORMALIZER_PYTHON = Join-Path $root $required.Python
    $env:MEDIA_NORMALIZER_RUNTIME_ROOT = $root
    $env:PATH = (Join-Path $root 'ffmpeg/bin') + ':' + (Join-Path $root 'python/bin') + ':' + $env:PATH
    function Invoke-CheckedRuntime {
        param([string]$RelativePath, [string[]]$Arguments, [string]$Expected)
        $output = & (Join-Path $root $RelativePath) @Arguments 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $output -notmatch $Expected) { throw "Runtime check failed: $RelativePath" }
        return $output
    }
    foreach ($pair in @(@('FFmpeg','ffmpeg'), @('ffprobe','ffmpeg'), @('Python','python'), @('PowerShell','powershell'))) {
        $version = [string]$manifest[$pair[1]].version
        if ([string]::IsNullOrWhiteSpace($version)) { throw "Missing version: $($pair[1])" }
        $arguments = if ($pair[0] -in @('FFmpeg','ffprobe')) { @('-version') } else { @('--version') }
        $null = Invoke-CheckedRuntime $required[$pair[0]] $arguments ('(?<![0-9.])' + [regex]::Escape($version) + '(?![0-9.])')
    }
    $normalizeVersion = [string]$manifest.ffmpegNormalize.version
    if ([string]::IsNullOrWhiteSpace($normalizeVersion)) { throw 'Missing ffmpeg-normalize version.' }
    $null = Invoke-CheckedRuntime $required.Python @('-m','ffmpeg_normalize','--version') ([regex]::Escape($normalizeVersion))
    $null = Invoke-CheckedRuntime $required.FFmpeg @('-hide_banner','-filters') '\bloudnorm\b'
    $encoders = Invoke-CheckedRuntime $required.FFmpeg @('-hide_banner','-encoders') 'Encoders:'
    foreach ($encoder in @('aac','flac','libmp3lame','libopus','libvorbis','libx264','pcm_s24le')) {
        if ($encoders -notmatch ('(?m)^\s*\S+\s+' + [regex]::Escape($encoder) + '\s')) { throw "Missing encoder: $encoder" }
    }
    $tempPath = [IO.Path]::GetTempPath()
    $probe = Join-Path $tempPath ('mn-runtime-check-' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($probe, 'ok') } finally { if ([IO.File]::Exists($probe)) { [IO.File]::Delete($probe) } }
    $drive = [IO.DriveInfo]::GetDrives() | Where-Object {
        $tempPath.StartsWith($_.Name, [StringComparison]::Ordinal)
    } | Sort-Object { $_.Name.Length } -Descending | Select-Object -First 1
    if ($null -eq $drive -or $drive.AvailableFreeSpace -lt 1GB) { throw 'Temporary volume needs at least 1 GiB free.' }
    if (-not $Quiet) { Write-Output 'OK: macOS arm64 runtime hashes, architectures, versions, filter, encoders and temporary storage.' }
    exit 0
} catch {
    [Console]::Error.WriteLine('Runtime check failed: ' + $_.Exception.Message)
    exit 1
}
