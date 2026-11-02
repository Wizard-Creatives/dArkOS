#!/bin/bash
# Preflight for building dArkOS under WSL2 (or any Linux host).
# Checks the host features the dArkOS build scripts rely on, in a few minutes,
# before committing to a ~20 hour build. Run as a normal user with sudo.
# Prints PASS/FAIL per check and exits non-zero if any check failed.

fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails+1)); }
T="$(mktemp -d)"
cleanup() {
  sudo umount "$T/mnt" 2>/dev/null
  [ -n "${LOOP:-}" ] && sudo losetup -d "$LOOP" 2>/dev/null
  sudo umount "$T/root/proc" 2>/dev/null
  sudo rm -rf "$T"
}
trap cleanup EXIT

echo "Host"
if [ "$(uname -m)" = "x86_64" ]; then pass "x86_64 host ($(uname -r))"; else fail "host is $(uname -m): the build's cross toolchain is x86_64 only"; fi
if grep -qi microsoft /proc/version; then
  if grep -qi "WSL2" /proc/version || [ -d /run/WSL ] ; then pass "WSL2"; else fail "looks like WSL1: run 'wsl --set-version <distro> 2' in PowerShell"; fi
fi
if sudo -n true 2>/dev/null; then pass "passwordless sudo"; else fail "sudo asks for a password: run ./FreeSudo.sh in the repo"; fi
if [ "$(ps -p 1 -o comm=)" = "systemd" ]; then pass "systemd is PID 1 (needed for apt-cacher-ng)"; else fail "systemd not running: see step 2 of the handoff (append [boot] systemd=true to /etc/wsl.conf, never overwrite it), then 'wsl --shutdown'"; fi
# Under WSL2, df on the Linux side shows the virtual disk's 1 TB maximum, not
# the Windows drive it grows into. Check the Windows drive that holds the WSL
# disk (C: unless WIN_DRIVE=d etc. is set).
if [ -d "/mnt/${WIN_DRIVE:-c}" ] && grep -qi microsoft /proc/version; then
  where="Windows drive ${WIN_DRIVE:-c}: (holds the WSL disk)"
  free_gb=$(df -BG --output=avail "/mnt/${WIN_DRIVE:-c}" | tail -1 | tr -dc 0-9)
else
  where="\$HOME"
  free_gb=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc 0-9)
fi
if [ "${free_gb:-0}" -ge 150 ]; then pass "${free_gb} GB free on $where"; else fail "only ${free_gb} GB free on $where; want 150+ GB"; fi
mem_mb=$(free -m | awk '/^Mem:/{print $2}')
swap_mb=$(free -m | awk '/^Swap:/{print $2}')
if [ "$((mem_mb + swap_mb))" -ge 15000 ]; then pass "${mem_mb} MB RAM + ${swap_mb} MB swap"; else fail "${mem_mb} MB RAM + ${swap_mb} MB swap; want 16 GB together (raise memory/swap in %UserProfile%\\.wslconfig, then wsl --shutdown)"; fi
case "$PWD" in /mnt/[a-z]/*) fail "running from a Windows drive ($PWD): clone the repo inside the Linux filesystem, e.g. ~/dArkOS";; esac

echo "Tools"
sudo apt-get -y -qq update >/dev/null 2>&1
# Includes host tools the build runs unchecked (unzip, zstd, cpio): without
# them it "succeeds" with no RetroArch cores and a broken initrd.
sudo DEBIAN_FRONTEND=noninteractive apt-get -y -qq install debootstrap qemu-user-static btrfs-progs dosfstools gdisk parted \
  git tmux unzip zstd cpio rsync wget curl p7zip-full kmod >/dev/null 2>&1 \
  && pass "build host packages installed" \
  || fail "could not install the build host packages with apt"
for t in debootstrap qemu-aarch64-static qemu-arm-static mkfs.btrfs mkfs.vfat sgdisk parted partprobe git tmux unzip zstd cpio rsync wget curl 7z; do
  command -v "$t" >/dev/null || fail "missing host tool: $t"
done

echo "Loop devices with partitions (setup_partition-rk3566.sh)"
truncate -s 300M "$T/disk.img"
LOOP=$(sudo losetup --show -f "$T/disk.img" 2>/dev/null)
if [ -n "$LOOP" ]; then
  pass "losetup gave $LOOP"
  sudo parted -s "$LOOP" mklabel gpt >/dev/null 2>&1
  sudo sgdisk --new=1:2048:206847 --new=2:206848:0 "$LOOP" >/dev/null 2>&1
  sudo partprobe "$LOOP" 2>/dev/null; sleep 2
  if [ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ]; then pass "partition nodes ${LOOP}p1/p2 appear after partprobe"; else fail "no ${LOOP}p1/p2 after partprobe: the build formats \${LOOP_DEV}p3..p5"; fi
  sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1 && pass "mkfs.vfat on a loop partition" || fail "mkfs.vfat on ${LOOP}p1"
else
  fail "losetup -f failed (no loop devices)"
fi

echo "btrfs (root filesystem of the image)"
sudo modprobe btrfs 2>/dev/null
if grep -qw btrfs /proc/filesystems; then pass "btrfs available in kernel $(uname -r)"; else fail "btrfs not available: run 'wsl --update', remove any custom kernel= line from .wslconfig, then 'sudo modprobe btrfs'"; fi
truncate -s 1G "$T/fs.img"
mkdir -p "$T/mnt"
if sudo mkfs.btrfs -f -L TEST "$T/fs.img" >/dev/null 2>&1 && sudo mount -t btrfs -o loop,compress=zstd:1 "$T/fs.img" "$T/mnt" 2>/dev/null; then
  pass "mkfs.btrfs + mount -o loop,compress=zstd:1"
  sudo btrfs filesystem resize 800M "$T/mnt" >/dev/null 2>&1 && pass "btrfs filesystem resize (shrink)" || fail "btrfs filesystem resize (shrink)"
  sudo umount "$T/mnt"
else
  fail "cannot create/mount btrfs (kernel without btrfs?)"
fi

echo "arm64 + armhf emulation in a chroot (qemu-user-static via binfmt_misc)"
for a in aarch64 arm; do
  f=/proc/sys/fs/binfmt_misc/qemu-$a
  if [ -e "$f" ] && grep -q '^enabled' "$f" && grep -q '^flags:.*F' "$f"; then
    pass "binfmt qemu-$a registered (flags: $(grep '^flags' "$f" | cut -d' ' -f2))"
  else
    fail "binfmt qemu-$a not registered with the F flag: run 'sudo /usr/lib/systemd/systemd-binfmt /usr/lib/binfmt.d/qemu-aarch64.conf /usr/lib/binfmt.d/qemu-arm.conf' (on Ubuntu 24.04 qemu-user-static registers through systemd-binfmt, not update-binfmts)"
  fi
done
if sudo debootstrap --variant=minbase --foreign --arch=arm64 trixie "$T/root" http://deb.debian.org/debian >/dev/null 2>&1; then
  sudo cp /usr/bin/qemu-aarch64-static "$T/root/usr/bin/" 2>/dev/null
  out=$(sudo chroot "$T/root" /bin/uname -m 2>&1)
  if [ "$out" = "aarch64" ]; then pass "arm64 chroot runs (uname -m = aarch64)"; else fail "arm64 chroot did not run: $out"; fi
else
  fail "debootstrap of an arm64 trixie base failed (network?)"
fi

echo
if [ "$fails" -eq 0 ]; then echo "PREFLIGHT PASSED"; else echo "PREFLIGHT FAILED: $fails check(s)"; fi
exit "$fails"
