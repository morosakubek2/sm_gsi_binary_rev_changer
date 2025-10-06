# Samsung Firmware GSI Builder with Model and Signer Update

**Educational Purpose Only**: This project is intended solely for educational purposes to demonstrate firmware modification techniques for Samsung devices. Using this script on a real device carries significant risks, including **bootloop** or **hardbrick**, which may render your device unusable. Proceed at your own risk, and ensure you have a full backup of your data (photos, files, Google/Samsung accounts) before attempting any modifications. The author is not responsible for any damage to your device.

**Requirement**: Your device's recovery mode **must support access to `fastbootd`** (dynamic partition flashing mode). Without `fastbootd` support, the generated images cannot be flashed correctly, increasing the risk of bricking your device.

This repository contains the `build_gsi_for_fastbootd.sh` script, designed to generate either fastboot-compatible images or an experimental modified `AP_*.tar.md5` package for Samsung devices (e.g., Galaxy Z Flip 3, SM-F711B). The script supports replacing the `system.img` with a Generic System Image (GSI), updating the `SignerVer02` section, and optionally modifying the device model string (e.g., from `F711BXXS8HXF2` to `F711BXXSFJYGB`) across firmware images like `boot.img`, `vendor_boot.img`, and `userdata.img`. It integrates with `extract_params.py` and `update_signer.py` to extract parameters from a provided `--last-image` (e.g., `misc.bin.lz4`) and apply them to other images.

**Warning**: The `--experimental-model-replace` and `--build-ap` options are highly experimental and may not work as expected, especially with Odin. Using these features, or the script in general, can lead to **bootloop** or **hardbrick**. Ensure your device's recovery supports `fastbootd` before proceeding.

## Features

- Processes `AP_*.tar.md5` archives, handling images like `super.img.lz4`, `boot.img.lz4`, `vendor_boot.img.lz4`, etc.
- Replaces `system.img` in `super.img` with a provided GSI (supports `.xz` format).
- Extracts `SignerVer02` section and device model from a `--last-image` (e.g., `misc.bin.lz4`) and applies them to other images (except `super.img`).
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
- **Hardware**:
  - 20GB free disk space (for `super.img` processing).
  - 16GB+ RAM recommended (for sparse image conversion).
- **Firmware Files**:
  - Source AP package (e.g., `AP_F711BXXS8HXF2_*.tar.md5`) from [samfw.com](https://samfw.com).
  - Optional: GSI image (e.g., `system.img` or `system.img.xz`) for replacement.
  - Optional: Last image (e.g., `misc.bin.lz4`) for extracting `SignerVer02` and model.
- **Device**:
  - Samsung device with an unlocked bootloader (e.g., Galaxy Z Flip 3, SM-F711B).
  - Recovery mode must support `fastbootd` (verify by booting into recovery and checking for `fastbootd` mode).

## Installation

1. **Install dependencies** (example for Ubuntu):
   ```bash
   sudo apt update
   sudo apt install android-tools-adb android-tools-fastboot lz4 python3 tar xz-utils md5sum jq
   ```
   For Artix Linux (Arch-based):
   ```bash
   sudo pacman -S android-tools lz4 python tar xz jq
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
   - Optional: Place a GSI image (e.g., `Voltage-A16_treble_arm64_bN.img.xz`) in the same directory.
   - Optional: Provide a `--last-image` (e.g., `misc.bin.lz4`) to extract `SignerVer02` and the new model.

2. **Verify `fastbootd` support**:
   - Boot your device into recovery mode (e.g., Vol Up + Power or via `adb reboot recovery`).
   - Check if `fastbootd` is available (e.g., select "Enter fastboot" in recovery and run `fastboot devices` to confirm).
   - If `fastbootd` is not supported, **do not proceed**, as flashing dynamic partitions will fail, risking a **hardbrick**.

3. **Run the script**:
   ```bash
   ./build_gsi_for_fastbootd.sh [options] <input_tar>
   ```

   **Options**:
   - `-k`, `--keep-files`: Keep temporary files in `/tmp` for debugging (default: delete).
   - `-v`, `--verbose`: Enable verbose output.
   - `-m`, `--experimental-model-replace`: Enable experimental replacement of the device model (e.g., `F711BXXS8HXF2` to `F711BXXSFJYGB`) outside `SignerVer02`.
   - `-b`, `--build-ap`: [EXPERIMENTAL] Generate a modified `AP_*.tar.md5` package instead of fastboot images (likely incompatible with Odin).
   - `-g`, `--gsi <file>`: GSI image to replace `system.img` (supports `.xz`).
   - `-l`, `--last-image <file>`: Image to extract `SignerVer02` and new model (e.g., `misc.bin.lz4`).
   - `-o`, `--output <dir>`: Output directory (default: `./fastboot_images` or `./modified_ap` for `--build-ap`).
   - `-e`, `--exclude <file>`: Exclude specific images from processing (default: `recovery.img`).

   **Examples**:
   - Generate fastboot images with GSI replacement:
     ```bash
     ./build_gsi_for_fastbootd.sh -v -g Voltage-A16_treble_arm64_bN.img.xz AP_F711BXXS8HXF2_F711BXXS8HXF2_MQB81265444_REV00_user_low_ship_MULTI_CERT_meta_OS14.tar.md5
     ```
     Output: `fastboot_images/` with `super.img`, `boot.img`, `vendor_boot.img`, etc.
   - With experimental model replacement:
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
- **Temporary Files**: Use `-k` to preserve temporary files in `/tmp` for debugging. Check `/tmp/tmp.*` for logs and intermediate images.
- **GSI Support**: Supports `.xz` compressed GSI images. The script decompresses them automatically.
- **Partitions**: Automatically detects partitions in `super.img` (e.g., `system`, `vendor`, `product`, `odm`). Verify after unpacking:
  ```bash
  ls fastboot_images/super
  ```
- **Model String**: The script extracts the old model from the AP filename (e.g., `F711BXXS8HXF2`) and the new model from `--last-image`. If detection fails, check `params.json` in the temporary directory.
- **Resources**:
  - Memory: ~20GB free disk space, 16GB+ RAM recommended.
  - Backup: Always keep original firmware and a full device backup.
  - XDA Forums: Check XDA for device-specific issues (search "Flip 3 GSI fastbootd").
- **Fastbootd Requirement**: Without `fastbootd` support in recovery, flashing dynamic partitions (e.g., `super.img`) will fail, risking a hardbrick. Verify with:
  ```bash
  fastboot devices
  ```
  after entering `fastbootd` mode.

## Troubleshooting

- **Fastbootd not accessible**:
  - Ensure recovery supports `fastbootd` (e.g., TWRP or custom recovery with `fastbootd` support).
  - Boot into recovery and select "Enter fastboot" or similar.
  - Verify:
    ```bash
    fastboot devices
    ```
  - If unsupported, install a compatible recovery or avoid flashing.
- **Sparse image errors** (e.g., "Invalid sparse file format"):
  - Update `android-tools`:
    ```bash
    sudo apt install android-tools-adb android-tools-fastboot
    ```
  - Run with `-v` and `-k` to inspect temporary files:
    ```bash
    ./build_gsi_for_fastbootd.sh -k -v -g system.img.xz AP_F711BXXS8HXF2_*.tar.md5
    ```
  - Check temporary images:
    ```bash
    ls -l /tmp/tmp*/super*.img
    ```
- **Model not detected**:
  - Verify `--last-image` contains a valid `SignerVer02` section:
    ```bash
    python3 extract_params.py misc.bin.lz4 --output-json params.json --output-signer signer_section.bin
    ```
  - Check `params.json` for `device_model`.
- **Repack errors**:
  - Verify partition sizes:
    ```bash
    ls -l fastboot_images/super/*.img
    ```
  - Ensure sufficient disk space:
    ```bash
    df -h
    ```
- **Verbose logs**:
  - Use `-v` for detailed output and `-k` to keep temporary files. Share logs for support.

## License

MIT License. See [LICENSE](LICENSE) for details.

## About

This project is a forkable tool for educational purposes, demonstrating firmware modification for Samsung devices with GSI integration and model/signer updates. It is not intended for production use due to the high risk of **bootloop** or **hardbrick**. Always ensure your recovery supports `fastbootd` before attempting to flash.
