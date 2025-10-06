#!/usr/bin/env bash

# build_gsi_for_fastbootd.sh - Creates uncompressed images for fastboot or an experimental AP tar.md5
# Modified to integrate extract_params.py and update_signer.py for handling --last-image
# Parameters are extracted from --last-image (supports LZ4) and applied using update_signer.py
# Ensures model replacement across all images (e.g., boot.img, vendor_boot.img, userdata.img)
# Adds --experimental-model-replace to make model replacement outside SignerVer02 optional
# Adds --build-ap to generate an experimental AP_*.tar.md5 (likely won't work with Odin)

set -e

# Default options
KEEP_FILES=0
VERBOSE=0
EXPERIMENTAL_MODEL_REPLACE=0
BUILD_AP=0
GSI_IMAGE=""
LAST_IMAGE=""
OLD_MODEL=""
MODEL=""
EXCLUDE_FILES=("vbmeta.img" "recovery.img")

# Directories
SCRIPT_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
WORKDIR=$(pwd)
TEMP_DIR=$(mktemp -d)
OUTPUT_JSON="$TEMP_DIR/params.json"
OUTPUT_SIGNER_BIN="$TEMP_DIR/signer_section.bin"

# Tools
LZ4=lz4
SIMG2IMG=simg2img
IMG2SIMG=img2simg
LPUNPACK=lpunpack
LPMAKE=lpmake
PYTHON3=python3
TAR=tar
XZ=xz
MD5SUM=md5sum

# Assume extract_params.py and update_signer.py are in SCRIPT_DIR
EXTRACT_PARAMS_SCRIPT="$SCRIPT_DIR/extract_params.py"
UPDATE_SIGNER_SCRIPT="$SCRIPT_DIR/update_signer.py"

# Verbose print function
vprint() {
    if [ $VERBOSE -eq 1 ]; then
        echo "[*] $1"
    fi
}

# Cleanup function
cleanup() {
    if [ $KEEP_FILES -eq 0 ]; then
        vprint "Cleaning up temporary files"
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

usage() {
    echo "Usage: $0 [options] <input_tar>"
    echo "Options:"
    echo "  -k, --keep-files             Keep temporary files"
    echo "  -v, --verbose                Verbose output"
    echo "  -m, --experimental-model-replace  Enable experimental model replacement outside SignerVer02"
    echo "  -b, --build-ap               [EXPERIMENTAL] Build modified AP_*.tar.md5 instead of fastboot images (likely won't work with Odin)"
    echo "  -g, --gsi FILE               GSI image to replace system.img (.xz supported) [REQUIRED]"
    echo "  -l, --last-image FILE        Image from new firmware to extract params (misc.bin, boot.img, etc., .lz4 supported) [OPTIONAL]"
    echo "  -o, --output DIR             Output directory (default: ./fastboot_images or ./modified_ap for --build-ap)"
    echo "  -e, --exclude FILE           Add file to exclude list (can be used multiple times)"
    echo ""
    echo "Examples:"
    echo "  $0 -g system.img.xz AP_FILE.tar.md5                    # Replace GSI only"
    echo "  $0 -l new_misc.bin -g system.img.xz AP_FILE.tar.md5    # Extract params from new image and replace GSI"
    echo "  $0 -l new_misc.bin.lz4 -m -g system.img.xz AP_FILE.tar.md5  # Extract params, replace GSI, and enable experimental model replacement"
    echo "  $0 -l new_misc.bin.lz4 -b -g system.img.xz AP_FILE.tar.md5  # [EXPERIMENTAL] Build modified AP_*.tar.md5"
    echo ""
    echo "Output: Directory with uncompressed images for fastboot (super.img, boot.img, etc.) or experimental AP_*.tar.md5"
    echo "Input: AP_*.tar.md5 file containing super.img.lz4, boot.img.lz4, etc."
    exit 1
}

# Extract parameters from last-image using extract_params.py
extract_params() {
    local last_image="$1"
    local temp_image="$TEMP_DIR/last_image_temp.img"

    vprint "Checking TEMP_DIR: $TEMP_DIR"
    if [ -z "$TEMP_DIR" ] || [ ! -d "$TEMP_DIR" ] || [ ! -w "$TEMP_DIR" ]; then
        echo "[-] ERROR: Temporary directory $TEMP_DIR is invalid or not writable"
        exit 1
    fi

    if [ ! -f "$EXTRACT_PARAMS_SCRIPT" ]; then
        echo "[-] ERROR: extract_params.py not found at $EXTRACT_PARAMS_SCRIPT"
        exit 1
    fi

    # Check if last_image is LZ4-compressed
    if [[ "$last_image" == *.lz4 ]]; then
        vprint "Decompressing LZ4 last-image: $last_image"
        if ! $LZ4 -d "$last_image" "$temp_image"; then
            echo "[-] ERROR: Failed to decompress LZ4 file: $last_image"
            exit 1
        fi
        last_image="$temp_image"
    fi

    if [ ! -f "$last_image" ]; then
        echo "[-] ERROR: last-image file not found after decompression: $last_image"
        exit 1
    fi

    vprint "Extracting parameters from $last_image"
    if ! $PYTHON3 "$EXTRACT_PARAMS_SCRIPT" "$last_image" --output-json "$OUTPUT_JSON" --output-signer "$OUTPUT_SIGNER_BIN"; then
        echo "[-] ERROR: extract_params.py failed to process $last_image"
        exit 1
    fi

    if [ ! -f "$OUTPUT_SIGNER_BIN" ]; then
        echo "[-] ERROR: Failed to extract signer section to $OUTPUT_SIGNER_BIN"
        exit 1
    fi

    # Extract model from JSON
    if [ -f "$OUTPUT_JSON" ]; then
        vprint "Contents of $OUTPUT_JSON:"
        cat "$OUTPUT_JSON" 2>/dev/null || echo "[-] ERROR: Cannot read $OUTPUT_JSON"
        vprint "Extracting device_model from $OUTPUT_JSON"
        chmod 644 "$OUTPUT_JSON" 2>/dev/null
        MODEL=$(jq -r '.device_model' "$OUTPUT_JSON" 2>/tmp/jq_error.log)
        jq_exit_code=$?
        if [ $jq_exit_code -ne 0 ]; then
            echo "[-] ERROR: jq failed to parse $OUTPUT_JSON. Error details:"
            cat /tmp/jq_error.log
            exit 1
        fi
        if [ -n "$MODEL" ] && [ "$MODEL" != "null" ]; then
            echo "[+] Extracted new model from new image: $MODEL"
        else
            echo "[-] ERROR: Could not extract new device model from $OUTPUT_JSON (MODEL is empty or null)"
            echo "[-] Contents of $OUTPUT_JSON for debugging:"
            cat "$OUTPUT_JSON" 2>/dev/null || echo "[-] ERROR: Cannot read $OUTPUT_JSON"
            exit 1
        fi
    else
        echo "[-] ERROR: Parameter JSON file not generated at $OUTPUT_JSON"
        exit 1
    fi
}

# Apply modifications using update_signer.py
apply_signer_update() {
    local image_path="$1"
    local img_name=$(basename "$image_path")

    if [ ! -f "$UPDATE_SIGNER_SCRIPT" ]; then
        echo "[-] ERROR: update_signer.py not found at $UPDATE_SIGNER_SCRIPT"
        exit 1
    fi

    if [ ! -f "$image_path" ]; then
        vprint "Image not found: $image_path"
        return 1
    fi

    # Skip super.img
    if [[ "$img_name" == "super.img" ]]; then
        vprint "Skipping signer update for super.img"
        return 0
    fi

    local cmd=("$PYTHON3" "$UPDATE_SIGNER_SCRIPT" "update-file" "$image_path")

    if [ -f "$OUTPUT_SIGNER_BIN" ]; then
        cmd+=("--signer-section" "$OUTPUT_SIGNER_BIN")
    fi

    if [ -n "$OLD_MODEL" ]; then
        cmd+=("--preferred-model" "$OLD_MODEL")
    fi

    if [ -n "$MODEL" ] && [ $EXPERIMENTAL_MODEL_REPLACE -eq 1 ]; then
        cmd+=("--new-model" "$MODEL" "--auto-detect-old-model")
    fi

    vprint "Running update_signer.py on $img_name"
    if ! "${cmd[@]}"; then
        echo "[-] Warning: Failed to update $img_name with update_signer.py, continuing..."
        return 1
    fi

    return 0
}

# Create modified AP tar.md5
build_modified_ap() {
    local output_dir="$1"
    local tar_output="$2"

    echo "⚠️ [EXPERIMENTAL] Building modified AP_*.tar.md5 - this is an experimental feature and likely won't work with Odin"
    vprint "Compressing images to LZ4 and creating tar.md5"

    # Create temporary directory for LZ4 files
    local lz4_dir="$TEMP_DIR/lz4_files"
    mkdir -p "$lz4_dir"

    # Compress images to LZ4
    for img_file in "$output_dir"/*.img; do
        [ ! -f "$img_file" ] && continue
        img_name=$(basename "$img_file")
        lz4_file="$lz4_dir/$img_name.lz4"
        vprint "Compressing $img_name to $lz4_file"
        $LZ4 "$img_file" "$lz4_file"
    done

    # Create tar file
    vprint "Creating tar archive: $tar_output"
    $TAR -C "$lz4_dir" -cf "$tar_output" .

    # Generate MD5 sum and append to tar
    vprint "Appending MD5 sum to $tar_output"
    md5_sum=$($MD5SUM "$tar_output" | cut -d' ' -f1)
    echo -n "$md5_sum" >> "$tar_output"
    mv "$tar_output" "${tar_output}.md5"

    echo "[+] Created experimental AP package: ${tar_output}.md5"
}

# Parse arguments
OUTDIR="$WORKDIR/fastboot_images"
while [ $# -gt 0 ]; do
    case "$1" in
        -k|--keep-files) KEEP_FILES=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        -m|--experimental-model-replace) EXPERIMENTAL_MODEL_REPLACE=1 ;;
        -b|--build-ap) BUILD_AP=1 ;;
        -g|--gsi)
            if [ -z "$2" ]; then
                echo "Error: --gsi requires a file"
                usage
            fi
            GSI_IMAGE="$2"
            shift
            ;;
        -l|--last-image)
            if [ -z "$2" ]; then
                echo "Error: --last-image requires a file"
                usage
            fi
            LAST_IMAGE="$2"
            shift
            ;;
        -o|--output)
            if [ -z "$2" ]; then
                echo "Error: --output requires a directory"
                usage
            fi
            OUTDIR="$2"
            shift
            ;;
        -e|--exclude)
            if [ -z "$2" ]; then
                echo "Error: --exclude requires a filename"
                usage
            fi
            EXCLUDE_FILES+=("$2")
            shift
            ;;
        -h|--help) usage ;;
        *)
            if [ -z "$INPUT" ]; then
                INPUT="$1"
            else
                echo "Error: Unexpected argument: $1"
                usage
            fi
            ;;
    esac
    shift
done

# Check inputs
if [ -z "$INPUT" ] || [[ ! "$INPUT" =~ \.tar\.md5$ ]]; then
    echo "Error: Input must be a .tar.md5 file"
    usage
fi

# Extract old model from AP filename if not provided
input_filename=$(basename "$INPUT")
OLD_MODEL=""
if [ -z "$OLD_MODEL" ]; then
    if [[ "$input_filename" =~ AP_([^_]+)_ ]]; then
        OLD_MODEL="${BASH_REMATCH[1]}"
        echo "[+] Detected old model from filename: $OLD_MODEL"
    else
        echo "[+] Warning: Could not detect old model from filename automatically"
    fi
fi

if [ -z "$GSI_IMAGE" ] || [ ! -f "$GSI_IMAGE" ]; then
    echo "Error: GSI image must be provided and exist"
    usage
fi

if [ -n "$LAST_IMAGE" ] && [ ! -f "$LAST_IMAGE" ]; then
    echo "Error: Last image must exist"
    usage
fi

# If --last-image provided, extract params
if [ -n "$LAST_IMAGE" ]; then
    vprint "Starting parameter extraction from last-image"
    extract_params "$LAST_IMAGE"
fi

# Show excluded files
if [ ${#EXCLUDE_FILES[@]} -gt 0 ]; then
    echo "[+] Files to exclude: ${EXCLUDE_FILES[*]}"
fi

# Show if experimental model replacement is enabled
if [ $EXPERIMENTAL_MODEL_REPLACE -eq 1 ]; then
    echo "[+] Experimental model replacement outside SignerVer02 is ENABLED"
else
    echo "[+] Experimental model replacement outside SignerVer02 is DISABLED"
fi

# Show if experimental AP build is enabled
if [ $BUILD_AP -eq 1 ]; then
    echo "⚠️ [EXPERIMENTAL] Building modified AP_*.tar.md5 - this feature is experimental and likely won't work with Odin"
    OUTDIR="$WORKDIR/modified_ap"
fi

INPUT=$(realpath "$INPUT")
GSI_IMAGE=$(realpath "$GSI_IMAGE")
if [ -n "$LAST_IMAGE" ]; then
    LAST_IMAGE=$(realpath "$LAST_IMAGE")
fi

OUTDIR="$(realpath -m "$OUTDIR")"
mkdir -p "$OUTDIR"
echo "[+] Output directory: $OUTDIR"

rm -rf "$OUTDIR"/*

# Check tool availability
check_tool() {
    if ! command -v "$1" &>/dev/null; then
        echo "Error: $1 not found. Please install it."
        exit 1
    fi
}

check_tool "$LZ4"
check_tool "$SIMG2IMG"
check_tool "$IMG2SIMG"
check_tool "$LPUNPACK"
check_tool "$LPMAKE"
check_tool "$PYTHON3"
check_tool "$TAR"
check_tool "$XZ"
check_tool "$MD5SUM"
check_tool "jq"

# Function to convert sparse image to raw if needed
convert_sparse_to_raw() {
    local input_image="$1"
    local output_image="$2"

    if file "$input_image" | grep -q "Android sparse image"; then
        vprint "Converting sparse image to raw: $(basename "$input_image")"
        if ! $SIMG2IMG "$input_image" "$output_image" 2>/dev/null; then
            echo "[-] Warning: Failed to convert sparse image $(basename "$input_image") (Invalid sparse file format), continuing..."
        fi
        return 0
    else
        cp "$input_image" "$output_image"
        return 1
    fi
}

# Function to convert raw image to sparse if needed (for final output)
convert_raw_to_sparse() {
    local input_image="$1"
    local output_image="$2"

    vprint "Converting raw image to sparse: $(basename "$output_image")"
    $IMG2SIMG "$input_image" "$output_image"
}

# Extract AP tar
tar_dir="$TEMP_DIR/tar"
vprint "Extracting $INPUT to $tar_dir"
mkdir -p "$tar_dir"
$TAR -xf "$INPUT" -C "$tar_dir"

# Remove excluded files immediately after extraction
echo "[+] Removing excluded files from temporary directory"
for excluded_file in "${EXCLUDE_FILES[@]}"; do
    excluded_file_lz4="$excluded_file.lz4"
    if [ -f "$tar_dir/$excluded_file_lz4" ]; then
        echo "[*] Removing: $excluded_file_lz4"
        rm -f "$tar_dir/$excluded_file_lz4"
    fi
done

# Process external partitions first (boot, vendor_boot, userdata, etc.)
if [ -n "$LAST_IMAGE" ]; then
    echo "[+] Applying modifications to external partitions using parameters from last-image"
    for lz4_file in "$tar_dir"/*.lz4; do
        [ ! -f "$lz4_file" ] && continue

        filename=$(basename "$lz4_file")
        img_name="${filename%.lz4}"

        # Skip super - we'll process it separately
        if [ "$filename" = "super.img.lz4" ]; then
            continue
        fi

        echo "[+] Processing: $filename -> $img_name"

        # Decompress
        $LZ4 -d "$lz4_file" "$TEMP_DIR/$img_name"

        # Check if image is sparse and convert to raw for modification
        raw_img="$TEMP_DIR/${img_name}_raw"
        was_sparse=0

        if convert_sparse_to_raw "$TEMP_DIR/$img_name" "$raw_img"; then
            was_sparse=1
        fi

        # Apply update_signer.py to raw image
        apply_signer_update "$raw_img"

        # Convert back to sparse if it was originally sparse
        if [ $was_sparse -eq 1 ]; then
            convert_raw_to_sparse "$raw_img" "$OUTDIR/$img_name"
            echo "[+] Created (sparse): $OUTDIR/$img_name"
        else
            cp "$raw_img" "$OUTDIR/$img_name"
            echo "[+] Created: $OUTDIR/$img_name"
        fi
    done
else
    echo "[+] Skipping external partitions modifications (not requested)"
    # Just decompress and copy without modification (keep original format)
    for lz4_file in "$tar_dir"/*.lz4; do
        [ ! -f "$lz4_file" ] && continue
        filename=$(basename "$lz4_file")
        img_name="${filename%.lz4}"
        if [ "$filename" = "super.img.lz4" ]; then
            continue
        fi
        $LZ4 -d "$lz4_file" "$OUTDIR/$img_name"
        echo "[+] Created: $OUTDIR/$img_name"
    done
fi

# Copy remaining LZ4 files that weren't processed (except super) - decompress them
echo "[+] Copying and decompressing remaining files (except super)"
for lz4_file in "$tar_dir"/*.lz4; do
    [ ! -f "$lz4_file" ] && continue

    filename=$(basename "$lz4_file")
    img_name="${filename%.lz4}"

    # Skip super - we process it separately
    if [ "$filename" = "super.img.lz4" ]; then
        continue
    fi

    # Skip files we already processed
    if [ -f "$OUTDIR/$img_name" ]; then
        continue
    fi

    # Decompress and copy to OUTDIR
    $LZ4 -d "$lz4_file" "$OUTDIR/$img_name"
    echo "[+] Created: $OUTDIR/$img_name"
    vprint "Decompressed: $filename -> $img_name"
done

# Process super.img.lz4
super_lz4=$(find "$tar_dir" -name "super.img.lz4" | head -1)
if [ -z "$super_lz4" ]; then
    echo "Error: super.img.lz4 not found in $INPUT"
    exit 1
fi

echo "[+] Processing super image (unpacking and GSI replacement)"

vprint "Decompressing super.img.lz4"
$LZ4 -d "$super_lz4" "$TEMP_DIR/super.img"

# Convert sparse super.img to raw
if file "$TEMP_DIR/super.img" | grep -q "Android sparse image"; then
    vprint "Converting sparse super.img to raw"
    if ! $SIMG2IMG "$TEMP_DIR/super.img" "$TEMP_DIR/super_raw.img" 2>/dev/null; then
        echo "[-] Warning: Failed to convert sparse super.img (Invalid sparse file format), continuing..."
    fi
    [ -f "$TEMP_DIR/super_raw.img" ] && mv "$TEMP_DIR/super_raw.img" "$TEMP_DIR/super.img"
fi

# Unpack super.img
super_dir="$TEMP_DIR/super"
vprint "Unpacking super image to $super_dir"
mkdir -p "$super_dir"
$LPUNPACK "$TEMP_DIR/super.img" "$super_dir"

# SKIP modifications for super partitions - only replace GSI
echo "[+] Skipping modifications for super partitions (only replacing system.img with GSI)"

# Replace system.img with GSI
if [ -n "$GSI_IMAGE" ] && [ -f "$GSI_IMAGE" ]; then
    vprint "Processing GSI image: $GSI_IMAGE"
    gsi_temp="$TEMP_DIR/system_gsi.img"

    if [[ "$GSI_IMAGE" == *.xz ]]; then
        vprint "Decompressing GSI image with xz"
        $XZ -d -k -c "$GSI_IMAGE" > "$gsi_temp"
    else
        cp "$GSI_IMAGE" "$gsi_temp"
    fi

    # Convert GSI to raw if sparse
    if file "$gsi_temp" | grep -q "Android sparse image"; then
        vprint "Converting GSI from sparse to raw"
        $SIMG2IMG "$gsi_temp" "$TEMP_DIR/system_gsi_raw.img"
        mv "$TEMP_DIR/system_gsi_raw.img" "$gsi_temp"
    fi

    vprint "Replacing system.img with GSI"
    cp "$gsi_temp" "$super_dir/system.img"
fi

# Repack super.img
vprint "Repacking super image"
output_super="$OUTDIR/super.img"

# Get original super size
original_super_size=$(stat -c %s "$TEMP_DIR/super.img")

# Get partition list and sizes
partitions=$(find "$super_dir" -name "*.img" -exec basename {} .img \; | sort)

lpmake_args=(
    "--metadata-size" "65536"
    "--metadata-slots" "2"
    "--device" "super:$original_super_size"
    "--group" "main:0"
)

total_size=0
for part in $partitions; do
    part_img="$super_dir/$part.img"
    if [ -f "$part_img" ]; then
        size=$(stat -c %s "$part_img")
        total_size=$((total_size + size))
        lpmake_args+=("--partition" "$part:readonly:$size:main" "--image" "$part=$part_img")
    fi
done

# Update group size
lpmake_args[7]="main:$total_size"
lpmake_args+=("--sparse" "--output" "$output_super")

vprint "Running lpmake to repack super.img"
$LPMAKE "${lpmake_args[@]}"

echo "[+] Created: $output_super"

# If --build-ap is enabled, create modified AP tar.md5
if [ $BUILD_AP -eq 1 ]; then
    ap_output="$WORKDIR/AP_${MODEL}_${MODEL}_modified.tar"
    build_modified_ap "$OUTDIR" "$ap_output"
    OUTDIR="$WORKDIR/modified_ap"  # Update OUTDIR for final message
fi

echo "[+] SUCCESS: Output created in: $OUTDIR"

if [ -n "$LAST_IMAGE" ]; then
    echo "[+] Parameters extracted from: $LAST_IMAGE"
    echo "[+] Applied new model: $MODEL"
fi

echo "[+] GSI image integrated successfully"
echo ""
echo "[+] Available output in $OUTDIR:"
if [ $BUILD_AP -eq 1 ]; then
    echo "    $(basename "${ap_output}.md5")"
else
    for img_file in "$OUTDIR"/*.img; do
        [ ! -f "$img_file" ] && continue
        img_size=$(du -h "$img_file" | cut -f1)
        echo "    $(basename "$img_file") (${img_size})"
    done
    echo ""
    echo "[+] Flash using fastboot commands, for example:"
    echo "    fastboot flash super super.img"
    echo "    fastboot flash boot boot.img"
    echo "    fastboot flash vendor_boot vendor_boot.img"
    echo "    fastboot reboot"
fi
