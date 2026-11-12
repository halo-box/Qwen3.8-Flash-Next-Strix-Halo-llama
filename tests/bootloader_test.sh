#!/usr/bin/env bash
# setup.sh's kernel-parameter step on every boot loader it knows, each in a throwaway container:
# the boot tools are stubs that log their arguments, sudo runs the command as the user, and the
# user owns /etc and /boot inside the container. Needs Docker and the Strix Halo GPU (for
# setup.sh's hardware check); nothing on the host is changed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
IMAGE=debian:trixie-slim
render=$(. scripts/host.sh; echo "$STRIX_RENDER")
failed=0

run() {  # run NAME PREPARE CHECK: PREPARE builds the fake host as root, CHECK inspects it as the user
    local out
    out=$(docker run --rm -i --device /dev/kfd --device "$render" -v "$PWD:/recipe:ro" "$IMAGE" bash -s <<EOF 2>&1
set -e
mkdir -p /stub /etc/default /boot
printf '#!/bin/sh\nexec "\$@"\n' > /usr/local/bin/sudo; chmod +x /usr/local/bin/sudo
stub() { printf '#!/bin/sh\necho "\$(basename \$0) \$*" >> /tmp/calls\n' > /stub/\$1; chmod +x /stub/\$1; }
$2
chown -R 1000:1000 /etc/default /boot /stub; touch /tmp/calls; chown 1000 /tmp/calls
yes | setpriv --reuid 1000 --regid 1000 --clear-groups env HOME=/tmp USER=t PATH=/stub:\$PATH /recipe/setup.sh >/tmp/setup.log 2>&1 || true
$3
EOF
)
    if [[ "$(tail -1 <<<"$out")" == PASS ]]; then echo "  ok    $1"; else echo "  FAIL  $1"; sed 's/^/        /' <<<"$out" | tail -15; failed=1; fi
}

run "rpm-ostree (Bazzite, Silverblue)" \
    'stub rpm-ostree; stub grubby; touch /run/ostree-booted' \
    'grep -q "^rpm-ostree kargs .*--append-if-missing=amdgpu.gttsize=" /tmp/calls && ! grep -q grubby /tmp/calls && echo PASS'
run "kernelstub (Pop!_OS)" \
    'stub kernelstub' \
    'grep -q "^kernelstub -a amdgpu.gttsize=" /tmp/calls && echo PASS'
run "grubby (Fedora)" \
    'stub grubby' \
    'grep -q "^grubby --update-kernel=ALL --args=.*amdgpu.gttsize=" /tmp/calls && echo PASS'
run "update-grub (Debian, Ubuntu)" \
    'stub update-grub; printf "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"\n" > /etc/default/grub' \
    'grep -q "amdgpu.gttsize=" /etc/default/grub.d/90-strix-halo-llama.cfg && grep -q "^update-grub" /tmp/calls && echo PASS'
run "grub-mkconfig (Arch)" \
    'stub grub-mkconfig; printf "GRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"\n" > /etc/default/grub' \
    'grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=\"quiet .*amdgpu.gttsize=[0-9]*\"$" /etc/default/grub && ls /etc/default/grub.bak.* >/dev/null && grep -q "^grub-mkconfig -o /boot/grub/grub.cfg" /tmp/calls && echo PASS'
run "systemd-boot" \
    'mkdir -p /boot/loader/entries; printf "title Linux\noptions root=UUID=x rw\n" > /boot/loader/entries/linux.conf' \
    'grep -q "^options root=UUID=x rw .*amdgpu.gttsize=" /boot/loader/entries/linux.conf && ls /boot/loader/entries/linux.conf.bak.* >/dev/null && echo PASS'
run "no known boot loader" \
    ':' \
    'grep -q "add .* to your boot loader by hand" /tmp/setup.log && echo PASS'

exit $failed
