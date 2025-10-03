#!/usr/bin/env bash

# build-gsi.sh - Modified to include flexible binary rev change for Samsung firmware
# Original: https://gist.githubusercontent.com/sandorex/031c006cc9f705c3640bad8d5b9d66d2/raw/9d20da4905d01eb2d98686199d3c32d9800f486c/build-gsi.sh
# Added: Binary rev change for non-system partitions in super.img and other images (e.g., boot.img, vbmeta.img)
# Added: Support for decompressing .xz GSI images
# Improved: Maintains original sandorex behavior (no mounting, minimal processing), adds resource checks
# Improved: Dynamic device_size and partition detection, sudo for all privileged commands

set -e

# Default options
KEEP_FILES=0
USE_SYSTEM_LZ4=0
VERBOSE=0
REV=""
GSI_IMAGE=""

# Directories
SCRIPT_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
WORKDIR=$(pwd)
OUTDIR="$WORKDIR/out"
PATCHES_DIR="$SCRIPT_DIR/patches"
TEMP_DIR=$(mktemp -d)

# Tools
LZ4=lz4
SIMG2IMG=simg2img
LPUNPACK=lpunpack
LPMAKE=lpmake
AVBTOOL=avbtool
PYTHON3=python3
TAR=tar
XZ=xz

# Cleanup function
cleanup() {
    if [ $KEEP_FILES -eq 0 ]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

usage() {
    echo "Usage: $0 [options] <input_tar> [output_dir]"
    echo "Options:"
    echo "  -k, --keep-files    Keep temporary files"
    echo "  -l, --system-lz4    Use system lz4 instead of bundled"
    echo "  -v, --verbose       Verbose output"
    echo "  -r, --rev <value>   Change binary revision (e.g., 0x0F)"
    echo "  -g, --gsi <file>    Optional GSI image to replace system.img (supports .xz)"
    echo "  -h, --help          Show this help"
    echo "Input: AP_*.tar.md5 file containing super.img.lz4, boot.img, vbmeta.img, etc."
    exit 1
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -k|--keep-files) KEEP_FILES=1 ;;
        -l|--system-lz4) USE_SYSTEM_LZ4=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        -r|--rev) REV="$2"; shift ;;
        -g|--gsi) GSI_IMAGE="$2"; shift ;;
        -h|--help) usage ;;
        *) break ;;
    esac
    shift
done

INPUT="$1"
OUTPUT="${2:-$OUTDIR}"

# Check input
if [ -z "$INPUT" ] || [[ ! "$INPUT" == *.tar.md5 ]]; then
    echo "Error: Input must be a .tar.md5 file (e.g., AP_*.tar.md5)"
    usage
fi

# Create output directory
mkdir -p "$OUTPUT"

# Verbose print
vprint() {
    if [ $VERBOSE -eq 1 ]; then
        echo "[D] $1"
    fi
}

# Check tool availability
check_tool() {
    local tool=$1
    local cmd=$2
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $tool not found"
        exit 1
    fi
}

check_tool "lz4" "$LZ4"
check_tool "simg2img" "$SIMG2IMG"
check_tool "lpunpack" "$LPUNPACK"
check_tool "lpmake" "$LPMAKE"
check_tool "avbtool" "$AVBTOOL"
check_tool "python3" "$PYTHON3"
check_tool "tar" "$TAR"
check_tool "xz" "$XZ"

# Check loop module (for unpacking)
if ! lsmod | grep -q loop; then
    vprint "Loading loop module"
    sudo modprobe loop || {
        echo "Error: Failed to load loop module. Run 'sudo modprobe loop' manually."
        exit 1
    }
fi

# Check loop devices
if ! ls /dev/loop* &>/dev/null; then
    echo "Error: No loop devices found. Check kernel configuration."
    exit 1
fi

# Check system resources
vprint "Checking system resources"
mem_available=$(free -m | awk '/Mem:/ {print $7}')
if [ "$mem_available" -lt 16000 ]; then
    echo "Warning: Low available memory ($mem_available MB). Consider adding swap."
    echo "Run: sudo fallocate -l 8G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile"
fi

# Binary rev change function (Python-based)
change_binary_rev() {
    local img_path=$1
    local target_rev=$2
    vprint "Changing binary rev for $img_path to $target_rev"
    cat <<EOF | $PYTHON3 -
import sys
verbose = $VERBOSE
binRevOffset = 8

def printVerbose(text):
    if verbose == 1:
        print("[D] ", text)

def tryFindModelString(_content):
    modelString = _content.decode('ascii', errors='replace').rfind("SM-")
    if modelString == -1:
        print(f"Can't find model string for $img_path. Skipping.")
        sys.exit(1)
    return modelString - 48

def main():
    img_path = "$img_path"
    target_rev = "$target_rev"
    try:
        with open(img_path, "rb") as file:
            fileContent = file.read()
        modelStringOffset = tryFindModelString(fileContent)
        currentBinRev = chr(fileContent[modelStringOffset + binRevOffset])
        printVerbose(f"Current rev: {currentBinRev}, Offset: {hex(modelStringOffset)}")
        if currentBinRev == target_rev:
            print(f"Target rev same as current for {img_path}. Skipping.")
            sys.exit(0)
        fullBinRevOffset = modelStringOffset + binRevOffset
        newFileContent = fileContent[:fullBinRevOffset] + target_rev.encode('ascii') + fileContent[(fullBinRevOffset + 1):]
        with open(img_path, "wb") as file:
            file.write(newFileContent)
        print(f"[*] Changed rev in {img_path} to {target_rev}")
    except Exception as e:
        print(f"Error processing {img_path}: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
EOF
}

# Extract AP tar
vprint "Extracting $INPUT"
tar_dir="$TEMP_DIR/tar"
mkdir -p "$tar_dir"
sudo $TAR -xvf "$INPUT" -C "$tar_dir"

# Process super.img.lz4
super_lz4=$(find "$tar_dir" -name "super.img.lz4")
if [ -z "$super_lz4" ]; then
    echo "Error: super.img.lz4 not found in $INPUT"
    exit 1
fi

vprint "Decompressing $super_lz4"
sudo $LZ4 -d "$super_lz4" "$TEMP_DIR/super.img"

# Check if super.img is sparse
if file "$TEMP_DIR/super.img" | grep -q "Android sparse image"; then
    vprint "Converting sparse super.img to raw"
    raw_super="$TEMP_DIR/super_raw.img"
    sudo $SIMG2IMG "$TEMP_DIR/super.img" "$raw_super"
    mv "$raw_super" "$TEMP_DIR/super.img"
fi

# Unpack super.img
vprint "Unpacking super image"
super_dir="$TEMP_DIR/super"
mkdir -p "$super_dir"
sudo $LPUNPACK "$TEMP_DIR/super.img" "$super_dir"

# Replace system.img with GSI if provided
if [ -n "$GSI_IMAGE" ] && [ -f "$GSI_IMAGE" ]; then
    vprint "Processing GSI image: $GSI_IMAGE"
    gsi_temp="$TEMP_DIR/system_gsi.img"
    if [[ "$GSI_IMAGE" == *.xz ]]; then
        vprint "Decompressing GSI image ($GSI_IMAGE) with xz"
        sudo $XZ -d -k "$GSI_IMAGE" -c > "$gsi_temp" || {
            echo "Error: Failed to decompress $GSI_IMAGE with xz"
            exit 1
        }
    else
        cp "$GSI_IMAGE" "$gsi_temp"
    fi
    sudo chmod 666 "$gsi_temp"
    vprint "Replacing system.img with GSI"
    sudo cp "$gsi_temp" "$super_dir/system.img"
fi

# Process partitions, skip system.img for rev change (GSI)
partitions=($(find "$super_dir" -name "*.img" -exec basename {} \; | grep -v "system.img" | sed 's/\.img$//'))
for part in "${partitions[@]}"; do
    part_img="$super_dir/$part.img"
    vprint "Processing $part_img"
    # Fix permissions
    sudo chmod 666 "$part_img"
    # Apply binary rev change if requested
    if [ -n "$REV" ]; then
        change_binary_rev "$part_img" "$REV"
    fi
done

# Process system.img (no rev change, no modifications)
system_img="$super_dir/system.img"
if [ -f "$system_img" ]; then
    vprint "Processing system.img (GSI, no rev change)"
    # Fix permissions
    sudo chmod 666 "$system_img"
fi

# Calculate device_size dynamically
vprint "Calculating device_size for super.img"
device_size=0
all_partitions=($(find "$super_dir" -name "*.img" -exec basename {} \; | sed 's/\.img$//'))
for part in "${all_partitions[@]}"; do
    part_img="$super_dir/$part.img"
    if [ -f "$part_img" ]; then
        size=$(sudo stat -c %s "$part_img")
        device_size=$((device_size + size))
    fi
done
# Add metadata overhead (65536 bytes)
device_size=$((device_size + 65536))

# Repack super.img
vprint "Repacking super image"
output_super="$OUTPUT/super.img"
lpmake_args=(
    "--metadata-size" "65536"
    "--super-name" "super"
    "--device" "super:$device_size"
    "--group" "main:$device_size"
)
for part in "${all_partitions[@]}"; do
    part_img="$super_dir/$part.img"
    if [ -f "$part_img" ]; then
        size=$(sudo stat -c %s "$part_img")
        lpmake_args+=("--partition" "$part:readonly:$size:main" "--image" "$part=$part_img")
    fi
done
lpmake_args+=("--output" "$output_super")
sudo $LPMAKE "${lpmake_args[@]}"

# Compress super.img to LZ4
vprint "Compressing super.img to LZ4"
sudo $LZ4 "$output_super" "$OUTPUT/super.img.lz4"

# Process other images in tar (e.g., boot.img, vbmeta.img)
tar_images=$(find "$tar_dir" -name "*.img" ! -name "super.img")
for img in $tar_images; do
    img_name=$(basename "$img")
    vprint "Processing $img_name"
    sudo chmod 666 "$img"
    if [ -n "$REV" ]; then
        change_binary_rev "$img" "$REV"
    fi
    sudo $LZ4 "$img" "$OUTPUT/$img_name.lz4"
done

# Generate vbmeta if needed
vprint "Generating vbmeta"
vbmeta_img="$OUTPUT/vbmeta.img"
sudo $AVBTOOL make_vbmeta_image --flag 2 --padding_size 4096 --output "$vbmeta_img"
if [ -n "$REV" ]; then
    change_binary_rev "$vbmeta_img" "$REV"
fi
sudo $LZ4 "$vbmeta_img" "$OUTPUT/vbmeta.img.lz4"

# Create AP package
vprint "Creating AP package"
ap_tar="$OUTPUT/AP_modified.tar"
tar_files=("$OUTPUT/super.img.lz4" "$OUTPUT/vbmeta.img.lz4")
for img in $tar_images; do
    img_name=$(basename "$img")
    lz4_img="$OUTPUT/$img_name.lz4"
    if [ -f "$lz4_img" ]; then
        tar_files+=("$lz4_img")
    fi
done
sudo $TAR -cvf "$ap_tar" -C "$OUTPUT" "${tar_files[@]#$OUTPUT/}"

echo "[*] Done! AP package created at $ap_tar"
exit 0
