#!/usr/bin/env bash
# setup.sh — prepare a Strix Halo host for this recipe. Safe to re-run.
#
#   ./setup.sh          check everything, and offer to fix what is missing (asks before each change)
#   ./setup.sh --check  only report
#
# Modelled on claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo's setup.sh: Docker, GPU device
# access, kernel 7.0+, the GTT kernel parameters, and the tuned accelerator profile. Anything
# that needs a reboot is collected and asked for once, at the end.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

CHECK=0; [[ "${1:-}" == --check ]] && CHECK=1
# 120 GiB of GTT on a 128 GB machine: room for 5 slots of 262k (see README: Memory).
WANT_PARAMS=(amd_iommu=off ttm.pages_limit=31457280 amdgpu.gttsize=122880)
REBOOT=0 PROBLEMS=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mfix\033[0m   %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }
note() { printf '  \033[33mnote\033[0m  %s\n' "$*"; }
ask()  { ((CHECK)) && return 1; local a; read -r -p "        $* [y/N] " a; [[ "$a" == [yY]* ]]; }
[[ $EUID -ne 0 ]] || { echo "Run as your user, not root (sudo is used where needed)." >&2; exit 1; }

echo "Hardware"
if grep -q 'gfx1151\|Radeon 8060S\|AI MAX' /proc/cpuinfo /sys/class/drm/card*/device/product_name 2>/dev/null \
   || lspci 2>/dev/null | grep -qi '1586\|Strix Halo'; then ok "Strix Halo"; else note "not detected as a Strix Halo; the numbers in the README will not apply"; fi
mem=$(awk '/MemTotal/{print int($2/1048576)}' /proc/meminfo)
((mem >= 110)) && ok "${mem} GiB RAM" || bad "${mem} GiB RAM: the model needs a 128 GB machine"

echo "Docker"
if command -v docker >/dev/null; then
    ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"
    if id -nG | grep -qw docker || docker info >/dev/null 2>&1; then ok "your user can run docker"
    else bad "your user is not in the docker group"
         ask "Add $USER to the docker group (log out and in afterwards)?" && sudo usermod -aG docker "$USER" && REBOOT=1; fi
else
    bad "docker is not installed: https://docs.docker.com/engine/install/"
fi

echo "GPU access"
for dev in /dev/kfd /dev/dri/renderD128; do
    [[ -e $dev ]] && ok "$dev present" || bad "$dev missing: is the amdgpu driver loaded?"
done
for g in render video; do
    getent group $g >/dev/null || continue
    if id -nG | grep -qw $g; then ok "in group $g"; else
        note "not in group $g (containers get it with --group-add; only needed to run outside Docker)"; fi
done

echo "Kernel"
kv=$(uname -r); maj=${kv%%.*}; rest=${kv#*.}; min=${rest%%.*}
if ((maj > 7 || (maj == 7 && min >= 0))); then ok "kernel $kv"; else bad "kernel $kv: 7.0 or newer is needed (older kernels refuse the read-only checkpoint registration)"; fi

cmdline=$(cat /proc/cmdline)
missing=()
for p in "${WANT_PARAMS[@]}"; do
    key=${p%%=*}
    if [[ " $cmdline " == *" $p "* ]]; then ok "$p"
    elif [[ " $cmdline " == *" $key="* ]]; then
        cur=$(tr ' ' '\n' <<<"$cmdline" | grep "^$key=" | tail -1)
        note "$cur is set; this recipe is measured with $p"; missing+=("$p")
    else bad "$p is not on the kernel command line"; missing+=("$p"); fi
done
gtt=$(awk '{printf "%.0f", $1/2^30}' /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | head -1)
[[ -n "$gtt" ]] && note "GTT available to the GPU now: ${gtt} GiB (4 slots of 262k fit in 104 GiB, 5 in 120 GiB)"

if ((${#missing[@]})); then
    managed=$(grep -lsE 'ttm\.pages_limit|amd_iommu' /etc/default/grub.d/*.cfg 2>/dev/null | head -1 || true)
    if [[ -n "$managed" ]]; then
        note "$managed already sets these parameters (configuration management?): change them there:"
        note "  ${WANT_PARAMS[*]}"
    elif ask "Add ${missing[*]} to the kernel command line (backs up the file it edits)?"; then
        if command -v grubby >/dev/null; then
            sudo grubby --update-kernel=ALL --args="${missing[*]}"
        elif [[ -d /etc/default/grub.d || -f /etc/default/grub ]] && command -v update-grub >/dev/null; then
            sudo mkdir -p /etc/default/grub.d
            printf 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT %s"\n' "${missing[*]}" \
                | sudo tee /etc/default/grub.d/90-strix-halo-llama.cfg >/dev/null
            sudo update-grub
        elif [[ -d /boot/loader/entries ]]; then
            for e in /boot/loader/entries/*.conf; do
                sudo cp "$e" "$e.bak.$(date +%s)"
                sudo sed -i "/^options /s|\$| ${missing[*]}|" "$e"
            done
        else
            bad "no grubby, update-grub or systemd-boot found: add ${missing[*]} to your boot loader by hand"
        fi
        REBOOT=1
    fi
fi

echo "Tuning"
if command -v tuned-adm >/dev/null; then
    prof=$(tuned-adm active 2>/dev/null | sed 's/.*: //')
    if [[ "$prof" == accelerator-performance ]]; then ok "tuned profile $prof"
    else bad "tuned profile is '$prof', not accelerator-performance"
         ask "Switch to accelerator-performance?" && sudo tuned-adm profile accelerator-performance; fi
else
    note "tuned is not installed (optional; accelerator-performance adds a few percent)"
fi
note "BIOS: leave the UMA / dedicated VRAM size at its minimum; the GPU uses GTT, not a carve-out"

echo
if ((REBOOT)); then echo "Done. Reboot (or log out and in, for group changes) before ./start.sh."
elif ((PROBLEMS)); then echo "$PROBLEMS item(s) to fix$(((CHECK)) && echo ': run ./setup.sh without --check to fix them')."
else echo "Ready: ./start.sh"; fi
