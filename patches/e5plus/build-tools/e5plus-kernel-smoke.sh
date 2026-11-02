#!/bin/bash
# GameMT E5 Plus kernel smoke test for dArkOS (branch claude/bold-cori-9yza6c).
# Builds only what the E5 Plus port adds to the kernel: the dts, the five
# kernel patches, the kernel and modules, and the out-of-tree RTL8733BS Wi-Fi
# driver, with the same toolchain and steps as build_kernel-rk3566.sh.
# Takes ~20-60 min. Does not need sudo, loop devices or qemu.
#
# Usage: e5plus-kernel-smoke.sh /path/to/dArkOS [workdir]
set -euo pipefail

REPO="$(cd "${1:?usage: $0 /path/to/dArkOS [workdir]}" && pwd)"
WORK="${2:-$HOME/e5plus-kernel-smoke}"
mkdir -p "$WORK"
cd "$WORK"

# Same cross toolchain the dArkOS build uses (utils.sh)
TC="$WORK/gcc-linaro-6.3.1-2017.05-x86_64_aarch64-linux-gnu"
[ -d "$TC" ] || git clone -q --depth=1 https://github.com/christianhaitian/gcc-linaro-6.3.1-2017.05-x86_64_aarch64-linux-gnu.git "$TC"
# KCFLAGS=-w: the dArkOS Makefile exports it to the whole build
export PATH="$TC/bin:$PATH" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KCFLAGS=-w
aarch64-linux-gnu-gcc --version | head -1

# Kernel, as build_kernel-rk3566.sh clones it
[ -d main ] || git clone -q --recursive --depth=1 https://github.com/christianhaitian/kernel_5_10_226.git main
cd main
cp "$REPO/patches/e5plus/kernel/rk3566-e5plus.dts" arch/arm64/boot/dts/rockchip/
grep -q "rk3566-e5plus.dtb" arch/arm64/boot/dts/rockchip/Makefile || \
  echo 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3566-e5plus.dtb' >> arch/arm64/boot/dts/rockchip/Makefile
for patch in "$REPO"/patches/e5plus/kernel/*.patch; do
  if git apply -R --check "$patch" 2>/dev/null; then echo "already applied: $(basename "$patch")"; continue; fi
  git apply "$patch"
  echo "applied: $(basename "$patch")"
done
make rk3566_optimized_linux_defconfig >/dev/null
CFLAGS=-Wno-deprecated-declarations make -j"$(nproc)" KERNEL_DTS=rk3566 KERNEL_CONFIG=rk3566_optimized_linux_defconfig
ls -la arch/arm64/boot/Image arch/arm64/boot/dts/rockchip/rk3566-e5plus.dtb
cd ..

# RTL8733BS Wi-Fi driver, as build_kernel-rk3566.sh builds it
rm -rf rtl8733bs
git clone -q https://github.com/newbie-461/RTL8733BS_WiFi_linux_v5.14.1.1-46.git rtl8733bs
git -C rtl8733bs checkout -q 4719bf994bc4a80c05cda4cb397ee7a39ecebe15
for patch in "$REPO"/patches/e5plus/rtl8733bs/*.patch; do git -C rtl8733bs apply "$patch"; done
make -C main M="$PWD/rtl8733bs" KCFLAGS=-w CONFIG_RTL8733BS=m -j"$(nproc)" modules
ls -la rtl8733bs/8733bs.ko
# The E5 Plus radio is SDIO 024C:B733: the module must claim it to autoload,
# and it must match the kernel it was built against.
mi="$(modinfo rtl8733bs/8733bs.ko)"
krel="$(make -s -C main kernelrelease)"
grep -qE '^alias: +sdio:c[0-9A-Fa-f*]+v024Cd[Bb]733' <<<"$mi" || { echo "FAIL: 8733bs.ko has no SDIO 024C:B733 alias"; exit 1; }
grep -qE "^vermagic: +$krel " <<<"$mi" || { echo "FAIL: 8733bs.ko vermagic does not match kernel $krel"; exit 1; }
grep -E '^(vermagic|alias)' <<<"$mi"

echo
echo "E5 PLUS KERNEL SMOKE TEST PASSED"
