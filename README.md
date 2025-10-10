# Samsung Firmware GSI Builder with Model and Signer Update

**Educational Purpose Only**: This project is intended solely for educational purposes to demonstrate firmware modification techniques for Samsung devices. Using this script on a real device carries significant risks of **bootloop** or **hardbrick**, potentially rendering your device unusable. Proceed at your own risk and ensure a full backup of your data (photos, files, Google/Samsung accounts) before attempting any modifications. The author is not responsible for any damage to your device.

**Requirement**: Your device's recovery mode **must support `fastbootd`** (dynamic partition flashing mode). Without `fastbootd` support, the generated images cannot be flashed correctly, increasing the risk of bricking your device.

The `build_gsi_for_fastbootd.sh` script generates fastboot-compatible images or an experimental `AP_*.tar.md5` package for Samsung devices (e.g., Galaxy Z Flip 3, SM-F711B). It supports optional replacement of `system.img` with a Generic System Image (GSI), updates the `SignerVer02` section, and modifies the device model string (e.g., from `F711BXXU6GWL1` to `F711BXXSFJYGB`) across images like `boot.img`, `vendor_boot.img`, `userdata.img`, etc. (excluding `super.img`). It uses `extract_params.py` and `update_signer.py` to extract parameters (including binary revision and `SignerVer02` section) from a `--last-image` (e.g., `misc.bin.lz4`) from the currently installed firmware and apply them to another AP package.

**Warning**: The `--experimental-model-replace` and `--build-ap` options are highly experimental and may not work as expected, especially with Odin. Using this script can lead to **bootloop** or **hardbrick**. Ensure your device's recovery supports `fastbootd`.

## Features

- Processes `AP_*.tar.md5` archives containing images like `super.img.lz4`, `boot.img.lz4`, `vendor_boot.img.lz4`, etc.
- Handles various image formats (`.img`, `.bin`, ELF like `modem.bin`) after LZ4 decompression, converting sparse to raw (`simg2img`) for modifications via `update_signer.py` and back to sparse (`img2simg`) if needed.
- Optionally replaces `system.img` in `super.img` with a provided GSI (supports `.xz`).
- Extracts `SignerVer02` section and device model from `--last-image` (e.g., `misc.bin.lz4`) and applies them to another AP package.
- Allows specifying the old model string with `--model` (overrides filename detection).
- **Experimental**: Replaces the device model string across all image occurrences (outside `SignerVer02`) with `--experimental-model-replace`.
- **Experimental**: Generates a modified `AP_*.tar.md5` package instead of fastboot images with `--build-ap` (likely incompatible with Odin).
- Excludes specified images (default: `recovery.img`, `vbmeta.img`).
- Automatically unpacks and repacks `super.img` using `lpunpack` and `lpmake`.
- Generates a complete `fastboot flash` command listing all output images (e.g., `fastboot flash boot boot.img dtbo dtbo.img misc misc.bin ... && fastboot reboot`).
- Outputs to `fastboot_images/` (default) or `modified_ap/` (with `--build-ap`).

## Requirements

- **Operating System**: Linux (e.g., Ubuntu, Artix Linux, or any distro with required tools).
- **Tools**:
  - `android-tools` (`simg2img`, `img2simg`, `lpunpack`, `lpmake`)
  - `lz4`
  - `python3`
  - `tar`
  - `xz`
  - `md5sum`
  - `jq` (for JSON parsing)
  - Hex editor (e.g., `xxd`, `hexdump`) to verify `SignerVer02`
- **Hardware**:
  - 20GB free disk space (for `super.img` processing).
  - 16GB+ RAM recommended (for sparse image conversion).
- **Firmware Files**:
  - Source AP package (e.g., `AP_F711BXXU6GWL1_*.tar.md5`) from [samfw.com](https://samfw.com).
  - Optional: GSI image (e.g., `Voltage-5.1_treble_arm64-ab-20250929.img.xz`). **Recommended**: VoltageOS GSI due to its sandboxed Play Services, which allows suspending Play Services (without errors) for improved security and battery efficiency. Source from [Doze-off/voltage_a16_treble](https://github.com/Doze-off/voltage_a16_treble) or the archived [cawilliamson/treble_voltage](https://github.com/cawilliamson/treble_voltage).
  - Optional: `--last-image` (e.g., `misc.bin.lz4`) from the device's current firmware, containing `SignerVer02`.
- **Device**:
  - Samsung device with an unlocked bootloader (e.g., Galaxy Z Flip 3, SM-F711B).
  - Recovery mode must support `fastbootd` (verify in recovery).

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

3. **Set script permissions**:
   ```bash
   chmod +x build_gsi_for_fastbootd.sh extract_params.py update_signer.py
   ```

## Usage

1. **Prepare firmware**:
   - Download the source AP package (e.g., `AP_F711BXXU6GWL1_*.tar.md5`) from [samfw.com](https://samfw.com).
   - Optional: Obtain a GSI image, preferably VoltageOS (e.g., `Voltage-5.1_treble_arm64-ab-20250929.img.xz`) from [Doze-off/voltage_a16_treble](https://github.com/Doze-off/voltage_a16_treble) or the archived [cawilliamson/treble_voltage](https://github.com/cawilliamson/treble_voltage). VoltageOS is recommended due to its sandboxed Play Services, which allows suspending Play Services (without errors) for improved security and battery efficiency.
   - Optional: Extract a `--last-image` (e.g., `misc.bin.lz4`) from the device's current firmware to obtain the binary revision and `SignerVer02`. Use custom recovery (e.g., TWRP) or `dd` with root:
     ```bash
     adb shell
     su
     dd if=/dev/block/by-name/misc of=/sdcard/misc.bin
     lz4 /sdcard/misc.bin misc.bin.lz4
     adb pull /sdcard/misc.bin.lz4
     ```
     **Verify `SignerVer02`**:
     ```bash
     lz4 -d misc.bin.lz4 misc.bin
     xxd misc.bin | grep SignerVer02
     ```
     Expect output containing `SignerVer02`. If absent, try another image (e.g., `boot.img`).
   - Optional: Specify the old model string with `--model` (e.g., `F711BXXU6GWL1`) if filename detection fails.

2. **Verify `fastbootd` support**:
   - Boot into recovery mode:
     ```bash
     adb reboot recovery
     ```
   - Navigate to "Enter fastboot" in recovery.
   - Check for `fastbootd`:
     ```bash
     fastboot devices
     ```
   - If no devices are detected or `fastbootd` is unsupported, install a custom recovery (e.g., TWRP) with `fastbootd` support.

3. **Run the script**:
   ```bash
   ./build_gsi_for_fastbootd.sh [options] <input_tar>
   ```

   **Options**:
   - `-k`, `--keep-files`: Keep temporary files in `/tmp` for debugging (default: deleted).
   - `-v`, `--verbose`: Enable verbose output.
   - `-m`, `--model <string>`: Specify the old model string (e.g., `F711BXXU6GWL1`).
   - `-n`, `--experimental-model-replace`: Enable experimental model string replacement outside `SignerVer02`.
   - `-b`, `--build-ap`: [Experimental] Generate a modified `AP_*.tar.md5` package (likely incompatible with Odin).
   - `-g`, `--gsi <file>`: GSI image to replace `system.img` (supports `.xz`, optional).
   - `-l`, `--last-image <file>`: Image from current firmware (e.g., `misc.bin.lz4`) for parameter extraction.
   - `-o`, `--output <dir>`: Output directory (default: `./fastboot_images` or `./modified_ap` for `--build-ap`).
   - `-e`, `--exclude <file>`: Exclude images from processing (default: `recovery.img`, `vbmeta.img`).

   **Examples**:
   - Process AP package without GSI:
     ```bash
     ./build_gsi_for_fastbootd.sh -v -m F711BXXU6GWL1 AP_F711BXXU6GWL1_*.tar.md5
     ```
   - With VoltageOS GSI and `--last-image`:
     ```bash
     ./build_gsi_for_fastbootd.sh -l misc.bin.lz4 -v -g Voltage-5.1_treble_arm64-ab-20250929.img.xz AP_F711BXXU6GWL1_F711BXXU6GWL1_MQB74615198_REV00_user_low_ship_MULTI_CERT_meta_OS14.tar.md5 -o v5.1
     ```
   - With experimental model replacement and excluded `modem.bin`:
     ```bash
     ./build_gsi_for_fastbootd.sh -v -n -m F711BXXU6GWL1 -l misc.bin.lz4 -g Voltage-5.1_treble_arm64-ab-20250929.img.xz -e modem AP_F711BXXU6GWL1_*.tar.md5 -o v5.1
     ```
   - [Experimental] Generate modified AP package:
     ```bash
     ./build_gsi_for_fastbootd.sh -v -b -m F711BXXU6GWL1 -l misc.bin.lz4 AP_F711BXXU6GWL1_*.tar.md5
     ```

4. **Flash the output**:
   - **For fastboot images** (recommended):
     - Boot into `fastbootd` mode via recovery.
     - Use the generated `fastboot flash` command, e.g.:
       ```bash
       fastboot flash boot boot.img dtbo dtbo.img misc misc.bin persist persist.img userdata userdata.img vbmeta_system vbmeta_system.img vendor_boot vendor_boot.img super super.img && fastboot reboot
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
     - Load AP, CP, CSC (skip BL) and flash in Download Mode.
     - **Warning**: The experimental AP package is likely incompatible with Odin.

## Notes

- **Image Format Handling**: The script processes `.img`, `.bin`, and ELF (e.g., `modem.bin`) images after LZ4 decompression. Byte-level modifications via `update_signer.py` work across all binary formats, but ELF files may risk corruption due to their structured headers. Exclude them with `-e modem` if unnecessary.
- **Fastboot Command**: The script generates a complete `fastboot flash` command listing all output images (e.g., `boot.img`, `misc.bin`, `super.img`), mapping filenames to partitions (e.g., `misc.bin` to `misc`), and ending with `&& fastboot reboot`.
- **Recommended GSI**: VoltageOS GSI (e.g., `Voltage-5.1_treble_arm64-ab-20250929.img.xz`) is recommended due to its sandboxed Play Services, which allows suspending Play Services (without errors) for improved security and battery efficiency. Source from [Doze-off/voltage_a16_treble](https://github.com/Doze-off/voltage_a16_treble) or the archived [cawilliamson/treble_voltage](https://github.com/cawilliamson/treble_voltage).
- **Temporary Files**: Use `-k` to preserve `/tmp` files for debugging.
- **Hardware Requirements**: ~20GB disk space, 16GB+ RAM.
- **Fastbootd**: Without `fastbootd` support in recovery, flashing `super.img` will fail, risking a hardbrick. Verify with:
  ```bash
  fastboot devices
  ```

## Troubleshooting

- **Permission denied errors**:
  - Check permissions:
    ```bash
    ls -ld /tmp /home/user/sm_gsi_binary_rev_changer/v5.1
    chmod -R 777 /tmp/tmp.*
    chmod -R 755 /home/user/sm_gsi_binary_rev_changer/v5.1
    ```
  - Run with `sudo` if needed:
    ```bash
    sudo ./build_gsi_for_fastbootd.sh -l misc.bin.lz4 -v -g Voltage-5.1_treble_arm64-ab-20250929.img.xz AP_F711BXXU6GWL1_*.tar.md5 -o v5.1
    ```
- **Sparse image errors**:
  - Update `android-tools`:
    ```bash
    sudo apt install android-tools-adb android-tools-fastboot
    ```
  - Use `-k -v` and check `/tmp/tmp*/super*.img`.
- **Missing `SignerVer02`**:
  - Verify `--last-image`:
    ```bash
    lz4 -d misc.bin.lz4 misc.bin
    xxd misc.bin | grep SignerVer02
    ```

## License

MIT License. See [LICENSE](LICENSE).

## About

Educational tool for Samsung firmware modification with GSI integration and model/signer updates. Not for production use due to high risk of **bootloop** or **hardbrick**.
