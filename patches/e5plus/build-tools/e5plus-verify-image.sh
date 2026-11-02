#!/bin/bash
# Checks a finished dArkOS GameMT E5 Plus image, read-only, for the files the
# E5 Plus port puts in it. The dArkOS build carries on past many failures
# without stopping, so a finished build is not proof of a good image.
# Usage: e5plus-verify-image.sh /path/to/dArkOS_E5PLUS_trixie_MMDDYYYY.img
# Prints PASS/FAIL per check; exits non-zero if any check failed.

IMG="${1:?usage: $0 /path/to/dArkOS_E5PLUS_*.img}"
[ -f "$IMG" ] || { echo "no such image: $IMG"; exit 2; }
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails+1)); }
have() { [ -e "$1" ] && pass "$2" || fail "$2 (missing: ${1#$M/})"; }
M="$(mktemp -d)"
cleanup() {
  sudo umount "$M/boot" "$M/root" 2>/dev/null
  [ -n "${LOOP:-}" ] && sudo losetup -d "$LOOP" 2>/dev/null
  rmdir "$M/boot" "$M/root" "$M" 2>/dev/null
}
trap cleanup EXIT

LOOP=$(sudo losetup -P -r --show -f "$IMG") || { echo "losetup failed"; exit 2; }
sudo partprobe "$LOOP" 2>/dev/null; sleep 2
mkdir -p "$M/boot" "$M/root"
sudo mount -o ro "${LOOP}p3" "$M/boot" || { echo "cannot mount the boot partition ${LOOP}p3"; exit 2; }
sudo mount -o ro "${LOOP}p4" "$M/root" 2>/dev/null || \
  sudo mount -o ro,rescue=nologreplay "${LOOP}p4" "$M/root" || { echo "cannot mount the root partition ${LOOP}p4"; exit 2; }
R="$M/root"

echo "Boot partition"
have "$M/boot/Image" "kernel Image"
have "$M/boot/uInitrd" "uInitrd"
have "$M/boot/rk3566-e5plus.dtb" "E5 Plus device tree (rk3566-e5plus.dtb)"
if grep -q "FDT /rk3566-e5plus.dtb" "$M/boot/extlinux/extlinux.conf" 2>/dev/null && \
   grep -q "fbcon=rotate:1" "$M/boot/extlinux/extlinux.conf" 2>/dev/null; then
  pass "extlinux.conf boots rk3566-e5plus.dtb with fbcon=rotate:1"
else
  fail "extlinux.conf does not name rk3566-e5plus.dtb with fbcon=rotate:1"
fi

echo "Kernel modules and firmware"
ko=$(ls "$R"/usr/lib/modules/*/extra/8733bs.ko "$R"/lib/modules/*/extra/8733bs.ko 2>/dev/null | head -1)
[ -n "$ko" ] && pass "RTL8733BS Wi-Fi driver (8733bs.ko)" || fail "RTL8733BS Wi-Fi driver (lib/modules/*/extra/8733bs.ko) missing"
if [ -n "$ko" ] && grep -qs "8733bs.ko" "$(dirname "$(dirname "$ko")")/modules.dep"; then
  pass "8733bs.ko is in modules.dep (depmod ran)"
else
  fail "8733bs.ko not in modules.dep"
fi
have "$R/usr/lib/firmware/rtl_bt/rtl8723fs_fw.bin" "Bluetooth firmware rtl8723fs_fw.bin"
have "$R/usr/lib/firmware/rtl_bt/rtl8723fs_config.bin" "Bluetooth firmware rtl8723fs_config.bin"

echo "E5 Plus services and tools"
for s in e5plus-lights e5plus-jackd e5plus-offcharge; do
  have "$R/etc/systemd/system/multi-user.target.wants/$s.service" "$s.service enabled"
done
have "$R/usr/local/bin/e5plus-lights.sh" "e5plus-lights.sh"
have "$R/usr/local/bin/e5plus-audio-path.sh" "e5plus-audio-path.sh"
have "$R/usr/local/bin/e5plus-offcharge.py" "e5plus-offcharge.py"
have "$R/usr/local/share/e5plus-offcharge/battery_5.bmp" "charging screen images"
have "$R/opt/system/Joystick Lights.sh" "Options > Joystick Lights"
dev=$(tr -d '\0\r\n' < "$R/home/ark/.config/.DEVICE" 2>/dev/null)
[ "$dev" = "E5PLUS" ] && pass ".DEVICE is E5PLUS" || fail ".DEVICE is '$dev', expected E5PLUS"
if grep -qs "headphone-audio-switch" "$R"/var/spool/cron/crontabs/root; then
  fail "headphone-audio-switch.sh is in root's crontab (should be off on the E5 Plus)"
else
  pass "headphone-audio-switch.sh not scheduled (e5plus-jackd does it)"
fi

echo "dArkOS userland"
have "$R/usr/bin/emulationstation/emulationstation" "EmulationStation"
have "$R/opt/retroarch/bin/retroarch" "RetroArch (64-bit)"
cores=$(ls "$R"/home/ark/.config/retroarch/cores/*_libretro.so 2>/dev/null | wc -l)
[ "$cores" -ge 50 ] && pass "$cores RetroArch cores" || fail "only $cores RetroArch cores (unzip missing on the build host?)"
have "$R/usr/local/bin/ogage" "ogage hotkey daemon"
have "$R/roms.tar" "roms.tar (first-boot roms partition contents)"
sdl=$(ls "$R"/usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0.* 2>/dev/null | head -1)
[ -n "$sdl" ] && pass "SDL2 ($(basename "$sdl"))" || fail "SDL2 library missing"

echo
if [ "$fails" -eq 0 ]; then echo "IMAGE CHECK PASSED"; else echo "IMAGE CHECK FAILED: $fails check(s)"; fi
exit "$fails"
