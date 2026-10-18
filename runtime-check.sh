#!/bin/sh
set -eu
. "$(dirname -- "$0")/runtime-env.sh"
exec "$mn_pwsh" -NoLogo -NoProfile -File "$mn_check" -RuntimeRoot "$mn_runtime" "$@"
