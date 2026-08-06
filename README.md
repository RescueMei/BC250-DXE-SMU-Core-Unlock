# SUPERSEDED: See the V2 here

https://github.com/RescueMei/BC250-DXEv2-BIOSMOD

# CAUTION: ONLY USE THIS ON BC250s THAT HAVE BEEN VERIFIED TO HAVE ALL 8 CPU CORES FUNCTIONAL VIA ANOTHER METHOD FIRST

Credit to https://github.com/rw-r-r-0644 for creating an implementation of this unlock, which I used as a reference when making this driver

## For how to use the patch to apply to the BC250_3.00_CHIPSETMENU.ROM BIOS, please see the bottom of this readme

# Why a DXE Driver?

This is so it can run extremely early in the boot process and add a minimal amount of time to the boot of BC250s that are already known to have good cores. By placing this driver in the bios, it prevents drive failures, updates, or OS reinstalls from breaking the cpu core unlock.

Like the other methods of core unlock, for some reason it causes the reported GPU clocks to be wrong. I have not noticed any negative impact on GPU performance however, so it appears to just be a visual/reporting issue?

# BC250-DXE-SMU-Core-Unlock

It is a standalone EDK II DXE driver for the AMD BC-250 that mirrors the SMU core-unlock
sequence from rw-r-r-0664, from this repo: https://github.com/rw-r-r-0644/bc250-core-unlock

This build script generates an `.ffs` driver for insertion into an AMI BIOS DXE firmware
volume with UEFITool.

## Behavior

The driver reads the core presence mask at SMN `0x0115A870` via PCI config space on `00:00.0`.

- If the low byte is `0xFF`: exit and boot normally.
- If the low byte is `0x77`: send SMU Queue 3 message `0x98`, verify the mask becomes `0xFF`,
  then issue a warm reboot.
- If the low byte is anything else: exit and boot normally to avoid lockout on abnormal masks.

This should prohibit it from unintentionally enabling defective cores on unexpected core masks.



## Files

```text
Bc250CoreUnlockPkg/
  Bc250CoreUnlockPkg.dec
  Bc250CoreUnlockPkg.dsc
  Bc250CoreUnlockDxe/
    Bc250CoreUnlockDxe.inf
    Bc250CoreUnlockDxe.c
scripts/
  build_ffs.sh
```

## Prerequisites for Building

### Default containerized path

- `podman` installed locally (or `docker` if you set `CONTAINER_ENGINE=docker`)
- network access on first run to pull the Tianocore dev image and clone `edk2`

By default, the build helper uses the Tianocore Fedora 41 development container:

- `ghcr.io/tianocore/containers/fedora-41-dev:latest`

It maintains a reusable `edk2` checkout under:

```text
.cache/edk2
```

### Optional host build path

If you already have a working host-side EDK II checkout, you can still build without
the container by setting:

```bash
export NO_CONTAINER=1
export EDK2_DIR=/path/to/edk2
```

That mode expects:

- a working `edk2` checkout
- BaseTools already built in that checkout
- a GCC toolchain compatible with your EDK II configuration

## Configuration

Optional overrides:

```bash
export TARGET=RELEASE
export TOOL_CHAIN_TAG=GCC5
export ARCH=X64
export CONTAINER_ENGINE=podman
export EDK2_IMAGE=ghcr.io/tianocore/containers/fedora-41-dev:latest
export EDK2_REPO=https://github.com/tianocore/edk2.git
export EDK2_REF=master
```

## Build `.efi` and `.ffs`

Run:

```bash
bash scripts/build_ffs.sh
```

On the default path, the script will:

1. start the Fedora 41 Tianocore dev container
2. clone or reuse an `edk2` checkout under `.cache/edk2`
3. initialize submodules and build BaseTools
4. build `MeiMeiDXEv2_BC250CoreUnlock.efi`
5. wrap it into a DXE driver `.ffs` using `GenSec` and `GenFfs`

Artifacts are emitted to:

```text
Build/Output/MeiMeiDXEv2_BC250CoreUnlock.efi
Build/Output/MeiMeiDXEv2_BC250CoreUnlock.ffs
```

Use the `.ffs` file for UEFITool insertion.

## Host build fallback

If you prefer using an existing local `edk2` tree instead of the container:

```bash
export NO_CONTAINER=1
export EDK2_DIR=/path/to/edk2
bash scripts/build_ffs.sh
```

## UEFITool insertion guidance

1. Open the AMI BC250 BIOS image in UEFITool.
2. Locate a DXE firmware volume.
3. Insert `Build/Output/MeiMeiDXEv2_BC250CoreUnlock.ffs` as a driver file in that DXE volume.
4. Save the modified image and flash only if you have a verified recovery path.

This driver is designed to be a normal DXE driver FFS file, with:

- a PE32 section containing the compiled module
- a UI section named `MeiMeiDXEv2_BC250CoreUnlock`
- `EFI_FV_FILETYPE_DRIVER`

## CAUTION

- Firmware modification can brick the board.
- Please have an external SPI programmer or another recovery method before flashing.
- The unlock does not persist across cold boots; the driver will re-trigger the warm-reset path
  again after each cold boot if the mask returns to `0x77`.
- Disabled cores may be defective. Stress-test thoroughly before relying on them AND BEFORE USING THIS DRIVER.
- The driver intentionally refuses to touch masks other than `0x77` and `0xFF`, so we do not try and enable cores that may be defective.

## Reference

This project’s hardware sequence is based on:

- `https://github.com/rw-r-r-0644/bc250-core-unlock/blob/main/bc250-unlock-cores.py`

# Using the Patch

1) Ensure xdelta3 and md5sum are available
2) Place BC250_3.00_CHIPSETMENU.ROM in the Patch directory.
3) Run ApplyDeltaPatch.sh, which will generate the final BC250 bios rom file.
4) Verify the MD5 hash matches the following:

- d298267029fbbe9d29b0bfa0db5fbf9e  BC250_3.00_CHIPSETMENU.ROM
- 6475614980a40a23c412d4deb5273876  BC250_3.00_MeiMeiDXE.ROM
- 18a48098f95da36f45b93b07ea72a18b  BC250_3.00_CHIPSETMENU-to-BC250_3.00_MeiMeiDXE.xdelta

5) If the hashes match, you should be set to flash it to the BC250 via whichever method you prefer.