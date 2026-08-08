Set-StrictMode -Version Latest

$script:MediaNormalizerSecretFilePatterns = @(
    '^\.env$'
    '^\.env\.'
    '^secrets\.'
    '\.key$'
    '\.pem$'
    '\.pfx$'
    '\.p12$'
    '^credentials\.'
)

function Test-SecretFilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    foreach ($segment in @($FilePath -split '[\\/]')) {
        foreach ($pattern in $script:MediaNormalizerSecretFilePatterns) {
            if ($segment -match $pattern) {
                return $true
            }
        }
    }

    return $false
}
