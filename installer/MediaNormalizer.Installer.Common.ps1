Set-StrictMode -Version 2

function Test-SafeRelativePath {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name) -or
        [IO.Path]::IsPathRooted($Name) -or
        $Name.Contains(':') -or
        $Name -match '(^|[\\/])\.\.?([\\/]|$)') {
        return $false
    }
    return $true
}

function Resolve-SafeChildPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $normalized = $RelativePath.Replace('/', '\')
    if (-not (Test-SafeRelativePath $normalized)) {
        throw "危険な相対パスです: $RelativePath"
    }

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull $normalized))
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "ルート外を指すパスです: $RelativePath"
    }
    return $candidate
}

function Assert-NoReparsePointInPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals($pathFull, $rootFull, [StringComparison]::OrdinalIgnoreCase) -and
        -not $pathFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "reparse point検証対象がルート外です: $pathFull"
    }

    $current = $rootFull
    if (Test-Path -LiteralPath $current) {
        if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "reparse pointは使用できません: $current"
        }
    }
    $relative = $pathFull.Substring($rootFull.Length).TrimStart('\')
    foreach ($segment in @($relative -split '\\' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { break }
        if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "reparse pointは使用できません: $current"
        }
    }
}

function ConvertTo-ValidatedManagedFileMap {
    param(
        [Parameter(Mandatory)]$ManagedFiles,
        [Parameter(Mandatory)][string]$Root
    )

    $map = @{}
    foreach ($file in @($ManagedFiles)) {
        if ($null -eq $file -or -not $file.PSObject.Properties['name']) {
            throw 'managedFilesにnameがない項目があります。'
        }
        $name = ([string]$file.name).Replace('/', '\')
        $path = Resolve-SafeChildPath -Root $Root -RelativePath $name
        Assert-NoReparsePointInPath -Root $Root -Path $path
        $key = $name.ToLowerInvariant()
        if ($map.ContainsKey($key)) {
            throw "managedFilesに重複パスがあります: $name"
        }
        $map[$key] = [pscustomobject]@{
            Name  = $name
            Path  = $path
            Entry = $file
        }
    }
    return $map
}
