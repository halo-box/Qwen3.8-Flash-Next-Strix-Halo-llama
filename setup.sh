#!/usr/bin/env bash
# setup.sh — prepare a Strix Halo host for this recipe. Safe to re-run.
#
#   ./setup.sh          check everything, and offer to fix what is missing (asks before each change)
#   ./setup.sh --check  only report
#
# Modelled on claudejaune/Qwen3.8-Halogen-Flash-Strix-Halo's setup.sh: the GPU, the BIOS memory
# split, Docker, the GTT kernel parameters, and the tuned accelerator profile. Anything that
# needs a reboot is collected and asked for once, at the end.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. scripts/host.sh

CHECK=0; [[ "${1:-}" == --check ]] && CHECK=1
REBOOT=0 PROBLEMS=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mfix\033[0m   %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }
note() { printf '  \033[33mnote\033[0m  %s\n' "$*"; }
ask()  { ((CHECK)) && return 1; local a; read -r -p "        $* [y/N] " a; [[ "$a" == [yY]* ]]; }
[[ $EUID -ne 0 ]] || { echo "Run as your user, not root (sudo is used where needed)." >&2; exit 1; }

echo "Hardware"
if [[ -z "$STRIX_RENDER" ]]; then
    bad "no Strix Halo GPU (gfx1151) found in KFD's topology: is the amdgpu driver loaded? (/dev/kfd $([[ -e /dev/kfd ]] && echo present || echo missing))"
    echo; echo "Fix that first; the rest of the checks need the GPU."; exit 1
fi
ok "Strix Halo GPU (gfx1151) at $STRIX_RENDER"
vram=$(awk '{print int($1 / 2^30)}' "$STRIX_SYSFS/mem_info_vram_total")
ram=$(awk -v v="$vram" '/MemTotal/{t = $2 / 2^20 + v; print int((t + 15) / 16) * 16}' /proc/meminfo)
if ((vram > 4)); then
    bad "the BIOS gives the GPU a ${vram} GiB carve-out: set UMA / dedicated graphics memory to its minimum; this recipe uses GTT, which the carve-out takes from"
else ok "BIOS carve-out ${vram} GiB"; fi
((ram >= 128)) && ok "${ram} GB RAM" || bad "${ram} GB RAM: the model needs a 128 GB Strix Halo"
gtt_gib=$(awk '/MemTotal/{print int($2 / 2^20) - 10}' /proc/meminfo)
cma=$(awk '/CmaFree/{print int($2 / 2^20)}' /proc/meminfo)
((cma > 2)) && note "the kernel counts ${cma} GiB of RAM as CMA-free (CmaTotal $(awk '/CmaTotal/{print int($2/2^20)}' /proc/meminfo) GiB): GPU pages cannot use it, so the server gets ~${cma} GiB less than GTT allows"
WANT_PARAMS=(amd_iommu=off "ttm.pages_limit=$((gtt_gib * 262144))" "amdgpu.gttsize=$((gtt_gib * 1024))")

echo "Host tools"
need=()
for t in curl python3 sha256sum pgrep stat df awk sed grep; do command -v "$t" >/dev/null || need+=("$t"); done
if ((${#need[@]})); then bad "missing: ${need[*]} (install them with your package manager; pgrep is in procps)"
else ok "curl, python3, sha256sum, pgrep and coreutils"; fi

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
for dev in /dev/kfd "$STRIX_RENDER"; do
    [[ -e $dev ]] && ok "$dev present" || bad "$dev missing: is the amdgpu driver loaded?"
done

echo "Kernel"
kv=$(uname -r); maj=${kv%%.*}
if ((maj >= 7)); then ok "kernel $kv"; else note "kernel $kv: this recipe is tested on 7.0; older kernels are untested"; fi

cmdline=$(cat /proc/cmdline)
missing=()
for p in "${WANT_PARAMS[@]}"; do
    key=${p%%=*}
    if [[ " $cmdline " == *" $p "* ]]; then ok "$p"
    elif [[ " $cmdline " == *" $key="* ]]; then
        cur=$(tr ' ' '\n' <<<"$cmdline" | grep "^$key=" | tail -1)
        note "$cur is set; this recipe recommends $p"; missing+=("$p")
    else bad "$p is not on the kernel command line"; missing+=("$p"); fi
done
note "GTT available to the GPU now: $(awk '{printf "%.0f", $1/2^30}' "$STRIX_SYSFS/mem_info_gtt_total") GiB; the parameters above make it ${gtt_gib} GiB"

if ((${#missing[@]})); then
    managed=$(grep -lsE 'ttm\.pages_limit|amd_iommu' /etc/default/grub.d/*.cfg 2>/dev/null | head -1 || true)
    if [[ -n "$managed" ]]; then
        note "$managed already sets these parameters (configuration management?): change them there:"
        note "  ${WANT_PARAMS[*]}"
    elif ask "Add ${missing[*]} to the kernel command line (backs up the file it edits)?"; then
        if [[ -e /run/ostree-booted ]]; then
            sudo rpm-ostree kargs $(printf -- '--append-if-missing=%s ' "${missing[@]}")
        elif command -v kernelstub >/dev/null; then
            for p in "${missing[@]}"; do sudo kernelstub -a "$p"; done
        elif command -v grubby >/dev/null; then
            sudo grubby --update-kernel=ALL --args="${missing[*]}"
        elif [[ -d /etc/default/grub.d || -f /etc/default/grub ]] && command -v update-grub >/dev/null; then
            sudo mkdir -p /etc/default/grub.d
            printf 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT %s"\n' "${missing[*]}" \
                | sudo tee /etc/default/grub.d/90-strix-halo-llama.cfg >/dev/null
            sudo update-grub
        elif [[ -f /etc/default/grub ]] && command -v grub-mkconfig >/dev/null; then
            sudo cp /etc/default/grub "/etc/default/grub.bak.$(date +%s)"
            sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${missing[*]}\"|" /etc/default/grub
            sudo grub-mkconfig -o /boot/grub/grub.cfg
        elif [[ -f /etc/update-extlinux.conf ]] && command -v update-extlinux >/dev/null; then
            sudo cp /etc/update-extlinux.conf "/etc/update-extlinux.conf.bak.$(date +%s)"
            sudo sed -i "s|^default_kernel_opts=\"\(.*\)\"|default_kernel_opts=\"\1 ${missing[*]}\"|" /etc/update-extlinux.conf
            sudo update-extlinux
        elif [[ -d /boot/loader/entries ]]; then
            for e in /boot/loader/entries/*.conf; do
                sudo cp "$e" "$e.bak.$(date +%s)"
                sudo sed -i "/^options /s|\$| ${missing[*]}|" "$e"
            done
        else
            bad "no rpm-ostree, kernelstub, grubby, GRUB, extlinux or systemd-boot found: add ${missing[*]} to your boot loader by hand"
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

echo
if ((REBOOT)); then echo "Done. Reboot (or log out and in, for group changes) before ./start.sh."
elif ((PROBLEMS)); then echo "$PROBLEMS item(s) to fix$(((CHECK)) && echo ': run ./setup.sh without --check to fix them')."
else echo "Ready: ./start.sh"; fi
