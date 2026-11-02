#!/bin/bash

# Build and install custom kernel from christianhaitian/linux
KERNEL_SRC=main
if [ ! -d "$KERNEL_SRC" ]; then
  git clone --recursive --depth=1 https://github.com/christianhaitian/kernel_5_10_226.git $KERNEL_SRC
fi
cd $KERNEL_SRC
# Change the boot logo depending on the device
if [[ -e "../logos/unrotated/dArkos${UNIT}.png" ]]; then
  apt list --installed 2>/dev/null | grep -q "netpbm"
  if [[ $? != "0" ]]; then
    sudo apt -y update
    sudo apt -y install netpbm
  fi	
  pngtopnm ../logos/unrotated/dArkos${UNIT}.png | ppmquant 224 | pnmnoraw > drivers/video/logo/logo_linux_clut224.ppm
  pngtopnm ../logos/unrotated/dArkoshdmi.png | ppmquant 224 | pnmnoraw > drivers/video/logo/logo_hdmi_clut224.ppm
fi

# The GameMT E5 Plus is not in the upstream kernel tree.  Its dts and the kernel
# patches it depends on live in patches/e5plus/kernel (see the README there).
# They are applied for the E5 Plus only.  The kernel tree is reused between
# builds, so any other unit takes them back out first: some (0003, 0005) touch
# code every RK817 unit runs.
if [ "$UNIT" != "e5plus" ]; then
  for patch in $(ls -r ../patches/e5plus/kernel/*.patch); do
    if git apply -R --check "$patch" 2>/dev/null; then
      git apply -R "$patch" || { echo "ERROR: could not take $patch back out of the kernel."; exit 1; }
    fi
  done
else
  cp ../patches/e5plus/kernel/rk3566-e5plus.dts arch/arm64/boot/dts/rockchip/
  grep -q "rk3566-e5plus.dtb" arch/arm64/boot/dts/rockchip/Makefile || \
    echo 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3566-e5plus.dtb' >> arch/arm64/boot/dts/rockchip/Makefile
  for patch in ../patches/e5plus/kernel/*.patch; do
    # Already applied (the kernel tree is reused between builds)
    git apply -R --check "$patch" 2>/dev/null && continue
    if ! git apply "$patch"; then
      echo "ERROR: $patch did not apply to the kernel."
      exit 1
    fi
  done
fi

make ARCH=arm64 rk3566_optimized_linux_defconfig
CFLAGS=-Wno-deprecated-declarations make -j$(nproc) ARCH=arm64 KERNEL_DTS=rk3566 KERNEL_CONFIG=rk3566_optimized_linux_defconfig
verify_action
cd ..

# Install kernel modules
sudo make -C $KERNEL_SRC ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=../Arkbuild modules_install
sudo cp -Rv $KERNEL_SRC/lib/firmware/ Arkbuild/usr/lib/

# The E5 Plus radio is an RTL8733BS (SDIO 024C:B733), not the RTL8821CS its
# stock dtb names, and this kernel has no driver for it.  Build Realtek's vendor
# driver out of tree, pinned to a known good commit, as a module.
if [ "$UNIT" == "e5plus" ]; then
  RTL8733BS_REPO=https://github.com/newbie-461/RTL8733BS_WiFi_linux_v5.14.1.1-46.git
  RTL8733BS_COMMIT=4719bf994bc4a80c05cda4cb397ee7a39ecebe15
  (
    set -e
    rm -rf rtl8733bs
    git clone -q "$RTL8733BS_REPO" rtl8733bs
    git -C rtl8733bs checkout -q "$RTL8733BS_COMMIT"
    for patch in patches/e5plus/rtl8733bs/*.patch; do git -C rtl8733bs apply "$PWD/$patch"; done
    make -C $KERNEL_SRC M="$PWD/rtl8733bs" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
      KCFLAGS=-w CONFIG_RTL8733BS=m -j$(nproc) modules
    KVER="$(basename "$(ls -d Arkbuild/lib/modules/*/ | head -1)")"
    sudo install -D -m 0644 rtl8733bs/8733bs.ko "Arkbuild/lib/modules/$KVER/extra/8733bs.ko"
  )
  if ! ls Arkbuild/lib/modules/*/extra/8733bs.ko >/dev/null 2>&1; then
    echo "ERROR: the RTL8733BS driver did not build - the E5 Plus would have no Wi-Fi."
    exit 1
  fi
  rm -rf rtl8733bs
fi

mountpoint=mnt/boot
mkdir -p ${mountpoint}
sudo mount ${LOOP_DEV}p3 ${mountpoint}

# Copy kernel, device tree, and modules into target rootfs
KERNEL_VERSION=$(basename $(ls Arkbuild/lib/modules))
sudo cp $KERNEL_SRC/.config Arkbuild/boot/config-${KERNEL_VERSION}
sudo cp $KERNEL_SRC/arch/arm64/boot/Image ${mountpoint}/
if [ "$UNIT" == "503" ]; then
  sudo cp $KERNEL_SRC/arch/arm64/boot/dts/rockchip/${UNIT_DTB}.dtb ${mountpoint}/${UNIT_DTB}.dtb
  cp $KERNEL_SRC/arch/arm64/boot/dts/rockchip/${UNIT_DTB}.dtb $KERNEL_SRC/arch/arm64/boot/dts/rockchip/${UNIT_DTB}.dtb
else
  sudo cp $KERNEL_SRC/arch/arm64/boot/dts/rockchip/${UNIT_DTB}.dtb ${mountpoint}/
  if [[ "$UNIT" == *"353"* ]]; then
    sudo cp $KERNEL_SRC/arch/arm64/boot/dts/rockchip/${UNIT_DTB}-notimingchange.dtb ${mountpoint}/
  elif [ "$UNIT" == "rgb30" ]; then
    sudo mkdir -p Arkbuild/usr/local/bin/rgb30dtbs/
    sudo cp $KERNEL_SRC/arch/arm64/boot/dts/rockchip/${UNIT_DTB}.dtb Arkbuild/usr/local/bin/rgb30dtbs/${UNIT_DTB}.dtb.v1
    sudo cp $KERNEL_SRC/arch/arm64/boot/dts/rockchip/${UNIT_DTB}-v2.dtb Arkbuild/usr/local/bin/rgb30dtbs/${UNIT_DTB}.dtb.v2
  fi
fi

# Copy firmware blobs (follow symlinks, ignore dangling ones)
echo "Installing firmware..."
sudo mkdir -p Arkbuild/lib/firmware/
# Use rsync to handle symlinks gracefully
sudo rsync -aL --ignore-errors $KERNEL_SRC/lib/firmware/ Arkbuild/lib/firmware/ 2>/dev/null || \
 sudo cp -rL $KERNEL_SRC/lib/firmware/* Arkbuild/lib/firmware/ 2>/dev/null || true
if [ "$UNIT" == "e5plus" ]; then
  # Bluetooth core of the RTL8733BS (an RTL8723F, see firmware/rtl8723fs/README.md).
  # Also added to the initrd below, for btrtl's first attempt early in boot.
  sudo install -D -m 0644 -t Arkbuild/usr/lib/firmware/rtl_bt/ \
    firmware/rtl8723fs/rtl8723fs_fw.bin firmware/rtl8723fs/rtl8723fs_config.bin
fi

# Create uInitrd from generated initramfs
#sudo cp /usr/bin/qemu-aarch64-static Arkbuild/usr/bin/
KERNEL_VERSION=$(basename $(find Arkbuild/lib/modules -maxdepth 1 -mindepth 1 -type d))
# Create symlink so depmod/initramfs can find modules for uname -r (host kernel)
sudo touch Arkbuild/lib/modules/${KERNEL_VERSION}/modules.builtin.modinfo
call_chroot "uname() { echo ${KERNEL_VERSION}; }; export -f uname; depmod ${KERNEL_VERSION}; update-initramfs -c -k ${KERNEL_VERSION}"
#sudo rm Arkbuild/usr/bin/qemu-aarch64-static
sudo cp Arkbuild/boot/initrd.img-* ${mountpoint}/initrd.img
if ! command -v mkimage &> /dev/null; then
  sudo apt -y update
  sudo apt -y install u-boot-tools
fi
mkdir initrd

#Update uInitrd to force booting from mmcblk1p4
sudo mv ${mountpoint}/initrd.img initrd/.
cd initrd
zstd -d -c initrd.img | cpio -idmv
rm -f initrd.img
sed -i '/local dev_id\=/c\\tlocal dev_id\=\"/dev/mmcblk1p4\"' scripts/local
#Add regulatory.db and regulatory.db.p7s
mkdir -p lib/firmware
wget https://github.com/CaffeeLake/wireless-regdb/raw/refs/heads/master/regulatory.db -O lib/firmware/regulatory.db -O lib/firmware/regulatory.db
#wget -t 5 -T 60 https://git.kernel.org/pub/scm/linux/kernel/git/wens/wireless-regdb.git/plain/regulatory.db.p7s -O lib/firmware/regulatory.db.p7s
# Fix: fsck hook fails to detect root fstype during chroot build because
# /dev/mmcblk1p4 doesn't exist, so it skips copying fsck/logsave entirely.
# The initramfs scripts/functions still calls logsave unconditionally, and
# the missing binary causes exit code 127 -> panic at boot.
for bin in /sbin/fsck /sbin/logsave /sbin/e2fsck /sbin/fsck.ext4; do
  src="../Arkbuild${bin}"
  if [ -f "$src" ]; then
    cp "$src" ".${bin}"
    # Copy required shared libraries
    for lib in $(ldd "$src" 2>/dev/null | grep -o '/lib[^ ]*'); do
      mkdir -p ".$(dirname "$lib")"
      cp -n "$lib" ".$lib" 2>/dev/null || true
    done
  fi
done
# We also need to copy the 5.10 kernel compatible BT firmware files or BT will not initialize correctly
mkdir -p lib/firmware/rtl_bt/
if [[ "$UNIT" == "e5plus" ]]; then
  # RTL8733BS: its Bluetooth core is an RTL8723F (patches/e5plus/kernel/0004 teaches btrtl about it).
  sudo cp ../firmware/rtl8723fs/rtl8723fs_fw.bin ../firmware/rtl8723fs/rtl8723fs_config.bin lib/firmware/rtl_bt/
elif [[ "$UNIT" != "rgb20pro" ]] && [[ "$UNIT" != *"miniloong"* ]]; then
  sudo cp ../Arkbuild/usr/lib/firmware/rtl_bt/rtl8821cs_* lib/firmware/rtl_bt/
else
  sudo cp ../firmware/rtl8723ds/rtl8723ds_config.bin lib/firmware/rtl_bt/rtl8723d_config.bin
  sudo cp ../firmware/rtl8723ds/rtl8723ds_fw.bin lib/firmware/rtl_bt/rtl8723d_fw.bin
fi
find . | cpio -H newc -o | gzip -c > ../uInitrd
sudo mv ../uInitrd ../${mountpoint}/uInitrd
cd ..
rm -rf initrd
sudo rm -f ${mountpoint}/initrd.img

# Build uboot and resource and install it to the image
cd $KERNEL_SRC
if [[ "$UNIT" == "503" ]] || [[ "$UNIT" == *"353"* ]] || [[ "$UNIT" == *"miniloong"* ]]; then
  #cp arch/arm64/boot/dts/rockchip/${UNIT_DTB}.dtb .
  # Next line generates the resource.img file needed to flash to the image and to build the uboot
  git clone --depth=1 https://github.com/rockchip-linux/rkbin
  cd rkbin/tools
  #cp ../../arch/arm64/boot/dts/rockchip/${UNIT_DTB}.dtb .
  if [[ "$UNIT" == "503" ]]; then
    cp ../../../misc/rk3566/device_off_charging_bmps/rg503/* .
    #cp ../../arch/arm64/boot/dts/rockchip/${UNIT_DTB}.dtb .
    #cp ../../arch/arm64/boot/dts/rockchip/${UNIT_DTB}.dtb rk-kernel.dtb
  elif [[ "$UNIT" == *"miniloong"* ]]; then
    cp ../../../misc/rk3566/device_off_charging_bmps/miniloong/*.bmp .
    #cp ../../arch/arm64/boot/dts/rockchip/${UNIT_DTB}.dtb .
    cp ../../arch/arm64/boot/dts/rockchip/${UNIT_DTB}-uboot.dtb rk-kernel.dtb
  else
    cp ../../../misc/rk3566/device_off_charging_bmps/rg353/* .
  fi
  # Use Anbernic's resource.img files to provide onscreen battery charging state while off
  ./resource_tool --pack *.bmp rk-kernel.dtb
  cp resource.img ../../.
  cd ../..
  rm -rf rkbin
  #scripts/mkimg --dtb ${UNIT_DTB}.dtb
elif [[ "$UNIT" == "e5plus" ]]; then
  # The E5 Plus gets its own resource.img: U-Boot reads rk-kernel.dtb from it
  # (PMIC, display).  The RG503 one used below for the PowKiddy units describes
  # another board: its charge mode parked a reboot-with-USB in a charge screen
  # this panel cannot show, and its "LCD power" GPIO0_C2 is the left stick
  # light here.  dtb only: U-Boot charge mode is off on this board (the charging
  # screen is e5plus-offcharge, in Linux).
  git clone --depth=1 https://github.com/rockchip-linux/rkbin
  cd rkbin/tools
  cp ../../arch/arm64/boot/dts/rockchip/${UNIT_DTB}.dtb rk-kernel.dtb
  ./resource_tool --pack rk-kernel.dtb
  cp resource.img ../../.
  cd ../..
  rm -rf rkbin
else
  # For some reason, supported PowKiddy rk3566 devices need resource.img generated from the RG503 Kernel source
  git clone --recursive --depth=1 https://github.com/christianhaitian/rg503Kernel.git
  cd rg503Kernel
  make ARCH=arm64 rk3566_optimized_linux_defconfig
  CFLAGS=-Wno-deprecated-declarations make -j$(nproc) ARCH=arm64 KERNEL_DTS=rk3566 KERNEL_CONFIG=rk3566_optimized_linux_defconfig
  cp arch/arm64/boot/dts/rockchip/rk3566.dtb .
  scripts/mkimg --dtb rk3566.dtb
  cp resource.img ../.
  cd ..
fi
git clone --depth=1 https://github.com/christianhaitian/rk356x-uboot.git
git clone https://github.com/christianhaitian/rkbin.git
mkdir -p ./prebuilts/gcc/linux-x86/aarch64/
OPT_TOOLCHAIN_DIR="/opt/toolchains/gcc-linaro-6.3.1-2017.05-x86_64_aarch64-linux-gnu"
LOCAL_TOOLCHAIN_DIR="./prebuilts/gcc/linux-x86/aarch64/gcc-linaro-6.3.1-2017.05-x86_64_aarch64-linux-gnu"
if [[ -d "$OPT_TOOLCHAIN_DIR" && ! -d "$LOCAL_TOOLCHAIN_DIR" ]]; then
    ln -s "$OPT_TOOLCHAIN_DIR" "$LOCAL_TOOLCHAIN_DIR"
fi
cd rk356x-uboot
cp ../resource.img rk3566_tool/Image/
./make.sh rk3566
./make.sh trust
# Since I don't know how to build a proper loader1.img file
# We'll cheat and use the one from Anbernic's stock OS
# More information on how it was obtained is available from
# here: https://github.com/christianhaitian/rkbin/commit/1302e7af2b34f18496997f52e3cf5a358829db73
cp ../rkbin/bin/rk35/Anbernic_Stock_loader1.img .
#sudo cp uboot.img ../../Arkbuild/usr/local/bin/uboot.img.jelos

echo "Flashing loader1.img, trust.img, uboot.img and resource.img..."
sudo dd if=Anbernic_Stock_loader1.img of=$LOOP_DEV bs=$SECTOR_SIZE seek=64 conv=notrunc
sudo dd if=trust.img of=$LOOP_DEV bs=$SECTOR_SIZE seek=8192 conv=notrunc
sudo dd if=uboot.img of=$LOOP_DEV bs=$SECTOR_SIZE seek=16384 conv=notrunc
sudo dd if=rk3566_tool/Image/resource.img of=$LOOP_DEV bs=$SECTOR_SIZE seek=24576 conv=notrunc

# Last but not least, create undervolt dtbo files and place them in an overlays subfolder in the fat partition
sudo mkdir -p ../../${mountpoint}/overlays
for DTS in light medium maximum
do
  wget -t 3 -T 60 --no-check-certificate https://raw.githubusercontent.com/christianhaitian/rk3566_core_builds/refs/heads/master/shell-scripts/undervolt/undervolt.${DTS}.dts
  dtc -@ -I dts -O dtb -o undervolt.${DTS}.dtbo undervolt.${DTS}.dts
  sudo mv undervolt.${DTS}.dtbo ../../${mountpoint}/overlays/
done

cd ../..
