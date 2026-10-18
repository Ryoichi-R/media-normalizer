#!/bin/sh
set -eu
. "$(dirname -- "$0")/runtime-env.sh"
"$mn_pwsh" -NoLogo -NoProfile -File "$mn_check" -RuntimeRoot "$mn_runtime" -Quiet
exec "$mn_pwsh" -NoLogo -NoProfile -File "$mn_root/media-normalizer.ps1" -Cli "$@"
