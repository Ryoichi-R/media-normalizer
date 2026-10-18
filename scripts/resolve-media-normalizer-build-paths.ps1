Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'shared\secret-patterns.ps1')

function ConvertTo-CanonicalDirectoryPath {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-SecretFilePath -FilePath $Path) {
        throw "MEDIA_NORMALIZER_SECRET_PATH_REJECTED: $Path"
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    $filesystemRoot = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath -ieq $filesystemRoot) {
        return $filesystemRoot
    }

    return $fullPath.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-MediaNormalizerOutputParent {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = ConvertTo-CanonicalDirectoryPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "OutputRoot must be an existing directory: $resolved"
    }
    if ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "OutputRoot cannot be a symbolic link or junction: $resolved"
    }

    return $resolved
}

function Resolve-MediaNormalizerBuildPaths {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [AllowNull()][AllowEmptyString()][string]$OutputRoot
    )

    $resolvedProjectRoot = ConvertTo-CanonicalDirectoryPath -Path $ProjectRoot
    $requestedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $resolvedProjectRoot
    }
    elseif ([IO.Path]::IsPathFullyQualified($OutputRoot.Trim())) {
        $OutputRoot.Trim()
    }
    else {
        Join-Path $resolvedProjectRoot $OutputRoot.Trim()
    }

    $resolvedOutputRoot = ConvertTo-CanonicalDirectoryPath -Path $requestedOutputRoot
    $usesExternalRoot = $resolvedOutputRoot -ine $resolvedProjectRoot
    if ($usesExternalRoot -and (Split-Path -Leaf $resolvedOutputRoot) -ieq 'MediaNormalizerBuilds') {
        throw "Specify the parent folder in which MediaNormalizerBuilds will be created, not MediaNormalizerBuilds itself: $resolvedOutputRoot"
    }

    $projectPrefix = $resolvedProjectRoot + [IO.Path]::DirectorySeparatorChar
    if ($usesExternalRoot -and $resolvedOutputRoot.StartsWith(
            $projectPrefix,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "OutputRoot cannot be inside the Media Normalizer project: $resolvedOutputRoot"
    }

    $managedRoot = if ($usesExternalRoot) {
        Join-Path $resolvedOutputRoot 'MediaNormalizerBuilds'
    }
    else {
        Join-Path $resolvedProjectRoot 'artifacts'
    }

    [pscustomobject]@{
        OutputParent     = $resolvedOutputRoot
        ManagedRoot      = ConvertTo-CanonicalDirectoryPath -Path $managedRoot
        UsesExternalRoot = $usesExternalRoot
    }
}
