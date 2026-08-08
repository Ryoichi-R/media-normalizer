#Requires -Modules Pester

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\lib\MediaNormalizer.Probe.psm1') -Force
}

Describe 'Format-Duration' {
    It '0秒を mm:ss で返す' {
        MediaNormalizer.Probe\Format-Duration -Seconds 0 | Should -Be '0:00'
    }

    It '59秒を mm:ss で返す' {
        MediaNormalizer.Probe\Format-Duration -Seconds 59 | Should -Be '0:59'
    }

    It '60秒を mm:ss で返す' {
        MediaNormalizer.Probe\Format-Duration -Seconds 60 | Should -Be '1:00'
    }

    It '3599秒を mm:ss で返す' {
        MediaNormalizer.Probe\Format-Duration -Seconds 3599 | Should -Be '59:59'
    }

    It '3600秒を h:mm:ss で返す' {
        MediaNormalizer.Probe\Format-Duration -Seconds 3600 | Should -Be '1:00:00'
    }

    It '負値は --:-- を返す' {
        MediaNormalizer.Probe\Format-Duration -Seconds -1 | Should -Be '--:--'
    }

    It 'NaNは --:-- を返す' {
        MediaNormalizer.Probe\Format-Duration -Seconds ([double]::NaN) | Should -Be '--:--'
    }

    It 'Infinityは --:-- を返す' {
        MediaNormalizer.Probe\Format-Duration -Seconds ([double]::PositiveInfinity) | Should -Be '--:--'
    }
}
