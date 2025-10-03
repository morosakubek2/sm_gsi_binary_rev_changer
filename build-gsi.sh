#!/usr/bin/env bash

# build-gsi.sh - Modified to include flexible binary rev change for Samsung firmware
# Original: https://gist.githubusercontent.com/sandorex/031c006cc9f705c3640bad8d5b9d66d2/raw/9d20da4905d01eb2d98686199d3c32d9800f486c/build-gsi.sh
# Added: Binary rev change for non-system partitions in super.img and other images (e.g., boot.img, vbmeta.img)
# Improved: Dynamic device_size and partition detection, optional GSI input, fixed sudo for mount/umount

set -e

# Default options
KEEP_FILES=0
USE_SUDO=""
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
E2FSCK=e2fsck
RESIZE2FS=resize2fs
MKE2FS=mke2fs
SLOAD_F2FS=sload.f2fs
MAKE_F2FS=make_f2fs
F2FSCK=fsck.f2fs
AVBTOOL=avbtool
PYTHON3=python3
TAR=tar

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
    echo "  -s, --sudo          Use sudo for commands"
    echo "  -l, --system-lz4    Use system lz4 instead of bundled"
    echo "  -v, --verbose       Verbose output"
    echo "  -r, --rev <value>   Change binary revision (e.g., 0x0F)"
    echo "  -g, --gsi <file>    Optional GSI image to replace system.img"
    echo "  -h, --help          Show this help"
    echo "Input: AP_*.tar.md5 file containing super.img.lz4, boot.img, vbmeta.img, etc."
    exit 1
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -k|--keep-files) KEEP_FILES=1 ;;
        -s|--sudo) USE_SUDO="sudo" ;;
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
check_tool "e2fsck" "$E2FSCK"
check_tool "resize2fs" "$RESIZE2FS"
check_tool "mke2fs" "$MKE2FS"
check_tool "sload.f2fs" "$SLOAD_F2FS"
check_tool "make_f2fs" "$MAKE_F2FS"
check_tool "fsck.f2fs" "$F2FSCK"
check_tool "avbtool" "$AVBTOOL"
check_tool "python3" "$PYTHON3"
check_tool "tar" "$TAR"

# Check loop module
if ! lsmod | grep -q loop; then
    vprint "Loading loop module"
    $USE_SUDO modprobe loop || {
        echo "Error: Failed to load loop module. Run 'sudo modprobe loop' manually."
        exit 1
    }
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
$USE_SUDO $TAR -xvf "$INPUT" -C "$tar_dir"

# Process super.img.lz4
super_lz4=$(find "$tar_dir" -name "super.img.lz4")
if [ -z "$super_lz4" ]; then
    echo "Error: super.img.lz4 not found in $INPUT"
    exit 1
fi

vprint "Decompressing $super_lz4"
$USE_SUDO $LZ4 -d "$super_lz4" "$TEMP_DIR/super.img"

# Check if super.img is sparse
if file "$TEMP_DIR/super.img" | grep -q "Android sparse image"; then
    vprint "Converting sparse super.img to raw"
    raw_super="$TEMP_DIR/super_raw.img"
    $USE_SUDO $SIMG2IMG "$TEMP_DIR/super.img" "$raw_super"
    mv "$raw_super" "$TEMP_DIR/super.img"
fi

# Unpack super.img
vprint "Unpacking super image"
super_dir="$TEMP_DIR/super"
mkdir -p "$super_dir"
$USE_SUDO $LPUNPACK "$TEMP_DIR/super.img" "$super_dir"

# Replace system.img with GSI if provided
if [ -n "$GSI_IMAGE" ] && [ -f "$GSI_IMAGE" ]; then
    vprint "Replacing system.img with provided GSI: $GSI_IMAGE"
    $USE_SUDO cp "$GSI_IMAGE" "$super_dir/system.img"
fi

# Process partitions, skip system.img for rev change (GSI)
partitions=($(find "$super_dir" -name "*.img" -exec basename {} \; | grep -v "system.img" | sed 's/\.img$//'))
for part in "${partitions[@]}"; do
    part_img="$super_dir/$part.img"
    vprint "Processing $part_img"
    # Apply binary rev change if requested
    if [ -n "$REV" ]; then
        change_binary_rev "$part_img" "$REV"
    fi
    # Mount and modify for GSI
    mount_dir="$TEMP_DIR/mount_$part"
    mkdir -p "$mount_dir"
    $USE_SUDO mount -o loop,rw "$part_img" "$mount_dir" || {
        echo "Error: Failed to mount $part_img. Check permissions or run with -s/--sudo."
        exit 1
    }
    vprint "Applying modifications to $part"
    $USE_SUDO rm -rf "$mount_dir/product/app"/* || true
    $USE_SUDO umount "$mount_dir" || {
        echo "Error: Failed to unmount $part_img. Check permissions or run with -s/--sudo."
        exit 1
    }
    $USE_SUDO $E2FSCK -f -y "$part_img"
    $USE_SUDO $RESIZE2FS -M "$part_img"
done

# Process system.img for GSI (no rev change)
system_img="$super_dir/system.img"
if [ -f "$system_img" ]; then
    vprint "Processing system.img (GSI, no rev change)"
    mount_dir="$TEMP_DIR/mount_system"
    mkdir -p "$mount_dir"
    $USE_SUDO mount -o loop,rw "$system_img" "$mount_dir" || {
        echo "Error: Failed to mount $system_img. Check permissions or run with -s/--sudo."
        exit 1
    }
    vprint "Applying GSI modifications to system"
    $USE_SUDO rm -rf "$mount_dir/product/app"/* || true
    $USE_SUDO umount "$mount_dir" || {
        echo "Error: Failed to unmount $system_img. Check permissions or run with -s/--sudo."
        exit 1
    }
    $USE_SUDO $E2FSCK -f -y "$system_img"
    $USE_SUDO $RESIZE2FS -M "$system_img"
fi

# Calculate device_size dynamically
vprint "Calculating device_size for super.img"
device_size=0
all_partitions=($(find "$super_dir" -name "*.img" -exec basename {} \; | sed 's/\.img$//'))
for part in "${all_partitions[@]}"; do
    part_img="$super_dir/$part.img"
    if [ -f "$part_img" ]; then
        size=$($USE_SUDO stat -c %s "$part_img")
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
        size=$($USE_SUDO stat -c %s "$part_img")
        lpmake_args+=("--partition" "$part:readonly:$size:main" "--image" "$part=$part_img")
    fi
done
lpmake_args+=("--output" "$output_super")
$USE_SUDO $LPMAKE "${lpmake_args[@]}"

# Compress super.img to LZ4
vprint "Compressing super.img to LZ4"
$USE_SUDO $LZ4 "$output_super" "$OUTPUT/super.img.lz4"

# Process other images in tar (e.g., boot.img, vbmeta.img)
tar_images=$(find "$tar_dir" -name "*.img" ! -name "super.img")
for img in $tar_images; do
    img_name=$(basename "$img")
    vprint "Processing $img_name"
    if [ -n "$REV" ]; then
        change_binary_rev "$img" "$REV"
    fi
    $USE_SUDO $LZ4 "$img" "$OUTPUT/$img_name.lz4"
done

# Generate vbmeta if needed
vprint "Generating vbmeta"
vbmeta_img="$OUTPUT/vbmeta.img"
$USE_SUDO $AVBTOOL make_vbmeta_image --flag 2 --padding_size 4096 --output "$vbmeta_img"
if [ -n "$REV" ]; then
    change_binary_rev "$vbmeta_img" "$REV"
fi
$USE_SUDO $LZ4 "$vbmeta_img" "$OUTPUT/vbmeta.img.lz4"

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
$USE_SUDO $TAR -cvf "$ap_tar" -C "$OUTPUT" "${tar_files[@]#$OUTPUT/}"

echo "[*] Done! AP package created at $ap_tar"
exit 0
