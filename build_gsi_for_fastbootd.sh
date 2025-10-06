#!/usr/bin/env bash

# build_gsi_for_fastbootd.sh - Creates uncompressed images for fastboot or an experimental AP tar.md5
# Modified to integrate extract_params.py and update_signer.py for handling --last-image
# Parameters are extracted from --last-image (supports LZ4) and applied using update_signer.py
# Ensures model replacement across all images (e.g., boot.img, vendor_boot.img, userdata.img)
# Adds --experimental-model-replace to make model replacement outside SignerVer02 optional
# Adds --build-ap to generate an experimental AP_*.tar.md5 (likely won't work with Odin)
# Adds --model to specify old model string explicitly (overrides filename detection)
# Makes GSI replacement optional (no --gsi flag required)
# Adds vbmeta.img to default excluded files
# Ensures proper permissions for temporary files to avoid Permission denied errors

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
EXCLUDE_FILES=("recovery.img" "vbmeta.img")

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
    echo "  -m, --model MODEL            Specify old model string (e.g., F711BXXS8HXE1) [overrides filename detection]"
    echo "  -n, --experimental-model-replace  Enable experimental model replacement outside SignerVer02"
    echo "  -b, --build-ap               [EXPERIMENTAL] Build modified AP_*.tar.md5 instead of fastboot images (likely won't work with Odin)"
    echo "  -g, --gsi FILE               GSI image to replace system.img (.xz supported) [optional]"
    echo "  -l, --last-image FILE        Image from currently installed firmware to extract params (misc.bin, boot.img, etc., .lz4 supported) [optional]"
    echo "  -o, --output DIR             Output directory (default: ./fastboot_images or ./modified_ap for --build-ap)"
    echo "  -e, --exclude FILE           Add file to exclude list (can be used multiple times)"
    echo ""
    echo "Examples:"
    echo "  $0 -g system.img.xz AP_FILE.tar.md5                    # Replace GSI only"
    echo "  $0 -l new_misc.bin -g system.img.xz AP_FILE.tar.md5    # Extract params from new image and replace GSI"
    echo "  $0 -l new_misc.bin.lz4 -n -m F711BXXS8HXE1 -g system.img.xz AP_FILE.tar.md5  # Extract params, replace GSI, and enable experimental model replacement"
    echo "  $0 -l new_misc.bin.lz4 -b -m F711BXXS8HXE1 AP_FILE.tar.md5  # [EXPERIMENTAL] Build modified AP_*.tar.md5 without GSI"
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
        chmod 644 "$temp_image"  # Ensure proper permissions
    else
        cp "$last_image" "$temp_image"
        chmod 644 "$temp_image"
    fi

    if [ ! -f "$temp_image" ]; then
        echo "[-] ERROR: last-image file not found after decompression: $temp_image"
        exit 1
    fi

    vprint "Extracting parameters from $temp_image"
    if ! $PYTHON3 "$EXTRACT_PARAMS_SCRIPT" "$temp_image" --output-json "$OUTPUT_JSON" --output-signer "$OUTPUT_SIGNER_BIN"; then
        echo "[-] ERROR: extract_params.py failed to process $temp_image"
        exit 1
    fi

    if [ ! -f "$OUTPUT_SIGNER_BIN" ]; then
        echo "[-] ERROR: Failed to extract signer section to $OUTPUT_SIGNER_BIN"
        exit 1
    fi

    # Ensure output files have proper permissions
    chmod 644 "$OUTPUT_JSON" "$OUTPUT_SIGNER_BIN" 2>/dev/null

    # Extract model from JSON
    if [ -f "$OUTPUT_JSON" ]; then
        vprint "Contents of $OUTPUT_JSON:"
        cat "$OUTPUT_JSON" 2>/dev/null || echo "[-] ERROR: Cannot read $OUTPUT_JSON"
        vprint "Extracting device_model from $OUTPUT_JSON"
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

    # Ensure image has proper permissions
    chmod 644 "$image_path" 2>/dev/null

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
    chmod 755 "$lz4_dir"

    # Compress images to LZ4
    for img_file in "$output_dir"/*.img; do
        [ ! -f "$img_file" ] && continue
        img_name=$(basename "$img_file")
        lz4_file="$lz4_dir/$img_name.lz4"
        vprint "Compressing $img_name to $lz4_file"
        $LZ4 "$img_file" "$lz4_file"
        chmod 644 "$lz4_file" 2>/dev/null
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
        -m|--model)
            if [ -z "$2" ]; then
                echo "Error: --model requires a model string"
                usage
            fi
            OLD_MODEL="$2"
            shift
            ;;
        -n|--experimental-model-replace) EXPERIMENTAL_MODEL_REPLACE=1 ;;
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

# Extract old model from AP filename if not provided via --model
input_filename=$(basename "$INPUT")
if [ -z "$OLD_MODEL" ]; then
    if [[ "$input_filename" =~ AP_([^_]+)_ ]]; then
        OLD_MODEL="${BASH_REMATCH[1]}"
        echo "[+] Detected old model from filename: $OLD_MODEL"
    else
        echo "[+] Warning: Could not detect old model from filename automatically"
    fi
else
    echo "[+] Using user-specified old model: $OLD_MODEL"
fi

if [ -n "$GSI_IMAGE" ] && [ ! -f "$GSI_IMAGE" ]; then
    echo "Error: GSI image must exist if provided"
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
if [ -n "$GSI_IMAGE" ]; then
    GSI_IMAGE=$(realpath "$GSI_IMAGE")
fi
if [ -n "$LAST_IMAGE" ]; then
    LAST_IMAGE=$(realpath "$LAST_IMAGE")
fi

OUTDIR="$(realpath -m "$OUTDIR")"
mkdir -p "$OUTDIR"
chmod 755 "$OUTDIR"  # Ensure output directory is writable
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
        chmod 644 "$output_image" 2>/dev/null
        return 0
    else
        cp "$input_image" "$output_image"
        chmod 644 "$output_image" 2>/dev/null
        return 1
    fi
}

# Function to convert raw image to sparse if needed (for final output)
convert_raw_to_sparse() {
    local input_image="$1"
    local output_image="$2"

    vprint "Converting raw image to sparse: $(basename "$output_image")"
    $IMG2SIMG "$input_image" "$output_image"
    chmod 644 "$output_image" 2>/dev/null
}

# Extract AP tar
tar_dir="$TEMP_DIR/tar"
vprint "Extracting $INPUT to $tar_dir"
mkdir -p "$tar_dir"
chmod 755 "$tar_dir"
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
        chmod 644 "$TEMP_DIR/$img_name" 2>/dev/null

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
            chmod 644 "$OUTDIR/$img_name" 2>/dev/null
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
        chmod 644 "$OUTDIR/$img_name" 2>/dev/null
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
    chmod 644 "$OUTDIR/$img_name" 2>/dev/null
    echo "[+] Created: $OUTDIR/$img_name"
    vprint "Decompressed: $filename -> $img_name"
done

# Process super.img.lz4
super_lz4=$(find "$tar_dir" -name "super.img.lz4" | head -1)
if [ -z "$super_lz4" ]; then
    echo "Error: super.img.lz4 not found in $INPUT"
    exit 1
fi

echo "[+] Processing super image (unpacking and optional GSI replacement)"

vprint "Decompressing super.img.lz4"
$LZ4 -d "$super_lz4" "$TEMP_DIR/super.img"
chmod 644 "$TEMP_DIR/super.img" 2>/dev/null

# Convert sparse super.img to raw
if file "$TEMP_DIR/super.img" | grep -q "Android sparse image"; then
    vprint "Converting sparse super.img to raw"
    if ! $SIMG2IMG "$TEMP_DIR/super.img" "$TEMP_DIR/super_raw.img" 2>/dev/null; then
        echo "[-] Warning: Failed to convert sparse super.img (Invalid sparse file format), continuing..."
    fi
    [ -f "$TEMP_DIR/super_raw.img" ] && mv "$TEMP_DIR/super_raw.img" "$TEMP_DIR/super.img"
    chmod 644 "$TEMP_DIR/super.img" 2>/dev/null
fi

# Unpack super.img
super_dir="$TEMP_DIR/super"
vprint "
