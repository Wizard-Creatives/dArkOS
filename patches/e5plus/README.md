# GameMT E5 Plus (`make e5plus`)

The GameMT E5 Plus is an RK3566 handheld with a 720x1280 MIPI DSI panel
mounted landscape, two TF slots, an RTL8733BS Wi-Fi/Bluetooth radio, an RK817
PMIC/codec, two analog sticks with light rings, and the RGB30's button set.
Its manufacturer only ever shipped a hard-to-find 4.19 JELOS/ROCKNIX based
image, and the board is not in christianhaitian's 5.10 kernel tree, so
everything needed to boot it is carried here.

This port was first done for dArkMoss
(MarsInsanity/dArkMoss, branch `claude/sweet-johnson-rnbznk`), where the
hardware support was brought up on a real unit, and has been moved
here so the E5 Plus has a home that runs the full dArkOS userland
(EmulationStation, RetroArch, the standalone emulators, PortMaster).

## What is in this folder

| Path | What it is |
| --- | --- |
| `kernel/rk3566-e5plus.dts` | The board's device tree. Structure from `rk3566-rgb30.dts`; every board value (panel init sequence and timings, button and stick-mux pins, PMIC rails, IO domains, battery, charger detect, SD/SDIO layout) from the dtb the stock image boots with, read back from a running unit. |
| `kernel/0001-singleadcjoy-stick-axis-options.patch` | `switch-rxy`, `invert-absry`, `invert-absx`, `invert-absy` for singleadcjoy. The right stick is wired with X/Y swapped and Y inverted; the left stick is not inverted the way the driver assumes. |
| `kernel/0002-asoc-pin-card-index-from-dt.patch` | `linux,snd-card-index` on an ASoC card's DT node. On this board HDMI otherwise wins the race to ALSA card 0. |
| `kernel/0003-rk817-amp-gpios-follow-path-changes.patch` | Switches the speaker/headphone amp enables when `Playback Path` changes during playback, not only when a stream starts, so plugging headphones in mid-game turns the speaker off. |
| `kernel/0004-btrtl-support-rtl8723f-uart.patch` | Teaches btrtl the RTL8723F Bluetooth core of the RTL8733BS (UART). Firmware in `firmware/rtl8723fs`. |
| `kernel/0005-rk817-not-save-power-en.patch` | Honours the `not-save-power-en` property (set by the E5 Plus dts, and by the other RK3566 units' too): skip restoring RK817 POWER_EN on reboot. dArkMoss carries it for every unit; here it is applied for the E5 Plus only, so the unit runs the kernel it was brought up on. |
| `rtl8733bs/*.patch` | Build Realtek's out-of-tree RTL8733BS driver (pinned commit, see `build_kernel-rk3566.sh`) for this kernel as `8733bs.ko`. |
| `retroarch/retroarch-patch-0017-e5plus-rotate90.patch` | Turns RetroArch's RGA rotated build from 270 to 90 degrees for this panel (see below). |

The kernel patches are applied for `UNIT=e5plus` only. The kernel tree
(`main`) is reused between local builds, so `build_kernel-rk3566.sh` takes
them back out before building any other unit: 0003 and 0005 change code every
RK817 unit runs.

## Elsewhere in the tree

- `build_e5plus.sh`, `make e5plus`: the full dArkOS build, the same set of
  components as the RGB30.
- `build_kernel-rk3566.sh`: adds the dts and patches, builds `8733bs.ko`,
  installs the Bluetooth firmware (rootfs and initrd), and packs the board's own
  `resource.img` (dtb only; U-Boot charge mode is off on this board).
- `scripts/e5plus/`:
  - `e5plus-audio-path.sh` + `e5plus-jackd.service`: speaker or headphones,
    following the jack switch's live level. `rk_headset` misses bounced
    insertions, and `headphone-audio-switch.sh` keys on a debug message this
    kernel does not print, so it is not installed on this unit.
  - `e5plus-lights.sh` + `e5plus-lights.service`, and
    `Options > Joystick Lights`: stick rings and button backlights, cycling
    all on -> stick rings off -> all off. The choice is restored at boot.
  - `e5plus-offcharge.py` + `.service`: the charging screen when plugging in a
    charger switched the unit on. Short press of power shows the level again,
    holding power boots dArkOS, unplugging powers off.
- `misc/rk3566/device_off_charging_bmps/e5plus/`: the charging screen images.
- `firmware/rtl8723fs/`: Bluetooth firmware, with its source and checksums.
- `logos/unrotated/dArkose5plus.png`: the 1280x720 boot logo.
- Per-unit configs (`*.e5plus`) are symlinks: the RG353M/RGB30 input configs
  (same `retrogame_joypad` button set) and RG503 configs where the 16:9
  screen matters (ES layout, Drastic layout, mupen64plus, launch image).

## Screen rotation

The panel is portrait (720x1280) and is turned 90 degrees clockwise
(`fbcon=rotate:1`), the opposite way to the Miniloong Pocket 1's (270).

| Component | How it is rotated |
| --- | --- |
| Console, boot logo, dialog tools | `fbcon=rotate:1`; `hdmi-test.sh` sets 0 on HDMI and 1 on the panel. |
| EmulationStation, PortMaster ports, SDL2 apps (PPSSPP OpenGL, Drastic, mupen64plus, ScummVM, OpenBOR, ...) | SDL2 built with the Miniloong's RGA kmsdrm rotation patch, `ROT_270` changed to `ROT_90` (`build_sdl2.sh`). |
| RetroArch (64 and 32 bit, `gl` driver) | The RGA rotated build (`retroarch-rgarotated`) with `retroarch-patch-0017-e5plus-rotate90.patch`; the stock norotation patch's context is moved to match so the second build still applies (`build_retroarch.sh`). |
| DuckStation standalone | `Rotation = Rotate90` on the panel, 0 on HDMI (`standalone-duckstation`). |
| mupen64plus standalone | Resolution swapped for the portrait panel (`n64.sh`). |

## Status

Checked while porting (no hardware in the loop):

- The dts compiles against christianhaitian/kernel_5_10_226 and all five
  kernel patches apply to it cleanly.
- The RetroArch rotation patch and the adjusted norotation patch apply, in
  build order, to RetroArch v1.22.2 with the stock rk3566_core_builds patches.

Brought up on a real unit under dArkMoss, per its commit history: boot and
panel, buttons and sticks (axes corrected on hardware), charger detection and
the charging screen, the speaker level and headphone jack switching, and the
stick lights. The Wi-Fi (RTL8733BS driver) and Bluetooth (RTL8723F firmware)
fixes were worked out from the unit's logs and build, but that history does
not record either confirmed working end to end, so test them first.

**Not yet tested on hardware under dArkOS** (the dArkMoss image used
spruceOS as its frontend, so none of the dArkOS frontend/emulator side ran on
the unit):

- EmulationStation, RetroArch and the SDL2 apps with the 90 degree rotation.
- Hotkeys: the RGB30's ogage build (`R3` + D-pad up/down for brightness,
  `R3` + D-pad left/right for volume; the E5 Plus has no working volume keys).

**Known not rotated on the E5 Plus** (these hard-code the Miniloong's 270
degree rotation or none; use the RetroArch core instead):

- retrorun (Dreamcast/Naomi/Atomiswave/Saturn "retrorun" emulator choice):
  its Miniloong rotation is baked into retrorun's `miniloong` branch, keyed
  on the Miniloong's device name.
- Dolphin standalone and PPSSPP's `standalone-vulkan` choice: their rotation
  patches detect the Miniloong / any portrait panel and rotate 270 degrees.
- RetroArch's `vulkan` driver (the default `gl` driver is rotated).
- Kodi.
