# shellcheck shell=bash
# The Strix Halo GPU (gfx1151) on this host, found through KFD's topology so that a second GPU
# (an eGPU, a discrete card) is never picked by mistake. Sourced by setup.sh and start.sh.
#
#   STRIX_RENDER   /dev/dri/renderD<minor> of the gfx1151 GPU, empty if there is none
#   STRIX_SYSFS    its sysfs device directory (mem_info_gtt_*, mem_info_vram_total)

: "${KFD_TOPOLOGY:=/sys/class/kfd/kfd/topology/nodes}"
: "${DRM_SYSFS:=/sys/class/drm}"

STRIX_RENDER="" STRIX_SYSFS=""
for _node in "$KFD_TOPOLOGY"/*/properties; do
    [[ -f "$_node" ]] || continue
    if [[ "$(awk '$1 == "gfx_target_version" {print $2}' "$_node")" == 110501 ]]; then
        _minor=$(awk '$1 == "drm_render_minor" {print $2}' "$_node")
        STRIX_RENDER=/dev/dri/renderD$_minor
        STRIX_SYSFS=$DRM_SYSFS/renderD$_minor/device
        break
    fi
done
unset _node _minor
