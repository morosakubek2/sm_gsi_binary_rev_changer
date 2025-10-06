# Samsung Firmware GSI Builder with Model and Signer Update

**Educational Purpose Only**: This project is intended solely for educational purposes to demonstrate firmware modification techniques for Samsung devices. Using this script on a real device carries significant risks, including **bootloop** or **hardbrick**, which may render your device unusable. Proceed at your own risk, and ensure you have a full backup of your data (photos, files, Google/Samsung accounts) before attempting any modifications. The author is not responsible for any damage to your device.

**Requirement**: Your device's recovery mode **must support access to `fastbootd`** (dynamic partition flashing mode). Without `fastbootd` support, the generated images cannot be flashed correctly, increasing the risk of bricking your device.

This repository contains the `build_gsi_for_fastbootd.sh` script, designed to generate either fastboot-compatible images or an experimental modified `AP_*.tar.md5` package for Samsung devices (e.g., Galaxy Z Flip 3, SM-F711B). The script supports replacing the `system.img` with a Generic System Image (GSI), updating the `SignerVer02` section, and optionally modifying the device model string (e.g., from `F711BXXS8HXF2` to `F711BXXSFJYGB`) across firmware images like `boot.img`, `vendor_boot.img`, and `userdata.img`. It integrates with `extract_params.py` and `update_signer.py` to extract parameters, including the current binary revision (bit revision) and `SignerVer02` section, from a provided `--last-image` (e.g., `misc.bin.lz4`) extracted from the currently installed firmware and apply them to another firmware (AP package).

**Warning**: The `--experimental-model-replace` and `--build-ap` options are highly experimental and may not work as expected, especially with Odin. Using these features, or the script in general, can lead to **bootloop** or **hardbrick**. Ensure your device's recovery supports `fastbootd` before proceeding.

## Features

- Processes `AP_*.tar.md5` archives, handling images like `super.img.lz4`, `boot.img.lz4`, `vendor_boot.img.lz4`, etc.
- Replaces `system.img` in `super.img` with a provided GSI (supports `.xz` format).
- Extracts `SignerVer02` section and device model from a `--last-image` (e.g., `misc.bin.lz4`) extracted from the currently installed firmware to obtain the current binary revision (bit revision) and applies them to another firmware (AP package) for images like `boot.img`, `vendor_boot.img`, etc. (except `super.img`).
- **Experimental**: Replaces the device model string across all occurrences in images (outside `SignerVer02`) with `--experimental-model-replace`.
- **Experimental**: Generates a modified `AP_*.tar.md5` package instead of fastboot images with `--build-ap` (likely incompatible with Odin).
- Skips excluded images (default: `recovery.img`).
- Supports sparse images (`simg2img`, `img2simg`) and LZ4 compression.
- Automatically detects and repacks `super.img` partitions using `lpunpack` and `lpmake`.
- Generates output in `fastboot_images/` (default) or `modified_ap/` (with `--build-ap`).

## Requirements

- **Operating System**: Linux (e.g., Ubuntu, Artix Linux, or any distribution with required tools).
- **Tools**:
  - `android-tools` (includes `simg2img`, `img2simg`, `lpunpack`, `lpmake`)
  - `lz4`
  - `python3`
  - `tar`
  - `xz`
  - `md5sum`
  - `jq` (for JSON parsing)
  - A hex editor (e.g., `xxd`, `hexdump`, or GUI tools like `Bless` or `Hex Fiend`) to verify `SignerVer02` in `--last-image`
- **Hardware**:
  - 40GB free disk space (for `super.img` processing).
  - 16GB+ RAM recommended (for sparse image conversion).
- **Firmware Files**:
  - Source AP package (e.g., `AP_F711BXXS8HXF2_*.tar.md5`) from [samfw.com](https://samfw.com).
  - Optional: GSI image (e.g., `system.img` or `system.img.xz`). **Recommended**: VoltageOS GSI (e.g., `Voltage-A16_treble_arm64_bN.img.xz`) due to its sandboxed Play Services, which allows suspending Play Services for improved security and battery efficiency.
  - Optional: Last image (e.g., `misc.bin.lz4`) extracted from the currently installed firmware, containing the `SignerVer02` section and binary revision.
- **Device**:
  - Samsung device with an unlocked bootloader (e.g., Galaxy Z Flip 3, SM-F711B).
  - Recovery mode must support `fastbootd` (verify by booting into recovery and checking for `fastbootd` mode).

## Installation

1. **Install dependencies** (example for Ubuntu):
   ```bash
   sudo apt update
   sudo apt install android-tools-adb android-tools-fastboot lz4 python3 tar xz-utils md5sum jq xxd
   ```
   For Artix Linux (Arch-based):
   ```bash
   sudo pacman -S android-tools lz4 python tar xz jq xxd
   ```
   If `android-tools` is unavailable, use AUR:
   ```bash
   yay -S android-tools
   ```

2. **Clone the repository**:
   ```bash
   git clone https://github.com/morosakubek2/sm_gsi_binary_rev_changer.git
   cd sm_gsi_binary_rev_changer
   ```

3. **Make scripts executable**:
   ```bash
   chmod +x build_gsi_for_fastbootd.sh extract_params.py update_signer.py
   ```

## Usage

1. **Prepare firmware**:
   - Download the source AP package (e.g., `AP_F711BXXS8HXF2_*.tar.md5`) from [samfw.com](https://samfw.com).
   - Optional: Place a GSI image in the same directory. **Recommended**: Use VoltageOS GSI (e.g., `Voltage-A16_treble_arm64_bN.img.xz`) for its sandboxed Play Services, which allows suspending Play Services to enhance security and save battery life. Download from [VoltageOS official sources](https://voltageos.org) or trusted repositories.
   - Optional: Extract a `--last-image` (e.g., `misc.bin.lz4`) from the currently installed firmware on your device to obtain the current binary revision and `SignerVer02` section. This ensures compatibility with the device's current firmware state and applies these parameters to another firmware (AP package). This can typically be done using a custom recovery (e.g., TWRP) or tools like `dd` via root access:
     ```bash
     adb shell
     su
     dd if=/dev/block/by-name/misc of=/sdcard/misc.bin
     lz4 /sdcard/misc.bin misc.bin.lz4
     adb pull /sdcard/misc.bin.lz4
     ```
     **Verify `SignerVer02` in `--last-image`**:
     - Use a hex editor to confirm the image contains the `SignerVer02` section:
       ```bash
       xxd misc.bin.lz4 | grep SignerVer02
       ```
       or, if the image is LZ4-compressed, decompress first:
       ```bash
       lz4 -d misc.bin.lz4 misc.bin
       xxd misc.bin | grep SignerVer02
       ```
       - Expected output should include `SignerVer02` (e.g., `SignerVer02` followed by model and revision data). If not found, try another image (e.g., `boot.img` or `vbmeta.img`) from the current firmware.

2. **Verify `fastbootd` support**:
   - Boot your device into recovery mode:
     ```bash
     adb reboot recovery
     ```
   - Navigate to "Enter fastboot" or similar in recovery (e.g., using volume keys and power button).
   - Check if `fastbootd` is detected:
     ```bash
     fastboot devices
     ```
   - If no devices are listed or `fastbootd` is not supported, install a custom recovery (e.g., TWRP) with `fastbootd` support. Without `fastbootd`, flashing dynamic partitions will fail, risking a **hardbrick**.

3. **Run the script**:
   ```bash
   ./build_gsi_for_fastbootd.sh [options] <input_tar>
   ```

   **Options**:
   - `-k`, `--keep-files`: Keep temporary files in `/tmp` for debugging (default: delete).
   - `-v`, `--verbose`: Enable verbose output.
   - `-m`, `--experimental-model-replace`: Enable experimental replacement of the device model (e.g., `F711BXXS8HXF2` to `F711BXXSFJYGB`) outside `SignerVer02`.
   - `-b`, `--build-ap`: [EXPERIMENTAL] Generate a modified `AP_*.tar.md5` package instead of fastboot images (likely incompatible with Odin).
   - `-g`, `--gsi <file>`: GSI image to replace `system.img` (supports `.xz`). Recommended: VoltageOS GSI for sandboxed Play Services.
   - `-l`, `--last-image <file>`: Image extracted from the currently installed firmware to obtain the current binary revision and `SignerVer02` section (e.g., `misc.bin.lz4`) and apply to another firmware (AP package).
   - `-o`, `--output <dir>`: Output directory (default: `./fastboot_images` or `./modified_ap` for `--build-ap`).
   - `-e`, `--exclude <file>`: Exclude specific images from processing (default: `recovery.img`).

   **Examples**:
   - Generate fastboot images with VoltageOS GSI:
     ```bash
     ./build_gsi_for_fastbootd.sh -v -g Voltage-A16_treble_arm64_bN.img.xz AP_F711BXXS8HXF2_F711BXXS8HXF2_MQB81265444_REV00_user_low_ship_MULTI_CERT_meta_OS14.tar.md5
     ```
     Output: `fastboot_images/` with `super.img`, `boot.img`, `vendor_boot.img`, etc.
   - With experimental model replacement and `--last-image`:
     ```bash
     ./build_gsi_for_fastbootd.sh -v -m -l misc.bin.lz4 -g Voltage-A16_treble_arm64_bN.img.xz AP_F711BXXS8HXF2_F711BXXS8HXF2_MQB81265444_REV00_user_low_ship_MULTI_CERT_meta_OS14.tar.md5
     ```
     Output: `fastboot_images/` with updated `SignerVer02` and model (if `-m` is used).
   - [EXPERIMENTAL] Generate modified AP package:
     ```bash
     ./build_gsi_for_fastbootd.sh -v -b -l misc.bin.lz4 -g Voltage-A16_treble_arm64_bN.img.xz AP_F711BXXS8HXF2_F711BXXS8HXF2_MQB81265444_REV00_user_low_ship_MULTI_CERT_meta_OS14.tar.md5
     ```
     Output: `modified_ap/AP_F711BXXSFJYGB_F711BXXSFJYGB_modified.tar.md5` (likely incompatible with Odin).

4. **Flash the output**:
   - **For fastboot images** (recommended):
     - Boot your device into `fastbootd` mode (via recovery).
     - Flash images:
       ```bash
       fastboot flash super fastboot_images/super.img
       fastboot flash boot fastboot_images/boot.img
       fastboot flash vendor_boot fastboot_images/vendor_boot.img
       fastboot reboot
       ```
   - **For experimental AP package** (not recommended):
     - Install Wine and Odin:
       ```bash
       sudo apt install wine
       ```
     - Download Odin from [samfw.com](https://samfw.com).
     - Run Odin:
       ```bash
       wine /path/to/odin.exe
       ```
     - Load:
       - AP: `modified_ap/AP_*.tar.md5`
       - CP: `CP_*.tar.md5` (from current firmware for modem compatibility)
       - CSC: `CSC_*.tar.md5` (or `HOME_CSC_*.tar.md5` to preserve data, if possible)
       - Skip BL to avoid bootloader issues.
     - Enter Download Mode (Vol Down + Power, connect USB, press Vol Up) and flash.
     - **Warning**: The experimental AP package is likely incompatible with Odin, increasing the risk of bootloop or hardbrick.

## Notes

- **Educational Use Only**: This script is for learning purposes. Using it on a device can cause **bootloop** or **hardbrick**. Always verify `fastbootd` support in recovery before flashing.
- **Recommended GSI**: VoltageOS is recommended due to its sandboxed Play Services, which allows suspending Play Services for improved security and battery efficiency. Download from [VoltageOS official sources](https://voltageos.org) or trusted repositories.
- **Temporary Files**: Use `-k` to preserve temporary files in `/tmp` for
