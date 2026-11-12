#!/usr/bin/env bash
# scripts/host.sh against fake KFD topologies: no GPU hardware needed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
failed=0

node() {  # node DIR INDEX GFX_TARGET RENDER_MINOR
    mkdir -p "$1/$2"
    printf 'cpu_cores_count 0\nsimd_count 80\ngfx_target_version %s\ndrm_render_minor %s\n' "$3" "$4" > "$1/$2/properties"
}
expect() {  # expect NAME TOPOLOGY WANT
    local got
    got=$(KFD_TOPOLOGY=$2 DRM_SYSFS=/sys/class/drm bash -c '. scripts/host.sh; echo "$STRIX_RENDER"')
    if [[ "$got" == "$3" ]]; then echo "  ok    $1"; else echo "  FAIL  $1: got '$got', want '$3'"; failed=1; fi
}

node "$tmp/one" 0 0 0
node "$tmp/one" 1 110501 128
expect "the iGPU alone" "$tmp/one" /dev/dri/renderD128

node "$tmp/egpu" 0 0 0
node "$tmp/egpu" 1 110000 128
node "$tmp/egpu" 2 110501 129
expect "a discrete gfx1100 enumerated first" "$tmp/egpu" /dev/dri/renderD129

node "$tmp/none" 0 0 0
node "$tmp/none" 1 110000 128
expect "no gfx1151" "$tmp/none" ""

expect "no KFD at all" "$tmp/missing" ""

exit $failed
