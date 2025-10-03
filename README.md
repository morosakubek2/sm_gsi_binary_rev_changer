# Samsung Firmware GSI Builder with Binary Revision Change

This script (`build-gsi.sh`) generates a modified AP package for Samsung devices, enabling downgrade or installation of a Generic System Image (GSI) with customizable binary revision (SW REV) changes. It is tailored for devices like the Samsung Galaxy Z Flip 3 (SM-F711B/U/N), allowing users to modify firmware images (e.g., `super.img`, `boot.img`, `vbmeta.img`) to match the bootloader's SW REV (e.g., from 11/0x0B to 15/0x0F) while supporting GSI for the system partition.

**Warning**: Modifying firmware can brick your device or cause data loss. Always back up data (photos, files, Google/Samsung accounts) before proceeding. Use at your own risk.

## Features
- Automatically processes `AP_*.tar.md5`, extracting and handling `super.img.lz4`, `boot.img`, `vbmeta.img`, etc.
- Changes binary revision (SW REV) for non-system partitions (`vendor`, `product`, `odm`, `system_ext`) and other images (e.g., `boot.img`, `vbmeta.img`) to any user-specified value.
- Skips SW REV change for `system.img` when using GSI.
- Supports sparse images (`simg2img`) and LZ4 compression.
- Dynamically calculates `super.img` size based on partition sizes, eliminating manual configuration.
- Generates `AP_modified.tar` for flashing with Odin.
- Compatible with Artix Linux (Arch-based) and other Linux distributions.

## Requirements
- **OS**: Artix Linux (or any Linux with `pacman` or equivalent package manager).
- **Tools**:
  - `android-tools` (includes `simg2img`, `lpunpack`, `lpmake`)
  - `lz4`
  - `python3`
  - `tar`
- **Hardware**:
  - 20GB free disk space (for `super.img` processing).
  - 16GB+ RAM recommended (for sparse image conversion).
- **Firmware Files**:
  - Source AP package (e.g., `AP_*.tar.md5` for OneUI 6.1, Android 14, SW REV 11) from [samfw.com](https://samfw.com/firmware/SM-F711B).
  - Optional: GSI image to replace `system.img`.
- **Device**: Samsung Galaxy Z Flip 3 with unlocked bootloader.

## Installation
1. Install dependencies on Artix Linux:
   ```bash
   sudo pacman -S android-tools lz4 python tar
   ```
   If `android-tools` is unavailable, use AUR:
   ```bash
   yay -S android-tools
   ```
2. Clone this repository:
   ```bash
   git clone https://github.com/your-username/samsung-gsi-builder.git
   cd samsung-gsi-builder
   ```
3. Make the script executable:
   ```bash
   chmod +x build-gsi.sh
   ```

## Usage
1. **Prepare firmware**:
   - Download the target AP package (e.g., `AP_*.tar.md5` for OneUI 6.1, Android 14, SW REV 11) from [samfw.com](https://samfw.com/firmware/SM-F711B).
   - Optional: Place a GSI image as `system.img` in the same directory to replace the stock system.

2. **Run the script**:
   ```bash
   ./build-gsi.sh -r <target_rev> -v <input_tar> [output_dir]
   ```
   - `-r <target_rev>`: Target binary revision (e.g., `0x0F` for SW REV 15, `0x0B` for SW REV 11).
   - `-v`: Enable verbose output for debugging.
   - `<input_tar>`: Input `AP_*.tar.md5` file.
   - `[output_dir]`: Output directory (default: `./out`).
   Example:
   ```bash
   ./build-gsi.sh -r 0x0F -v AP_F711BXXU6EWK1.tar.md5 out
   ```

3. **Output**:
   - The script generates `out/AP_modified.tar`, containing:
     - `super.img.lz4` (with GSI in `system.img` and modified rev for other partitions).
     - `boot.img.lz4`, `vbmeta.img.lz4`, etc., with modified rev.
   - Use Odin to flash `AP_modified.tar`.

4. **Flash the AP package**:
   - Install Wine for Odin:
     ```bash
     sudo pacman -S wine
     ```
   - Download Odin from [samfw.com](https://samfw.com).
   - Run Odin:
     ```bash
     wine /path/to/odin.exe
     ```
   - Load:
     - AP: `out/AP_modified.tar`
     - CP: `CP_*.tar.md5` (from current firmware, e.g., OneUI 7, for updated modem)
     - CSC: `CSC_*.tar.md5` (or `HOME_CSC_*.tar.md5` to preserve data, if possible)
     - Skip BL to avoid downgrading the bootloader.
   - Enter Download Mode (Vol Down + Power, connect USB, press Vol Up) and flash.

## Notes
- **Super Partition Size**: Automatically calculated based on partition sizes, no manual configuration needed.
- **Partitions**: Processes `vendor`, `product`, `odm`, `system_ext` for rev changes, skipping `system` (GSI). Check partitions after unpacking:
  ```bash
  ls out/super
  ```
  Add others (e.g., `opproduct`) to the `partitions` array in the script if needed.
- **Model String**: If the script cannot find the model string (e.g., `SM-F711B`), it will prompt for manual input. Hardcode it in `change_binary_rev` for automation.
- **GSI**: `system.img` is assumed to be a GSI and skipped for rev changes. For stock Samsung `system.img`, edit the script to include it in rev modification.
- **Resources**:
  - Memory: ~20GB free disk space, 16GB+ RAM recommended.
  - Backup: Always keep original firmware and a full device backup.
- **XDA Support**: Check [XDA forums](https://xdaforums.com) for Flip 3-specific issues (search "Flip 3 downgrade GSI rev").

## Troubleshooting
- **Tool errors**: Ensure all dependencies are installed. If `android-tools` is missing, build from AUR or AOSP source.
- **Model string not found**: Provide the full firmware string (e.g., `SM-F711BXXU6EWK1`) when prompted or hardcode in the script.
- **Repack errors**: Verify partition sizes (`ls -l out/super/*.img`) and ensure sufficient disk space.
- **Verbose logs**: Use `-v` for detailed output. Share full logs for support.

## Credits
- Original `build-gsi.sh`: [sandorex](https://gist.github.com/sandorex/031c006cc9f705c3640bad8d5b9d66d2)
- Binary rev change logic: [BotchedRPR/binary-rev-change](https://github.com/BotchedRPR/binary-rev-change)
- Adapted for Artix Linux and Flip 3 by [your-username].

## License
MIT License. See [LICENSE](LICENSE) for details.
