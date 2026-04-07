#!/usr/bin/env bash
# =============================================================================
# convert_to_dv81_hdr10only.sh
#
# Recursively scans a directory for MKV files and converts any that are:
#   • HEVC (H.265) encoded
#   • Dolby Vision HDR
#   • NOT already Dolby Vision profile 8.1
#
# For eligible files the script:
#   1. Inspects the base layer (BL) to detect whether it is HDR10 or HDR10+.
#      HDR10  → no ST 2094-40 SEI NAL units in bitstream
#      HDR10+ → ST 2094-40 dynamic metadata SEI frames present
#      Detection uses two signals in priority order:
#        1) hdr10plus_tool bitstream probe (ground truth — reads raw HEVC SEI
#           NAL units directly, unaffected by container metadata flags)
#        2) dv_bl_signal_compatibility_id tiebreaker (compat_id 4 = HDR10+,
#           only consulted if the bitstream probe fails to run)
#   2. If the BL is HDR10+, strips the dynamic ST 2094-40 metadata with
#      hdr10plus_tool and rewrites the SEI to produce a clean HDR10 BL before
#      running the Dolby Vision profile 8.1 conversion.
#   3. Converts the Dolby Vision RPU to profile 8 with compat_id 1 (HDR10)
#      using dovi_tool mode 2.
#
# Dependencies (must be on PATH):
#   • ffprobe  — part of ffmpeg      (brew install ffmpeg)
#   • ffmpeg   — with libx265        (brew install ffmpeg)
#   • dovi_tool                      (brew install quietvoid/tap/dovi_tool)
#   • hdr10plus_tool                 (brew install quietvoid/tap/hdr10plus_tool)
#   • mkvmerge / mkvextract          (brew install mkvtoolnix)
#
# Usage:
#   chmod +x convert_to_dv81_hdr10only.sh
#   ./convert_to_dv81_hdr10only.sh /path/to/media/dir [--dry-run] [--overwrite]
#   ./convert_to_dv81_hdr10only.sh /path/to/file.mkv [--dry-run] [--overwrite]
#
# Options:
#   --dry-run   Print what would be converted without actually converting.
#   --overwrite Replace the original source file in-place with the converted
#               version. The original is removed only after a successful
#               conversion and verification that the output file exists.
#               Without this flag a new file is created alongside the source.
#
# Output files are written alongside the source file with the suffix
# " - DV with HDR10.mkv" and the originals are left untouched.
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
ok()      { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
err()     { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
section() { printf "\n${BOLD}━━━  %s  ━━━${RESET}\n" "$*"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=false
OVERWRITE=false
INPUT_PATH=""       # may be a directory or a single .mkv file

for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=true ;;
    --overwrite) OVERWRITE=true ;;
    *)
      if [[ -z "$INPUT_PATH" ]]; then
        INPUT_PATH="$arg"
      else
        err "Unexpected argument: $arg"
        echo "Usage: $0 <directory|file.mkv> [--dry-run] [--overwrite]"
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$INPUT_PATH" ]]; then
  err "No input path specified."
  echo "Usage: $0 <directory|file.mkv> [--dry-run] [--overwrite]"
  exit 1
fi

# Determine whether the input is a directory or a single file
if [[ -d "$INPUT_PATH" ]]; then
  INPUT_MODE="dir"
elif [[ -f "$INPUT_PATH" && "$INPUT_PATH" == *.mkv ]]; then
  INPUT_MODE="file"
elif [[ -f "$INPUT_PATH" ]]; then
  err "File is not an MKV: $INPUT_PATH"
  exit 1
else
  err "Path not found: $INPUT_PATH"
  exit 1
fi

# ── Dependency checks ─────────────────────────────────────────────────────────
section "Checking dependencies"
MISSING_DEPS=()
for cmd in ffprobe ffmpeg dovi_tool hdr10plus_tool mkvextract mkvmerge; do
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd found at $(command -v "$cmd")"
  else
    err "$cmd NOT found"
    MISSING_DEPS+=("$cmd")
  fi
done

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
  echo ""
  err "Missing dependencies: ${MISSING_DEPS[*]}"
  echo -e "Install with Homebrew:"
  echo -e "  ${CYAN}brew install ffmpeg mkvtoolnix quietvoid/tap/dovi_tool quietvoid/tap/hdr10plus_tool${RESET}"
  exit 1
fi

# ── Helper: probe a single stream attribute via ffprobe ───────────────────────
probe() {
  # probe <file> <stream_specifier> <entry>
  ffprobe -v quiet -select_streams "$2" \
          -show_entries "stream=$3" \
          -of default=noprint_wrappers=1:nokey=1 \
          "$1" </dev/null 2>/dev/null | head -1
}

# ── Helper: extract all Dolby Vision metadata in a single ffprobe call ────────
# Sets three globals to avoid repeated ffprobe invocations on the same file:
#   _DV_PROFILE   — DV profile number (e.g. "8"), or empty if no DV
#   _DV_COMPAT_ID — dv_bl_signal_compatibility_id (e.g. "1" = HDR10, "4" = HDR10+)
#   _COLOR_TRANSFER — color_transfer of the primary video stream
_DV_PROFILE=""
_DV_COMPAT_ID=""
_COLOR_TRANSFER=""
get_dv_info() {
  local file="$1"
  _DV_PROFILE=""
  _DV_COMPAT_ID=""
  _COLOR_TRANSFER=""
  local result
  result=$(ffprobe -v quiet -print_format json \
           -show_streams "$file" </dev/null 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
profile = ''; compat = ''; ct = ''
for stream in data.get('streams', []):
    if stream.get('codec_type') == 'video' and not ct:
        ct = stream.get('color_transfer', '')
    for sd in stream.get('side_data_list', []):
        sdt = sd.get('side_data_type', '')
        if 'DOVI' in sdt or 'Dolby Vision' in sdt:
            profile = str(sd.get('dv_profile', ''))
            compat  = str(sd.get('dv_bl_signal_compatibility_id', ''))
print(profile + '|' + compat + '|' + ct)
" 2>/dev/null)
  _DV_PROFILE="${result%%|*}"
  local rest="${result#*|}"
  _DV_COMPAT_ID="${rest%%|*}"
  _COLOR_TRANSFER="${rest#*|}"
}

# ── Helper: determine fallback base-layer type (HDR10 or HDR10+) ─────────────
#
# Sets the global variable _BL_TYPE to "hdr10" or "hdr10plus".
# Deliberately does NOT use echo/return-via-stdout to avoid $() capture issues.
#
# Usage: get_fallback_layer_type <mkv_file> [<pre_extracted_hevc_path>]
#   If a pre-extracted HEVC path is supplied and the file exists, the ffmpeg
#   extraction step is skipped — saving a full read of the source file when
#   convert_to_dv81 has already extracted it.
#
# Detection uses two signals in priority order:
#   Signal 1 (primary): hdr10plus_tool bitstream probe on the raw HEVC stream.
#   Signal 2 (tiebreaker): dv_bl_signal_compatibility_id (compat_id=4 = HDR10+).
#     Only consulted if Signal 1 fails (e.g. HEVC extraction error).
_BL_TYPE="hdr10"          # global: fallback layer type result
_PROBE_HEVC_CACHE=""       # global: path to extracted HEVC if still on disk
get_fallback_layer_type() {
  local file="$1"
  local existing_hevc="${2:-}"   # optional pre-extracted bitstream
  _BL_TYPE="hdr10"  # default

  # --- Signal 1: hdr10plus_tool bitstream probe ---
  local probe_tmp own_tmp=false
  local probe_hevc probe_json

  if [[ -n "$existing_hevc" && -s "$existing_hevc" ]]; then
    # Reuse the already-extracted bitstream — no extra ffmpeg pass needed
    probe_tmp="$(mktemp -d "/tmp/dv_probe_XXXXXX")"
    own_tmp=true
    probe_hevc="$existing_hevc"
    probe_json="${probe_tmp}/hdr10plus.json"
    info "    Signal 1 (bitstream probe): reusing pre-extracted HEVC."
  else
    probe_tmp="$(mktemp -d "/tmp/dv_probe_XXXXXX")"
    own_tmp=true
    probe_hevc="${probe_tmp}/probe.hevc"
    probe_json="${probe_tmp}/hdr10plus.json"
    if ! ffmpeg -y -i "$file" \
                -map 0:v:0 \
                -c:v copy \
                -bsf:v hevc_mp4toannexb \
                -f hevc "$probe_hevc" \
                </dev/null >/dev/null 2>&1; then
      warn "    Signal 1 (bitstream probe): inconclusive — HEVC extraction failed."
      rm -rf "$probe_tmp"
      # Fall through to Signal 2
      warn "    Signal 1 inconclusive — falling back to compat_id tiebreaker."
      case "${_DV_COMPAT_ID:-}" in
        4) _BL_TYPE="hdr10plus" ;;
        *) _BL_TYPE="hdr10"     ;;
      esac
      return
    fi
  fi

  local signal1="inconclusive"

  # Redirect both stdout and stderr — progress lines go to /dev/null
  if hdr10plus_tool extract \
       --input  "$probe_hevc" \
       --output "$probe_json" \
       </dev/null >/dev/null 2>&1 \
     && [[ -s "$probe_json" ]]; then

    local frame_count
    frame_count=$(python3 -c "
import json, sys
try:
    d = json.load(open('${probe_json}'))
    if isinstance(d, list):
        print(len(d))
    else:
        for key in ('SceneInfo', 'frames', 'scene_info'):
            if key in d:
                print(len(d[key]))
                sys.exit(0)
        print(0)
except Exception:
    print(0)
" 2>/dev/null)

    if (( frame_count > 0 )); then
      signal1="hdr10plus"
      info "    Signal 1 (bitstream probe): HDR10+ — ${frame_count} ST 2094-40 frame(s) found."
    else
      signal1="hdr10"
      info "    Signal 1 (bitstream probe): HDR10 — JSON present but no frames."
    fi
  else
    signal1="hdr10"
    info "    Signal 1 (bitstream probe): HDR10 — no ST 2094-40 SEI found."
  fi

  # If we extracted our own HEVC and it may be reused by convert_to_dv81,
  # leave the file in place and export its path via _PROBE_HEVC_CACHE.
  # The temp dir will be cleaned up by convert_to_dv81 (via mv) or on next call.
  if $own_tmp && [[ "$probe_hevc" != "$existing_hevc" && -s "$probe_hevc" ]]; then
    _PROBE_HEVC_CACHE="$probe_hevc"
    # Remove only the json, not the hevc — convert_to_dv81 will mv the hevc
    rm -f "$probe_json" 2>/dev/null || true
    rmdir "$probe_tmp" 2>/dev/null || true
  elif $own_tmp; then
    _PROBE_HEVC_CACHE=""
    rm -rf "$probe_tmp"
  fi

  if [[ "$signal1" == "hdr10plus" ]]; then
    _BL_TYPE="hdr10plus"; return
  elif [[ "$signal1" == "hdr10" ]]; then
    _BL_TYPE="hdr10"; return
  fi

  # --- Signal 2: compat_id tiebreaker (only if Signal 1 was inconclusive) ---
  warn "    Signal 1 inconclusive — falling back to compat_id tiebreaker."
  info "    Signal 2 (compat_id): ${_DV_COMPAT_ID:-empty}"
  case "${_DV_COMPAT_ID:-}" in
    4) _BL_TYPE="hdr10plus" ;;
    *) _BL_TYPE="hdr10"     ;;
  esac
}

# ── Conversion function ───────────────────────────────────────────────────────
# Usage: convert_to_dv81 <src_file> <bl_type>
#   bl_type: "hdr10" | "hdr10plus"
#
# dovi_tool 2.3.1 convert subcommand syntax (positional input, fixed output name):
#   dovi_tool -m 2 convert --discard <input.hevc>
#   → always writes to BL_RPU.hevc in the current working directory
#
# A/V sync strategy:
#   Timestamps are extracted from the source video track with:
#     mkvextract timestamps_v2 <src> <track_id>:<timestamps.txt>
#   These are then applied to the converted HEVC in mkvmerge pass A via
#   --timestamps 0:<timestamps.txt>, ensuring the video track in the output
#   carries identical timestamps to the source. Pass B merges that video MKV
#   with all non-video tracks from the source, guaranteeing sync.
#
# On failure the temp dir is preserved at /tmp/dv81_* for diagnosis.
convert_to_dv81() {
  local src="$1"
  local bl_type="${2:-hdr10}"
  local dir
  dir="$(dirname "$src")"
  local base
  base="$(basename "$src" .mkv)"
  local dst
  if $OVERWRITE; then
    dst="${dir}/${base}.mkv.tmp_dv81"
  else
    dst="${dir}/${base} - DV with HDR10.mkv"
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d "/tmp/dv81_XXXXXX")"
  local raw_hevc="${tmp_dir}/video.hevc"
  local bl_hevc="${tmp_dir}/video_bl.hevc"
  local converted_hevc="${tmp_dir}/BL_RPU.hevc"
  local timestamps_file="${tmp_dir}/timestamps.txt"
  local tmp_video_mkv="${tmp_dir}/video_only.mkv"

  step_fail() {
    err "  Step $1 failed — temp files preserved at: $tmp_dir"
    return 1
  }

  info "Converting: $(basename "$src")"
  info "Output:     $(basename "$dst")"
  info "  Base layer type: ${bl_type}"

  # Discard any cached probe HEVC — it is raw Annex B and cannot be used here
  if [[ -n "${_PROBE_HEVC_CACHE:-}" ]]; then
    rm -rf "$(dirname "$_PROBE_HEVC_CACHE")" 2>/dev/null || true
    _PROBE_HEVC_CACHE=""
  fi

  # Find the video track ID (needed for both mkvextract calls)
  local video_track_id
  video_track_id=$(mkvmerge --identify "$src" </dev/null 2>/dev/null \
    | awk '/Track ID [0-9]+: video/ {gsub(/^Track ID /, ""); print +$0; exit}')
  if [[ -z "$video_track_id" ]]; then
    err "  Could not identify video track ID in source MKV."
    step_fail 0; return 1
  fi

  # ── Step 1: Extract timestamps and raw HEVC track ───────────────────────────
  # Extract the per-frame timestamps from the source video track. These will be
  # re-applied to the converted HEVC so its timestamps exactly match the source,
  # guaranteeing A/V sync regardless of what dovi_tool does to the bitstream.
  info "  [1/4] Extracting timestamps and HEVC track..."
  mkvextract "$src" timestamps_v2 "${video_track_id}:${timestamps_file}" \
    </dev/null 2>&1 | grep -iE "^(error|Error)" >&2 || true
  if [[ ! -s "$timestamps_file" ]]; then
    err "  [1/4] mkvextract timestamps produced no output."
    step_fail 1; return 1
  fi
  mkvextract "$src" tracks "${video_track_id}:${raw_hevc}" \
    </dev/null 2>&1 | grep -iE "^(error|Error)" >&2 || true
  if [[ ! -s "$raw_hevc" ]]; then
    err "  [1/4] mkvextract tracks produced no output."
    step_fail 1; return 1
  fi
  info "  [1/4] Extracted ($(du -sh "$raw_hevc" | cut -f1), $(wc -l < "$timestamps_file") timestamp entries)."

  # ── Step 2: Strip HDR10+ SEI from base layer (hdr10plus only) ───────────────
  if [[ "$bl_type" == "hdr10plus" ]]; then
    info "  [2/4] Stripping HDR10+ dynamic metadata from base layer..."
    hdr10plus_tool remove \
      --input  "$raw_hevc" \
      --output "$bl_hevc" \
      </dev/null 2>&1 | grep -iv "reordering\|reading\|writing\|done\|parsed\|removing" >&2 || true
    if [[ ! -s "$bl_hevc" ]]; then
      err "  [2/4] hdr10plus_tool remove produced no output."
      step_fail 2; return 1
    fi
    info "  [2/4] HDR10+ SEI stripped ($(du -sh "$bl_hevc" | cut -f1))."
  else
    info "  [2/4] Base layer is HDR10 — no stripping needed."
    ln -f "$raw_hevc" "$bl_hevc" 2>/dev/null || cp "$raw_hevc" "$bl_hevc"
  fi

  # ── Step 3: Convert RPU to profile 8.1 ──────────────────────────────────────
  info "  [3/4] Converting RPU to profile 8.1..."
  ( cd "$tmp_dir" && \
    dovi_tool -m 2 convert \
      --discard \
      "$bl_hevc" \
      </dev/null 2>&1 | grep -iv "reading\|writing\|converting\|done\|frame" >&2 \
  ) || true
  if [[ ! -s "$converted_hevc" ]]; then
    err "  [3/4] dovi_tool convert produced no output (expected: $converted_hevc)."
    step_fail 3; return 1
  fi
  info "  [3/4] Converted ($(du -sh "$converted_hevc" | cut -f1))."

  # ── Step 4: Remux into MKV with original timestamps ─────────────────────────
  # Pass A: wrap converted HEVC in a bare MKV, applying the source timestamps
  #   --timestamps 0:<file> applies the extracted per-frame timestamps to track
  #   index 0 of this muxing job (the only input = the converted HEVC). This
  #   makes the video track carry identical timestamps to the original source.
  # Pass B: merge the timestamped video MKV with all non-video tracks from source.
  info "  [4/4] Remuxing into MKV (with original timestamps)..."
  local mkvmerge_out

  mkvmerge_out=$(mkvmerge \
    --output "$tmp_video_mkv" \
    --timestamps "0:${timestamps_file}" \
    "$converted_hevc" \
    </dev/null 2>&1) || true
  if ! [[ -s "$tmp_video_mkv" ]]; then
    err "  [4/4] mkvmerge pass A failed — output missing or empty."
    printf '%s\n' "$mkvmerge_out" >&2
    step_fail 4; return 1
  fi

  mkvmerge_out=$(mkvmerge \
    --output "$dst" \
    "$tmp_video_mkv" \
    --no-video "$src" \
    </dev/null 2>&1) || true
  if ! [[ -s "$dst" ]]; then
    err "  [4/4] mkvmerge pass B failed — output missing or empty."
    printf '%s\n' "$mkvmerge_out" >&2
    step_fail 4; return 1
  fi

  rm -rf "$tmp_dir"

  if [[ -s "$dst" ]]; then
    if $OVERWRITE; then
      local src_size dst_size
      src_size=$(du -sh "$src" | cut -f1)
      dst_size=$(du -sh "$dst" | cut -f1)
      mv -f "$dst" "$src"
      ok "  Done (overwrite)! ${src_size} → ${dst_size}"
      ok "  Replaced: $src"
    else
      local src_size dst_size
      src_size=$(du -sh "$src" | cut -f1)
      dst_size=$(du -sh "$dst" | cut -f1)
      ok "  Done! Source: $src_size → Output: $dst_size"
      ok "  Saved to: $dst"
    fi
  else
    err "  Output file was not created. Conversion may have failed."
    return 1
  fi
}

# ── Startup: clean up any stale probe temp dirs from previous runs ───────────
for stale in /private/tmp/dv_probe_* /tmp/dv_probe_*; do
  [[ -d "$stale" ]] && rm -rf "$stale" 2>/dev/null || true
done

# ── Main scan loop ────────────────────────────────────────────────────────────
section "Scanning: $INPUT_PATH"
$DRY_RUN && warn "DRY-RUN mode — no files will be modified."
$OVERWRITE && warn "OVERWRITE mode — original source files will be replaced after successful conversion."

FOUND=0; SKIPPED_CODEC=0; SKIPPED_HDR=0; SKIPPED_P81=0; CONVERTED=0; ERRORS=0
BL_HDR10=0; BL_HDR10PLUS=0

while IFS= read -r -d '' file; do
  echo ""
  info "Found: $file"

  # ── Check 1: HEVC codec ────────────────────────────────────────────────────
  codec=$(probe "$file" "v:0" "codec_name")
  if [[ "$codec" != "hevc" ]]; then
    warn "  Skipping — codec is '${codec:-unknown}', not HEVC."
    (( SKIPPED_CODEC += 1 )) || true; continue
  fi
  info "  ✓ Codec: HEVC"

  # ── Check 2: Dolby Vision ─────────────────────────────────────────────────
  # Single ffprobe call sets _DV_PROFILE, _DV_COMPAT_ID, _COLOR_TRANSFER
  get_dv_info "$file"
  dv_profile="$_DV_PROFILE"
  compat_id="$_DV_COMPAT_ID"
  color_transfer="$_COLOR_TRANSFER"

  if [[ -z "$dv_profile" ]]; then
    warn "  Skipping — no Dolby Vision metadata detected (color_transfer=${color_transfer:-unknown})."
    (( SKIPPED_HDR += 1 )) || true; continue
  fi
  info "  ✓ Dolby Vision detected (profile ${dv_profile})"

  # ── Check 3: Fallback base-layer type (HDR10 or HDR10+) ──────────────────
  # No pre-extracted HEVC yet at scan time — bitstream probe runs inside the
  # function. The extracted bitstream is then reused by convert_to_dv81.
  info "  Analysing base layer fallback type (bitstream probe + compat_id tiebreaker)..."
  get_fallback_layer_type "$file"
  bl_type="$_BL_TYPE"

  if [[ "$bl_type" == "hdr10plus" ]]; then
    warn "  ⚠ Base layer is HDR10+ (compat_id=${compat_id:-?}) — will strip ST 2094-40 metadata."
    (( BL_HDR10PLUS += 1 )) || true
  else
    info "  ✓ Base layer is HDR10 (compat_id=${compat_id:-?})"
    (( BL_HDR10 += 1 )) || true
  fi

  # ── Check 4: Already profile 8.1 with HDR10 BL? ──────────────────────────
  # Profile 8 + compat_id 1 + HDR10 BL = already correct, nothing to do.
  if [[ "$dv_profile" == "8" && "$compat_id" == "1" && "$bl_type" == "hdr10" ]]; then
    ok "  Already Dolby Vision profile 8.1 with HDR10 base layer — no conversion needed."
    (( SKIPPED_P81 += 1 )) || true
    [[ -n "${_PROBE_HEVC_CACHE:-}" ]] && rm -rf "$(dirname "$_PROBE_HEVC_CACHE")" 2>/dev/null || true
    _PROBE_HEVC_CACHE=""
    continue
  fi

  info "  → Needs conversion: profile ${dv_profile}, compat_id=${compat_id:-?}, BL=${bl_type}"
  (( FOUND += 1 )) || true

  if $DRY_RUN; then
    warn "  [DRY-RUN] Would convert: $file"
    [[ -n "${_PROBE_HEVC_CACHE:-}" ]] && rm -rf "$(dirname "$_PROBE_HEVC_CACHE")" 2>/dev/null || true
    _PROBE_HEVC_CACHE=""
    continue
  fi

  # ── Convert ───────────────────────────────────────────────────────────────
  # _PROBE_HEVC_CACHE is consumed (mv'd) by convert_to_dv81 if set.
  # Defensive cleanup covers any case where it wasn't consumed.
  if convert_to_dv81 "$file" "$bl_type"; then
    (( CONVERTED += 1 )) || true
  else
    err "  Conversion failed for: $file"
    (( ERRORS += 1 )) || true
  fi
  [[ -n "${_PROBE_HEVC_CACHE:-}" ]] && rm -rf "$(dirname "$_PROBE_HEVC_CACHE")" 2>/dev/null || true
  _PROBE_HEVC_CACHE=""

done < <(
  if [[ "$INPUT_MODE" == "file" ]]; then
    printf '%s\0' "$INPUT_PATH"
  else
    find "$INPUT_PATH" -type f -iname "*.mkv" -print0
  fi
)

# ── Summary ───────────────────────────────────────────────────────────────────
section "Summary"
printf "  ${CYAN}Skipped (not HEVC):${RESET}              %s\n" "$SKIPPED_CODEC"
printf "  ${CYAN}Skipped (no Dolby Vision):${RESET}       %s\n" "$SKIPPED_HDR"
printf "  ${CYAN}Skipped (already DV 8.1/HDR10):${RESET} %s\n" "$SKIPPED_P81"
printf "  ${CYAN}Base layer — HDR10:${RESET}              %s\n" "$BL_HDR10"
printf "  ${CYAN}Base layer — HDR10+:${RESET}             %s\n" "$BL_HDR10PLUS"
if $DRY_RUN; then
  printf "  ${YELLOW}Would convert:${RESET}                   %s\n" "$FOUND"
else
  printf "  ${GREEN}Converted successfully:${RESET}          %s\n" "$CONVERTED"
  [[ $ERRORS -gt 0 ]] && printf "  ${RED}Errors:${RESET}                          %s\n" "$ERRORS"
fi
printf "\n"