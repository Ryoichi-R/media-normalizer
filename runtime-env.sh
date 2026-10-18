#!/bin/sh
# Sourced by the three package entrypoints; never resolves tools from PATH.
set -eu
mn_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mn_runtime="$mn_root/runtime"
mn_pwsh="$mn_runtime/powershell/pwsh"
mn_manifest="$mn_runtime/dependency-manifest.json"
mn_fail() { printf '%s\n' "$1" >&2; exit 1; }
[ "$(/usr/bin/uname -s)" = Darwin ] || mn_fail 'macOS is required.'
[ "$(/usr/bin/uname -m)" = arm64 ] || mn_fail 'Apple Silicon is required.'
[ -x "$mn_pwsh" ] || mn_fail 'Bundled PowerShell is missing or not executable.'
[ -f "$mn_manifest" ] || mn_fail 'Bundled runtime manifest is missing.'
[ "$(/usr/bin/plutil -extract schemaVersion raw -o - "$mn_manifest")" = 1 ] || mn_fail 'Unsupported runtime manifest schema.'
[ "$(/usr/bin/plutil -extract runtime raw -o - "$mn_manifest")" = osx-arm64 ] || mn_fail 'Wrong runtime manifest.'
mn_index=0
mn_hash=
while mn_name=$(/usr/bin/plutil -extract "criticalFiles.$mn_index.name" raw -o - "$mn_manifest" 2>/dev/null); do
    if [ "$mn_name" = PowerShell ]; then
        [ -z "$mn_hash" ] || mn_fail 'Duplicate PowerShell manifest entry.'
        mn_path=$(/usr/bin/plutil -extract "criticalFiles.$mn_index.path" raw -o - "$mn_manifest")
        [ "$mn_path" = powershell/pwsh ] || mn_fail 'Invalid PowerShell manifest path.'
        mn_hash=$(/usr/bin/plutil -extract "criticalFiles.$mn_index.sha256" raw -o - "$mn_manifest")
    fi
    mn_index=$((mn_index + 1))
done
[ ${#mn_hash} -eq 64 ] || mn_fail 'Missing or invalid PowerShell hash.'
mn_actual=$(/usr/bin/shasum -a 256 "$mn_pwsh")
mn_actual=${mn_actual%% *}
[ "$mn_actual" = "$mn_hash" ] || mn_fail 'Bundled PowerShell SHA-256 mismatch.'
export MEDIA_NORMALIZER_RUNTIME_ROOT="$mn_runtime"
export FFMPEG_PATH="$mn_runtime/ffmpeg/bin/ffmpeg"
export FFPROBE_PATH="$mn_runtime/ffmpeg/bin/ffprobe"
export MEDIA_NORMALIZER_PYTHON="$mn_runtime/python/bin/python3"
export PYTHONHOME="$mn_runtime/python"
unset PYTHONPATH
export PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1
export PATH="$mn_runtime/ffmpeg/bin:$mn_runtime/python/bin:/usr/bin:/bin:/usr/sbin:/sbin"
mn_check="$mn_root/diagnostics/runtime-check.ps1"
[ -f "$mn_check" ] || mn_fail 'Runtime diagnostic script is missing.'
