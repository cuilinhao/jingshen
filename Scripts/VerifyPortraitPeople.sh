#!/bin/bash
# macOS local acceptance probe. Requires Xcode and an existing bundle containing
# DepthAnythingV3_base_504.mlmodelc; no model download or compilation is performed.
# Usage: ./Scripts/VerifyPortraitPeople.sh IMAGE MODELS.bundle OUTPUT_DIR COUNT X,Y [X,Y ...]
# Supply exactly COUNT distinct-person clicks in normalized top-left coordinates.
# Output: focus-id-N.png, mask-id-N.png, verification.json. Existing files are not overwritten.
# The image is read-only. Temporary executable/module-cache files are removed on exit.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: VerifyPortraitPeople.sh IMAGE MODELS.bundle OUTPUT_DIR COUNT X,Y [X,Y ...]' \
    'COUNT must be 1–4, with one normalized top-left click per expected person.'
}
fail() { printf 'FAIL %s\n' "$1" >&2; exit 2; }

if [[ $# == 1 && "$1" == '--help' ]]; then usage; exit 0; fi
if [[ $# -lt 5 ]]; then usage >&2; exit 2; fi
[[ "$4" =~ ^[1-4]$ ]] || fail 'Expected count must be 1–4.'
[[ $(($# - 4)) == "$4" ]] || fail 'Provide exactly one click for each expected person.'
for point in "${@:5}"; do
  awk -F, '
    NF != 2 { exit 1 }
    $1 !~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/ { exit 1 }
    $2 !~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/ { exit 1 }
    $1 < 0 || $1 > 1 || $2 < 0 || $2 > 1 { exit 1 }
  ' <<< "$point" || fail 'Click coordinates must be finite X,Y values in [0,1].'
done
[[ -f "$1" && -r "$1" ]] || fail 'Input image is not a readable file.'
[[ -d "$2" ]] || fail 'Compiled model bundle is not a directory.'
[[ -n "$3" ]] || fail 'An output directory must be explicitly provided.'
[[ "$(uname -s)" == 'Darwin' ]] || fail 'This probe requires macOS and Xcode.'
xcrun --find swiftc >/dev/null 2>&1 || fail 'Swift compiler is unavailable.'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
probe_work="$(mktemp -d "${TMPDIR:-/tmp}/PGYPortraitVerification.XXXXXX")"
cleanup() { rm -rf -- "$probe_work"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s\n' 'BUILD compiling the current Core and Imaging sources for local macOS verification'
xcrun swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$probe_work/ModuleCache" \
  "$project_dir"/PGYDepthDemo/Core/*.swift \
  "$project_dir"/PGYDepthDemo/Imaging/*.swift \
  "$script_dir/VerifyPortraitPeople.swift" \
  -o "$probe_work/VerifyPortraitPeople"
"$probe_work/VerifyPortraitPeople" "$@"
