#!/usr/bin/env bash
# =============================================================================
# convert_4k_to_1080p.sh
#
# Recursively scans a directory for 4K UHD HEVC (H.265) MKV files and
# converts them to 1080p HD AVC (H.264) MKV files with HDR→SDR tone mapping.
# Audio and subtitle tracks are copied without modification.
#
# Hardware acceleration: Apple VideoToolbox (macOS) is used by default for
# both decoding (hevc_videotoolbox) and encoding (h264_videotoolbox).
# HDR tone-mapping is performed in software (CPU) as VideoToolbox does not
# support it natively; the script automatically uses a hybrid pipeline
# (HW decode → CPU tone-map/scale → HW encode) for HDR sources and a
# fully hardware pipeline for SDR sources.
# Falls back to software (libx264) automatically if VideoToolbox is
# unavailable or fails to initialise for a given file.
#
# Requirements:
#   - ffmpeg + ffprobe: static builds from https://evermeet.cx/ffmpeg/
#     These include VideoToolbox, libx264, libzimg (zscale), and all
#     required filters. The standard Homebrew ffmpeg does NOT include
#     libzimg/zscale and will not work for HDR tone-mapping.
#
#     Install:
#       curl -L https://evermeet.cx/ffmpeg/get/zip -o ffmpeg.zip && unzip ffmpeg.zip
#       curl -L https://evermeet.cx/ffmpeg/get/ffprobe/zip -o ffprobe.zip && unzip ffprobe.zip
#       sudo mv ffmpeg ffprobe /usr/local/bin/
#       sudo xattr -d com.apple.quarantine /usr/local/bin/ffmpeg /usr/local/bin/ffprobe
#
#   - macOS 10.13+ (VideoToolbox HEVC decode requires Metal/macOS 10.13+)
#
# Usage:
#   ./convert_4k_to_1080p.sh [OPTIONS] <input>
#
#   <input> can be:
#     - A directory: recursively scanned for 4K HEVC MKV files
#     - A single MKV file: converted directly (must be 4K HEVC)
#
# Options:
#   -o <dir>    Output directory for converted files
#               (default: same directory as each source file)
#               Output filename is always "<original name> - 1080p.mkv"
#   -b <rate>   VideoToolbox encode bitrate (default: 8000k)
#               Examples: 6000k, 8000k, 12000k. Ignored in SW mode.
#   -c <val>    Software fallback CRF 0-51 (default: 18, lower=better)
#   -p <preset> Software fallback x264 preset (default: slow)
#   -t <method> Tone-mapping algorithm (default: mobius)
#               Options: hable mobius reinhard clip linear gamma none
#               Note: bt2390 is only valid for the libplacebo-based
#               tonemap2 filter, not the tonemap filter used by this script
#   -k <val>    Peak brightness for tone-mapping in nits (default: omitted,
#               letting ffmpeg auto-detect from source metadata)
#               Example: -k 1000 for a 1000-nit mastered source
#   -s          Force software encode only (skip VideoToolbox entirely)
#   -n          Dry-run: detect files and print commands without converting
#   -h          Show this help message
#
# Examples:
#   ./convert_4k_to_1080p.sh /Volumes/NAS/Movies
#   ./convert_4k_to_1080p.sh "/Volumes/NAS/Movies/My Film (2024).mkv"
#   ./convert_4k_to_1080p.sh -o ~/Desktop/output -b 10000k /Volumes/NAS/Movies
#   ./convert_4k_to_1080p.sh -s /Volumes/NAS/Movies   # force software
#   ./convert_4k_to_1080p.sh -n /Volumes/NAS/Movies   # dry-run
# =============================================================================

set -euo pipefail

# Defaults
VT_BITRATE="8000k"
SW_CRF=18
SW_PRESET="slow"
TONEMAP="mobius"
TONEMAP_PEAK=""
FORCE_SW=false
DRY_RUN=false
OUTPUT_DIR=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

usage() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
    exit 0
}

while getopts ":o:b:c:p:t:k:snh" opt; do
    case $opt in
        o) OUTPUT_DIR="$OPTARG" ;;
        b) VT_BITRATE="$OPTARG" ;;
        c) SW_CRF="$OPTARG" ;;
        p) SW_PRESET="$OPTARG" ;;
        t) TONEMAP="$OPTARG" ;;
        k) TONEMAP_PEAK="$OPTARG" ;;
        s) FORCE_SW=true ;;
        n) DRY_RUN=true ;;
        h) usage ;;
        :) echo -e "${RED}Option -$OPTARG requires an argument.${RESET}" >&2; exit 1 ;;
        \?) echo -e "${RED}Unknown option: -$OPTARG${RESET}" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# Validate -t value against the set supported by the tonemap filter
case "$TONEMAP" in
    hable|mobius|reinhard|clip|linear|gamma|none) ;;
    *)
        echo -e "${RED}Error: unsupported tone-map method '${TONEMAP}'.${RESET}" >&2
        echo -e "       Valid options: hable mobius reinhard clip linear gamma none" >&2
        exit 1
        ;;
esac

if [[ $# -lt 1 ]]; then
    echo -e "${RED}Error: No input specified.${RESET}" >&2
    echo "Usage: $0 [OPTIONS] <file_or_directory>"
    exit 1
fi

INPUT="${1%/}"

# Determine whether input is a single file or a directory
INPUT_IS_FILE=false
if [[ -f "$INPUT" ]]; then
    INPUT_IS_FILE=true
elif [[ ! -d "$INPUT" ]]; then
    echo -e "${RED}Error: '$INPUT' is not a file or directory.${RESET}" >&2
    exit 1
fi

# OUTPUT_DIR remains empty by default — each file is written alongside its source

# Dependency checks
for cmd in ffmpeg ffprobe; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}Error: '$cmd' not found.${RESET}" >&2
        echo -e "${RED}Download the static build from: https://evermeet.cx/ffmpeg/${RESET}" >&2
        exit 1
    fi
done

# ── Capability Detection ──────────────────────────────────────────────────────
# VideoToolbox HW decode is enabled via -hwaccel videotoolbox (no separate
# decoder binary — the standard hevc decoder is used, accelerated by VT).
# We probe by attempting a 1-frame null decode with -hwaccel videotoolbox.
HW_DECODE_AVAILABLE=false
HW_ENCODE_AVAILABLE=false
ZSCALE_AVAILABLE=false

if ! $FORCE_SW; then
    # Probe HW decode: try a null decode with -hwaccel videotoolbox
    if ffmpeg -hide_banner -hwaccel videotoolbox \
              -f lavfi -i nullsrc=s=16x16:d=0.1 \
              -c:v hevc -frames:v 1 -f null - 2>/dev/null; then
        HW_DECODE_AVAILABLE=true
    fi
    # Probe HW encode
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_videotoolbox"; then
        HW_ENCODE_AVAILABLE=true
    fi
fi

# Probe zscale — required for HDR->SDR tone-mapping (needs libzimg)
if ffmpeg -hide_banner -filters 2>/dev/null | grep -qF " zscale "; then
    ZSCALE_AVAILABLE=true
else
    # Warn now; we will abort later if an HDR file is actually encountered
    echo -e "${YELLOW}Warning: zscale filter not found in this ffmpeg build.${RESET}" >&2
    echo -e "${YELLOW}         HDR->SDR tone-mapping will not be available.${RESET}" >&2
    echo -e "${YELLOW}         Download the static build from: https://evermeet.cx/ffmpeg/${RESET}" >&2
    echo "" >&2
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

probe_stream() {
    local file="$1" stream_type="$2" field="$3"
    ffprobe -v error \
        -select_streams "${stream_type}:0" \
        -show_entries "stream=${field}" \
        -of default=noprint_wrappers=1:nokey=1 \
        "$file" 2>/dev/null | head -n1
}

is_target_file() {
    local file="$1"
    [[ "$(echo "$file" | tr '[:upper:]' '[:lower:]')" == *.mkv ]] || return 1

    local codec width
    # tr -d strips any trailing whitespace/carriage-returns from ffprobe output
    codec=$(probe_stream "$file" "v" "codec_name" | tr -d '[:space:]')
    width=$(probe_stream  "$file" "v" "width"      | tr -d '[:space:]')

    [[ "$codec" == "hevc" ]] || return 1
    # Width alone identifies 4K UHD — height is NOT checked because many
    # 4K Blu-ray encodes are anamorphic crops (e.g. 3840x1600) with a
    # full 4K width but a height well below 2160.
    # 3840 = UHD-1 / 4K, 4096 = DCI 4K — both qualify.
    [[ -n "$width" ]] && [[ "$width" -ge 3840 ]] || return 1
    return 0
}

has_hdr() {
    local file="$1"
    local color_transfer
    # Strip whitespace so unexpected trailing chars don't break the case match
    color_transfer=$(probe_stream "$file" "v" "color_transfer" | tr -d '[:space:]')

    # smpte2084  = PQ transfer function (HDR10, Dolby Vision base layer)
    # arib-std-b67 = HLG
    # bt2020-10/12 = BT.2020 gamma (some HDR10 encoders report this)
    case "$color_transfer" in
        smpte2084|arib-std-b67|bt2020-10|bt2020-12) return 0 ;;
    esac

    # Also check for Dolby Vision via stream side-data (catches DV without PQ tag)
    local dv_tag
    dv_tag=$(ffprobe -v error \
        -select_streams v:0 \
        -show_entries "stream_side_data=side_data_type" \
        -of default=noprint_wrappers=1:nokey=1 \
        "$file" 2>/dev/null | grep -i "dolby" | head -n1)
    [[ -n "$dv_tag" ]] && return 0

    # Final check: master display metadata present = HDR10 (handles encoders
    # that set mastering display data without a recognised transfer tag)
    local hdr_tag
    hdr_tag=$(ffprobe -v error \
        -select_streams v:0 \
        -show_entries "stream_side_data=side_data_type" \
        -of default=noprint_wrappers=1:nokey=1 \
        "$file" 2>/dev/null | grep -i "mastering" | head -n1)
    [[ -n "$hdr_tag" ]] && return 0

    return 1
}

# ── Pipeline strategy ─────────────────────────────────────────────────────────
#
# VideoToolbox HW decode:
#   Enabled via -hwaccel videotoolbox on the input. No separate decoder name
#   is needed — the standard hevc decoder runs accelerated through VT.
#   Do NOT pass -c:v hevc_videotoolbox (that decoder does not exist).
#
# HDR tone-mapping:
#   Preferred: zscale+tonemap chain (requires libzimg / zscale filter).
#   Fallback:  scale+colorspace+tonemap chain (available in most ffmpeg builds).
#              Slightly lower quality but functionally equivalent.
#   Both chains convert BT.2020/PQ → BT.709 SDR and scale to 1920-wide
#   (height calculated automatically to preserve source aspect ratio).
#   VT cannot perform tone-mapping on-GPU, so decoded frames must be brought
#   into CPU RAM. This is done implicitly via a format= filter (see below).
#
# h264_videotoolbox encoder:
#   -b:v sets the target bitrate (e.g. 8000k). No CRF equivalent in VT.
#   -allow_sw 1  : fall back within VT if HW queue is saturated.
#   -realtime 0  : disable real-time constraint for best quality.

# Build the HDR tone-map filter chain using zscale.
# zscale (libzimg) is required — there is no viable fallback for HDR->SDR.
#
# Chain explanation:
#   1. zscale=t=linear:npl=100:tin=smpte2084:min=bt2020nc:pin=bt2020
#         - Declare input as PQ (smpte2084) / BT.2020 explicitly so zscale
#           honours the metadata even if container tags are ambiguous
#         - Convert transfer function to linear light (npl=100 = 100 nits SDR peak)
#   2. format=gbrpf32le
#         - tonemap filter requires float RGB; convert from linear YUV to float RGB
#   3. zscale=p=bt709
#         - Convert colour primaries BT.2020 -> BT.709 (still in linear light)
#   4. tonemap=tonemap=${TONEMAP}:desat=0:peak=10
#         - Apply tone-mapping operator to compress HDR highlights into SDR range
#   5. zscale=s=1920x-2:m=bt709:r=tv:t=bt709
#         - Scale to 1080p, set BT.709 matrix, limited range, gamma-encode to BT.709
#   6. format=yuv420p
#         - Final pixel format for encoder
build_tonemap_vf() {
    # zscale handles linear-light conversion, primaries, tonemap, and gamma encoding.
    # The final resize uses scale (not zscale) because zscale does not support
    # the -2 auto-height syntax needed to preserve non-2160 aspect ratios.
    local peak_opt=""
    [[ -n "$TONEMAP_PEAK" ]] && peak_opt=":peak=${TONEMAP_PEAK}"
    echo "zscale=t=linear:npl=100:tin=smpte2084:min=bt2020nc:pin=bt2020,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=${TONEMAP}:desat=0${peak_opt},zscale=m=bt709:r=tv:t=bt709,scale=1920:-2:flags=lanczos,format=yuv420p"
}

# Global command array — populated by build_*_cmd functions.
# Bash 3.2 compatible: no negative indices, no unquoted command substitution.
CMD_ARRAY=()

# Helper: last element without negative indexing (Bash 3.2 has no [-1])
cmd_last() {
    echo "${CMD_ARRAY[${#CMD_ARRAY[@]}-1]}"
}

build_hw_sdr_cmd() {
    # Full HW pipeline: VT decode -> CPU scale -> VT encode
    # -hwaccel videotoolbox enables HW decode; no explicit -c:v needed on input
    local src="$1" dst="$2"
    CMD_ARRAY=(
        ffmpeg -hide_banner -loglevel warning -stats
        -hwaccel videotoolbox
        -probesize 100M
        -i "$src"
        -map 0:v:0
        -map 0:a
        -map 0:s?
        -map 0:d?
        -vf "scale=1920:-2:flags=lanczos,format=yuv420p"
        -c:v h264_videotoolbox
        -b:v "$VT_BITRATE"
        -profile:v high
        -allow_sw 1
        -realtime 0
        -pix_fmt yuv420p
        -color_primaries bt709
        -color_trc bt709
        -colorspace bt709
        -c:a copy -c:s copy -c:d copy
        -movflags +faststart
        "$dst"
    )
}

build_hw_hdr_cmd() {
    # Hybrid pipeline: VT decode -> implicit surface download -> CPU tone-map -> VT encode
    #
    # On Apple Silicon, VideoToolbox surfaces are in videotoolbox_vld format and
    # cannot be explicitly downloaded as nv12 via hwdownload. Instead we omit
    # -hwaccel_output_format and hwdownload entirely. When the first CPU-side
    # filter (format=yuv420p) is encountered, ffmpeg automatically downloads
    # the surface from the VT context before passing frames to the tone-map chain.
    local src="$1" dst="$2"
    # Combine declaration and assignment — avoids "unbound variable" under set -u
    # if the subshell returns empty (Bash treats separately-declared locals as unset)
    local tonemap_vf="$(build_tonemap_vf)"
    # Do NOT prepend format=yuv420p here. The VT surface is implicitly
    # downloaded when zscale (the first CPU filter) requests its input.
    # Prepending format=yuv420p would strip the HDR metadata and feed
    # gamma-encoded yuv420p into zscale, breaking tone-mapping.
    CMD_ARRAY=(
        ffmpeg -hide_banner -loglevel warning -stats
        -hwaccel videotoolbox
        -probesize 100M
        -i "$src"
        -map 0:v:0
        -map 0:a
        -map 0:s?
        -map 0:d?
        -vf "$tonemap_vf"
        -c:v h264_videotoolbox
        -b:v "$VT_BITRATE"
        -profile:v high
        -allow_sw 1
        -realtime 0
        -pix_fmt yuv420p
        -color_primaries bt709
        -color_trc bt709
        -colorspace bt709
        -c:a copy -c:s copy -c:d copy
        -movflags +faststart
        "$dst"
    )
}

build_sw_sdr_cmd() {
    # Software pipeline: SW decode -> CPU scale -> libx264 encode
    local src="$1" dst="$2"
    CMD_ARRAY=(
        ffmpeg -hide_banner -loglevel warning -stats
        -probesize 100M
        -i "$src"
        -map 0:v:0
        -map 0:a
        -map 0:s?
        -map 0:d?
        -vf "scale=1920:-2:flags=lanczos,format=yuv420p"
        -c:v libx264
        -crf "$SW_CRF"
        -preset "$SW_PRESET"
        -profile:v high
        -level 4.1
        -pix_fmt yuv420p
        -color_primaries bt709
        -color_trc bt709
        -colorspace bt709
        -c:a copy -c:s copy -c:d copy
        -movflags +faststart
        "$dst"
    )
}

build_sw_hdr_cmd() {
    # Software pipeline: SW decode -> CPU tone-map -> libx264 encode
    local src="$1" dst="$2"
    local tonemap_vf="$(build_tonemap_vf)"
    CMD_ARRAY=(
        ffmpeg -hide_banner -loglevel warning -stats
        -probesize 100M
        -i "$src"
        -map 0:v:0
        -map 0:a
        -map 0:s?
        -map 0:d?
        -vf "$tonemap_vf"
        -c:v libx264
        -crf "$SW_CRF"
        -preset "$SW_PRESET"
        -profile:v high
        -level 4.1
        -pix_fmt yuv420p
        -color_primaries bt709
        -color_trc bt709
        -colorspace bt709
        -c:a copy -c:s copy -c:d copy
        -movflags +faststart
        "$dst"
    )
}

run_cmd() {
    # Use cmd_last (not [-1]) for Bash 3.2 compatibility
    local dst
    dst="$(cmd_last)"
    if "${CMD_ARRAY[@]}"; then
        return 0
    else
        [[ -f "$dst" ]] && rm -f "$dst"
        return 1
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║        4K HEVC -> 1080p AVC Batch Converter              ║"
echo "║              Apple VideoToolbox Edition                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

if $HW_DECODE_AVAILABLE; then
    hw_dec_label="VideoToolbox (-hwaccel videotoolbox)"
else
    hw_dec_label="software"
fi

if $HW_ENCODE_AVAILABLE; then
    hw_enc_label="h264_videotoolbox (${VT_BITRATE})"
else
    hw_enc_label="libx264 (crf=${SW_CRF})"
fi

if $ZSCALE_AVAILABLE; then
    tonemap_label="${TONEMAP} via zscale"
else
    tonemap_label="${TONEMAP} — zscale NOT AVAILABLE (HDR files will be skipped)"
fi

echo -e "  Input         : ${BOLD}$INPUT${RESET}"
echo -e "  Output dir    : ${BOLD}${OUTPUT_DIR:-<same as source>}${RESET}"
echo -e "  HW decode     : ${BOLD}${hw_dec_label}${RESET}"
echo -e "  HW encode     : ${BOLD}${hw_enc_label}${RESET}"
echo -e "  SW fallback   : ${BOLD}libx264 crf=${SW_CRF} preset=${SW_PRESET}${RESET}"
echo -e "  Tone-map      : ${BOLD}${tonemap_label}${RESET}"
echo -e "  Dry-run       : ${BOLD}$DRY_RUN${RESET}"
echo ""

found=0; converted=0; skipped=0; errors=0

# Build the list of candidate MKV files
mkv_files=()
if $INPUT_IS_FILE; then
    # Single file mode — add it directly, validation happens in the loop
    mkv_files=("$INPUT")
else
    # Directory mode — collect all MKV files recursively (bash 3.2 compatible)
    while IFS= read -r -d '' f; do
        mkv_files+=("$f")
    done < <(find "$INPUT" -type f -iname "*.mkv" -print0 | sort -z)
fi

if [[ ${#mkv_files[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No MKV files found in '$INPUT'.${RESET}"
    exit 0
fi

if $INPUT_IS_FILE; then
    echo -e "${CYAN}Processing single file...${RESET}\n"
else
    echo -e "${CYAN}Scanning ${#mkv_files[@]} MKV file(s)...${RESET}\n"
fi

for src in "${mkv_files[@]}"; do

    if ! is_target_file "$src"; then
        if $INPUT_IS_FILE; then
            echo -e "  ${RED}ERROR${RESET} '$src' is not a 4K UHD HEVC MKV file — skipping." >&2
        else
            echo -e "  ${YELLOW}SKIP${RESET}  (not 4K HEVC) -> $src"
        fi
        ((skipped++)) || true
        continue
    fi

    # Output goes to -o <dir> if specified, otherwise same directory as source
    src_dir="$(dirname "$src")"
    dst_dir="${OUTPUT_DIR:-$src_dir}"
    dst="$dst_dir/$(basename "$src" .mkv) - 1080p.mkv"

    # Check for existing output before incrementing found or printing the banner
    if [[ -f "$dst" ]]; then
        echo -e "  ${YELLOW}SKIP${RESET}  (already converted) -> $src"
        ((skipped++)) || true
        continue
    fi

    ((found++)) || true

    echo -e "\n${BOLD}[${found}]${RESET} ${GREEN}Found 4K HEVC:${RESET} $src"

    # HDR detection
    if has_hdr "$src"; then
        hdr=true
        # zscale is the only viable HDR->SDR path — abort this file if missing
        if ! $ZSCALE_AVAILABLE; then
            echo -e "  ${RED}ERROR${RESET} HDR source requires zscale (libzimg) for tone-mapping." >&2
            echo -e "         Download the static build from: https://evermeet.cx/ffmpeg/" >&2
            ((errors++)) || true
            continue
        fi
        echo -e "  ${CYAN}HDR detected${RESET} — hybrid: VT HW decode -> CPU tone-map (${TONEMAP}) -> VT HW encode"
    else
        hdr=false
        echo -e "  ${CYAN}SDR source${RESET} — full HW pipeline"
    fi

    echo -e "  Output : $dst"

    # Select pipeline
    if $HW_ENCODE_AVAILABLE; then
        if $hdr; then
            build_hw_hdr_cmd "$src" "$dst"
            pipeline="HW-hybrid (VT decode + CPU tone-map + VT encode)"
        else
            build_hw_sdr_cmd "$src" "$dst"
            pipeline="HW (full VideoToolbox)"
        fi
    else
        if $hdr; then
            build_sw_hdr_cmd "$src" "$dst"
            pipeline="SW (libx264 + CPU tone-map)"
        else
            build_sw_sdr_cmd "$src" "$dst"
            pipeline="SW (libx264)"
        fi
    fi

    echo -e "  Pipeline : ${BOLD}${pipeline}${RESET}"

    if $DRY_RUN; then
        echo -e "  ${YELLOW}[DRY-RUN] Command:${RESET}"
        echo "    ${CMD_ARRAY[*]}"
        ((converted++)) || true
        continue
    fi

    mkdir -p "$dst_dir"

    echo -e "  ${CYAN}Converting...${RESET}"
    if run_cmd; then
        echo -e "  ${GREEN}Done${RESET} [${pipeline}]"
        ((converted++)) || true
    else
        # Retry with SW fallback if HW pipeline was used
        if $HW_ENCODE_AVAILABLE; then
            echo -e "  ${YELLOW}HW pipeline failed — retrying with software fallback...${RESET}"
            if $hdr; then
                build_sw_hdr_cmd "$src" "$dst"
            else
                build_sw_sdr_cmd "$src" "$dst"
            fi
            if run_cmd; then
                echo -e "  ${GREEN}Done${RESET} [SW fallback]"
                ((converted++)) || true
            else
                echo -e "  ${RED}Software fallback also failed: $src${RESET}" >&2
                ((errors++)) || true
            fi
        else
            echo -e "  ${RED}FFmpeg failed for: $src${RESET}" >&2
            ((errors++)) || true
        fi
    fi

done

echo ""
echo -e "${BOLD}${CYAN}========================================${RESET}"
echo -e "${BOLD}Summary${RESET}"
echo -e "  4K HEVC files found : ${BOLD}$found${RESET}"
if $DRY_RUN; then
    echo -e "  Would convert       : ${BOLD}$converted${RESET}"
else
    echo -e "  Converted           : ${BOLD}${GREEN}$converted${RESET}"
    echo -e "  Errors              : ${BOLD}${RED}$errors${RESET}"
fi
echo -e "  Skipped             : ${BOLD}${YELLOW}$skipped${RESET}"
echo -e "${BOLD}${CYAN}========================================${RESET}"

[[ $errors -gt 0 ]] && exit 1 || exit 0