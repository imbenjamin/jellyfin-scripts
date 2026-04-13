#!/usr/bin/env bash
# =============================================================================
# mkv_original_english_audio_subtitle_tracks.sh
#
# Recursively scans a directory for MKV files and strips tracks that are
# unlikely to be needed, keeping only:
#   • Audio tracks that are English or the movie's original language
#   • Audio tracks tagged as undetermined (und), no linguistic content (zxx),
#     or multilingual (mul) — kept as a precaution
#   • Subtitle tracks that are English
# If removal would eliminate all audio tracks, all audio is kept untouched.
#
# Original language detection:
#   The movie's or show's original language is resolved via the TMDB API using
#   an IMDB or TVDB ID embedded in the filename or its immediate parent
#   directory name. The supported patterns are:
#     Movie.Title.[imdbid-tt1234567].mkv
#     My.Show.[tvdbid-12345]/My.Show.S01E01.mkv
#   The filename is checked first; the parent directory is used as a fallback.
#   IMDB IDs take precedence over TVDB IDs when both are present.
#   If no ID is found, or the TMDB lookup fails, audio is filtered to English
#   only as a safe fallback.
#
# TMDB API token:
#   Required for original language detection. Supply it either as an
#   environment variable or via the --tmdb-token option:
#     export TMDB_TOKEN="your_token_here"
#     ./mkv_original_english_audio_subtitle_tracks.sh /path/to/media
#   or:
#     ./mkv_original_english_audio_subtitle_tracks.sh /path/to/media --tmdb-token "your_token_here"
#   If no token is provided, original language detection is skipped and audio
#   is filtered to English only as a safe fallback.
#
# Scan cache:
#   A dotfile named ".mkv_track_cache" is written into each directory
#   containing processed MKV files. It records the filename and a fingerprint
#   (file size + modification time) for every successfully processed file. On
#   subsequent runs, files whose fingerprint matches the cache entry are skipped
#   automatically. If a file is replaced or modified, its fingerprint changes
#   and it will be re-processed on the next run.
#   Use --rescan to ignore the cache and process all files fresh.
#
# Output:
#   By default, each source file is replaced in-place with the cleaned
#   version. Use --new-file to write a "_cleaned.mkv" file alongside the
#   original instead, leaving the original untouched.
#
# Dependencies (must be on PATH):
#   • mkvmerge  — part of MKVToolNix  (brew install mkvtoolnix)
#   • jq        — JSON processor       (brew install jq)
#   • curl      — HTTP client          (pre-installed on macOS)
#
# Usage:
#   chmod +x mkv_original_english_audio_subtitle_tracks.sh
#   ./mkv_original_english_audio_subtitle_tracks.sh /path/to/media [options]
#
# Options:
#   --tmdb-token <token>  TMDB API read access token.
#   --dry-run             Print what would be changed without modifying any files.
#   --new-file            Write a "_cleaned.mkv" file alongside each original
#                         instead of replacing it.
#   --rescan              Ignore the scan cache and process all files fresh.
# =============================================================================

set -euo pipefail

# ── TMDB Configuration ────────────────────────────────────────────────────────
# Token is picked up from the environment; may be overridden by --tmdb-token.
TMDB_TOKEN="${TMDB_TOKEN:-}"
TMDB_API="https://api.themoviedb.org/3"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
detail()  { echo -e "${DIM}         $*${RESET}"; }
section() { echo -e "\n${BOLD}━━━  $*  ━━━${RESET}"; }

# ── Constants ─────────────────────────────────────────────────────────────────
CACHE_FILENAME=".mkv_track_cache"

# ── Argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=false
NEW_FILE=false
RESCAN=false
SEARCH_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tmdb-token)
      if [[ -z "${2:-}" ]]; then
        err "--tmdb-token requires a value."
        exit 1
      fi
      TMDB_TOKEN="$2"
      shift 2
      ;;
    --dry-run)  DRY_RUN=true;  shift ;;
    --new-file) NEW_FILE=true; shift ;;
    --rescan)   RESCAN=true;   shift ;;
    *)
      if [[ -z "$SEARCH_DIR" ]]; then
        SEARCH_DIR="$1"
        shift
      else
        err "Unexpected argument: $1"
        echo "Usage: $0 /path/to/media [--tmdb-token <token>] [--dry-run] [--new-file] [--rescan]"
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$SEARCH_DIR" ]]; then
  err "No search directory specified."
  echo "Usage: $0 /path/to/media [--tmdb-token <token>] [--dry-run] [--new-file] [--rescan]"
  exit 1
fi

if [[ ! -d "$SEARCH_DIR" ]]; then
  err "Directory not found: $SEARCH_DIR"
  exit 1
fi

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in mkvmerge jq curl; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    echo ""
    echo "Install via Homebrew:"
    for cmd in "${missing[@]}"; do
      case "$cmd" in
        mkvmerge) echo "  brew install mkvtoolnix" ;;
        jq)   echo "  brew install jq" ;;
        curl) echo "  (pre-installed on macOS)" ;;
      esac
    done | sort -u
    exit 1
  fi
}

# ── Scan cache helpers ────────────────────────────────────────────────────────
# Cache format (one entry per line):
#   <size>:<mtime>  <filename>
#
# The fingerprint combines the file's byte size and last-modified timestamp.
# This is instantaneous even for large files, and reliably detects replacements
# or modifications — if either value changes the file is re-processed.
# The cache file lives in the same directory as the MKV files it covers.

# Returns a size:mtime fingerprint for a file.
file_fingerprint() {
  local size mtime
  size=$(wc -c < "$1" | tr -d ' ')
  mtime=$(stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null)
  echo "${size}:${mtime}"
}

# Returns the cache file path for a given directory.
cache_path() {
  echo "$1/$CACHE_FILENAME"
}

# Returns 0 (true) if a file's current fingerprint matches its cache entry.
is_cached() {
  local file="$1"
  local dir
  dir=$(dirname "$file")
  local filename
  filename=$(basename "$file")
  local cache
  cache=$(cache_path "$dir")

  [[ "$RESCAN" == true ]] && return 1
  [[ -f "$cache" ]] || return 1

  local cached_fp current_fp
  cached_fp=$(grep -F "  $filename" "$cache" 2>/dev/null | awk '{print $1}' | head -1) || true
  [[ -z "$cached_fp" ]] && return 1

  current_fp=$(file_fingerprint "$file")
  [[ "$cached_fp" == "$current_fp" ]]
}

# Records a file as successfully processed in its directory's cache.
# In dry-run mode the cache is not written.
mark_cached() {
  local file="$1"
  local dir
  dir=$(dirname "$file")
  local filename
  filename=$(basename "$file")
  local cache
  cache=$(cache_path "$dir")

  [[ "$DRY_RUN" == true ]] && return 0

  local current_fp
  current_fp=$(file_fingerprint "$file")

  # Remove any existing entry for this filename, then append the new one.
  local tmp
  tmp="${cache}.tmp.$$"
  if [[ -f "$cache" ]]; then
    grep -vF "  $filename" "$cache" > "$tmp" 2>/dev/null || true
  else
    : > "$tmp"
  fi
  echo "$current_fp  $filename" >> "$tmp"
  mv -f "$tmp" "$cache"
}


# Returns the ISO 639-1 original language code for a given external ID,
# or an empty string if the lookup fails.
# Arguments:
#   $1 — external ID (IMDB ID e.g. tt1234567, or TVDB ID e.g. 12345)
#   $2 — external source: "imdb_id" or "tvdb_id"
tmdb_get_original_language() {
  local external_id="$1"
  local external_source="$2"
  local response lang

  response=$(curl -sf --max-time 10 \
    -H "Authorization: Bearer ${TMDB_TOKEN}" \
    -H "Accept: application/json" \
    "${TMDB_API}/find/${external_id}?external_source=${external_source}" 2>/dev/null) || {
    warn "TMDB API request failed for ID: $external_id (source: $external_source)"
    echo ""
    return
  }

  # Try movie results first, then TV
  lang=$(echo "$response" | jq -r '
    (.movie_results[0].original_language // "") |
    if . == "" then empty else . end
  ' 2>/dev/null || true)

  if [[ -z "$lang" ]]; then
    lang=$(echo "$response" | jq -r '
      (.tv_results[0].original_language // "") |
      if . == "" then empty else . end
    ' 2>/dev/null || true)
  fi

  echo "${lang:-}"
}

# ── Language normalisation ────────────────────────────────────────────────────
# MKV language tags can be ISO 639-1 (2-letter), ISO 639-2/B (3-letter),
# or ISO 639-2/T (3-letter). Normalise common variants to ISO 639-2/B
# so comparisons are consistent.
# Returns the ISO 639-2/B code (lower-case) for a given tag.
normalise_lang() {
  local tag
  tag=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  case "$tag" in
    # ISO 639-1 → 639-2/B mappings for common languages
    en|eng) echo "eng" ;;
    fr|fre) echo "fre" ;;
    de|ger) echo "ger" ;;
    es|spa) echo "spa" ;;
    it|ita) echo "ita" ;;
    pt|por) echo "por" ;;
    nl|dut) echo "dut" ;;
    sv|swe) echo "swe" ;;
    nb|nor) echo "nor" ;;
    da|dan) echo "dan" ;;
    fi|fin) echo "fin" ;;
    ja|jpn) echo "jpn" ;;
    zh|chi) echo "chi" ;;
    ko|kor) echo "kor" ;;
    ar|ara) echo "ara" ;;
    ru|rus) echo "rus" ;;
    pl|pol) echo "pol" ;;
    cs|cze) echo "cze" ;;
    hu|hun) echo "hun" ;;
    ro|rum) echo "rum" ;;
    tr|tur) echo "tur" ;;
    hi|hin) echo "hin" ;;
    he|heb) echo "heb" ;;
    # Pass through anything already 3-letter or unknown
    *) echo "$tag" ;;
  esac
}

# Convert TMDB ISO 639-1 code to MKV ISO 639-2/B code
tmdb_lang_to_mkv() {
  normalise_lang "$1"
}

# ── Track inspection ──────────────────────────────────────────────────────────
# Given an MKV file, outputs JSON track info via mkvmerge -J
get_tracks_json() {
  mkvmerge -J "$1" 2>/dev/null
}

# ── Process a single MKV file ─────────────────────────────────────────────────
process_file() {
  local src="$1"
  local filename
  filename=$(basename "$src")
  local dir
  dir=$(dirname "$src")

  echo ""
  section "$filename"

  # ── Extract external ID from filename or immediate parent directory ────────
  # Supports [imdbid-ttXXXXXXX] and [tvdbid-XXXXXXX] patterns.
  # The filename is checked first; the parent directory is used as a fallback.
  local external_id="" external_id_source="" external_id_location=""
  local parent_dir
  parent_dir=$(basename "$dir")

  for candidate in "$filename" "$parent_dir"; do
    if [[ "$candidate" =~ \[imdbid-([a-zA-Z0-9]+)\] ]]; then
      external_id="${BASH_REMATCH[1]}"
      external_id_source="imdb_id"
      [[ "$candidate" == "$filename" ]] && external_id_location="filename" || external_id_location="parent directory"
      break
    elif [[ "$candidate" =~ \[tvdbid-([a-zA-Z0-9]+)\] ]]; then
      external_id="${BASH_REMATCH[1]}"
      external_id_source="tvdb_id"
      [[ "$candidate" == "$filename" ]] && external_id_location="filename" || external_id_location="parent directory"
      break
    fi
  done

  if [[ -n "$external_id" ]]; then
    local id_label
    [[ "$external_id_source" == "imdb_id" ]] && id_label="IMDB" || id_label="TVDB"
    info "Found $id_label ID in $external_id_location: $external_id"
  else
    warn "No IMDB or TVDB ID found in filename or parent directory — audio will be filtered to English only"
  fi

  # ── Look up original language via TMDB ────────────────────────────────────
  local orig_lang_tmdb="" orig_lang_mkv=""
  if [[ -n "$external_id" && -n "$TMDB_TOKEN" ]]; then
    info "Looking up original language via TMDB..."
    orig_lang_tmdb=$(tmdb_get_original_language "$external_id" "$external_id_source")
    if [[ -n "$orig_lang_tmdb" ]]; then
      orig_lang_mkv=$(tmdb_lang_to_mkv "$orig_lang_tmdb")
      info "Original language: $orig_lang_tmdb (MKV tag: $orig_lang_mkv)"
    else
      warn "TMDB lookup returned no language — audio will be filtered to English only"
    fi
  elif [[ -n "$external_id" && -z "$TMDB_TOKEN" ]]; then
    warn "No TMDB token — skipping original language lookup"
  fi

  # ── Get track information ──────────────────────────────────────────────────
  local tracks_json
  if ! tracks_json=$(get_tracks_json "$src"); then
    err "Failed to read track info from: $src"
    return 1
  fi

  # ── Build track filter lists ───────────────────────────────────────────────
  # Collect subtitle and audio track IDs to keep/remove
  local -a audio_keep_ids=()
  local -a audio_remove_ids=()
  local -a audio_remove_info=()
  local -a sub_keep_ids=()
  local -a sub_remove_ids=()
  local -a sub_remove_info=()
  local total_audio=0
  local total_subs=0

  while IFS= read -r track; do
    local track_id track_type track_lang track_name
    track_id=$(echo "$track"   | jq -r '.id')
    track_type=$(echo "$track" | jq -r '.type')
    track_lang=$(echo "$track" | jq -r '.properties.language // "und"')
    track_name=$(echo "$track" | jq -r '.properties.track_name // ""')

    local norm_lang
    norm_lang=$(normalise_lang "$track_lang")

    case "$track_type" in
      # ── Audio tracks ──────────────────────────────────────────────────────
      audio)
        (( total_audio++ )) || true
        local codec
        codec=$(echo "$track" | jq -r '.codec // "unknown"')
        local desc="Track $track_id [$codec] lang=$track_lang"
        [[ -n "$track_name" ]] && desc+=" name=\"$track_name\""

        # Keep if English
        if [[ "$norm_lang" == "eng" ]]; then
          audio_keep_ids+=("$track_id")
          detail "KEEP   (audio/English)  $desc"
        # Keep if original language (and it's not undetermined)
        elif [[ -n "$orig_lang_mkv" && "$norm_lang" == "$orig_lang_mkv" && "$norm_lang" != "und" ]]; then
          audio_keep_ids+=("$track_id")
          detail "KEEP   (audio/original) $desc"
        # Keep undetermined, no linguistic content (zxx), or multilingual (mul) tracks
        elif [[ "$norm_lang" == "und" || "$norm_lang" == "zxx" || "$norm_lang" == "mul" ]]; then
          audio_keep_ids+=("$track_id")
          detail "KEEP   (audio/$norm_lang — keeping to be safe) $desc"
        else
          audio_remove_ids+=("$track_id")
          audio_remove_info+=("$desc")
          detail "REMOVE (audio/foreign)  $desc"
        fi
        ;;

      # ── Subtitle tracks ───────────────────────────────────────────────────
      subtitles)
        (( total_subs++ )) || true
        local codec
        codec=$(echo "$track" | jq -r '.codec // "unknown"')
        local desc="Track $track_id [$codec] lang=$track_lang"
        [[ -n "$track_name" ]] && desc+=" name=\"$track_name\""

        if [[ "$norm_lang" == "eng" || "$norm_lang" == "und" ]]; then
          sub_keep_ids+=("$track_id")
          detail "KEEP   (subtitle)  $desc"
        else
          sub_remove_ids+=("$track_id")
          sub_remove_info+=("$desc")
          detail "REMOVE (subtitle)  $desc"
        fi
        ;;
    esac
  done < <(echo "$tracks_json" | jq -c '.tracks[]')

  # ── Summary ────────────────────────────────────────────────────────────────
  local audio_rm_count=${#audio_remove_ids[@]}
  local sub_rm_count=${#sub_remove_ids[@]}

  if [[ $audio_rm_count -eq 0 && $sub_rm_count -eq 0 ]]; then
    ok "Nothing to remove — file is already clean."
    mark_cached "$src"
    return 0
  fi

  if [[ $audio_rm_count -gt 0 ]]; then
    warn "Audio tracks to remove ($audio_rm_count of $total_audio):"
    for info_str in "${audio_remove_info[@]}"; do
      detail "  - $info_str"
    done
  fi

  if [[ $sub_rm_count -gt 0 ]]; then
    warn "Subtitle tracks to remove ($sub_rm_count of $total_subs):"
    for info_str in "${sub_remove_info[@]}"; do
      detail "  - $info_str"
    done
  fi

  # ── Safety check: don't remove ALL audio tracks ───────────────────────────
  if [[ ${#audio_keep_ids[@]} -eq 0 && $total_audio -gt 0 ]]; then
    warn "Removal would eliminate ALL audio tracks — keeping all audio to be safe."
    audio_remove_ids=()
    audio_remove_info=()
    audio_rm_count=0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    local mode_label="replace original"
    [[ "$NEW_FILE" == true ]] && mode_label="new file alongside original"
    info "[DRY RUN] Would remove $audio_rm_count audio + $sub_rm_count subtitle tracks (mode: $mode_label)."
    return 0
  fi

  # ── Build mkvmerge track selection arguments ───────────────────────────────
  # In replace mode, mkvmerge writes to a temp file which then overwrites the
  # original. In new-file mode, the output is written alongside the original.
  local tmp_dst dst
  if [[ "$NEW_FILE" == true ]]; then
    dst="${src%.mkv}_cleaned.mkv"
    tmp_dst="$dst"
  else
    tmp_dst="${src%.mkv}.tmp.$$.mkv"
    dst="$src"
  fi

  # Build comma-separated lists of track IDs to keep for mkvmerge
  # mkvmerge --audio-tracks / --subtitle-tracks accept ID lists to KEEP
  local audio_keep_arg="" sub_keep_arg=""

  if [[ $audio_rm_count -gt 0 && ${#audio_keep_ids[@]} -gt 0 ]]; then
    audio_keep_arg="--audio-tracks $(IFS=,; echo "${audio_keep_ids[*]}")"
  elif [[ $audio_rm_count -gt 0 && ${#audio_keep_ids[@]} -eq 0 ]]; then
    audio_keep_arg="--no-audio"
  fi

  if [[ $sub_rm_count -gt 0 && ${#sub_keep_ids[@]} -gt 0 ]]; then
    sub_keep_arg="--subtitle-tracks $(IFS=,; echo "${sub_keep_ids[*]}")"
  elif [[ $sub_rm_count -gt 0 && ${#sub_keep_ids[@]} -eq 0 ]]; then
    sub_keep_arg="--no-subtitles"
  fi

  # ── Run mkvmerge ──────────────────────────────────────────────────────────
  if [[ "$NEW_FILE" == true ]]; then
    info "Writing new file: $(basename "$tmp_dst")"
  else
    info "Remuxing to temp file, then replacing original..."
  fi

  # shellcheck disable=SC2086
  local mkvmerge_out
  if ! mkvmerge_out=$(mkvmerge \
    --output "$tmp_dst" \
    $audio_keep_arg \
    $sub_keep_arg \
    "$src" \
    </dev/null 2>&1); then
    # mkvmerge exits with 1 for warnings, 2 for errors
    local exit_code=$?
    if [[ $exit_code -eq 2 ]] || echo "$mkvmerge_out" | grep -qiE "^Error"; then
      err "mkvmerge failed:"
      printf '%s\n' "$mkvmerge_out" >&2
      [[ -f "$tmp_dst" ]] && rm -f "$tmp_dst"
      return 1
    fi
    # exit code 1 = warnings only — print them but continue
    warn "mkvmerge completed with warnings:"
    printf '%s\n' "$mkvmerge_out" >&2
  fi

  if [[ ! -s "$tmp_dst" ]]; then
    err "Output file was not created or is empty."
    [[ -f "$tmp_dst" ]] && rm -f "$tmp_dst"
    return 1
  fi

  # In replace mode, swap the temp file over the original
  if [[ "$NEW_FILE" == false ]]; then
    mv -f "$tmp_dst" "$dst"
  fi

  local src_size dst_size
  # For replace mode, report before/after using the final file size
  src_size=$(du -sh "$src" | cut -f1)
  dst_size=$(du -sh "$dst" | cut -f1)
  ok "Done! $src_size → $dst_size"
  if [[ "$NEW_FILE" == true ]]; then
    ok "Saved: $dst"
  else
    ok "Replaced: $dst"
  fi
  # Record the final file in the cache (dst == src in replace mode)
  mark_cached "$dst"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════════╗"
  echo "║         MKV Track Cleaner (Audio + Subs)         ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo -e "${RESET}"

  check_deps

  info "Search directory : $SEARCH_DIR"
  info "Dry run          : $DRY_RUN"
  info "Output mode      : $( [[ "$NEW_FILE" == true ]] && echo "new file alongside original" || echo "replace original" )"
  info "Rescan           : $( [[ "$RESCAN" == true ]] && echo "yes (ignoring cache)" || echo "no (skipping previously scanned files)" )"
  if [[ -n "$TMDB_TOKEN" ]]; then
    info "TMDB token       : set (original language detection enabled)"
  else
    warn "TMDB token       : not set — audio will be filtered to English only"
  fi
  echo ""

  # Find all MKV files recursively
  local -a mkv_files=()
  while IFS= read -r -d '' f; do
    mkv_files+=("$f")
  done < <(find "$SEARCH_DIR" -type f -iname "*.mkv" -print0)

  local total=${#mkv_files[@]}
  if [[ $total -eq 0 ]]; then
    warn "No MKV files found in: $SEARCH_DIR"
    exit 0
  fi

  info "Found $total MKV file(s) to process."

  local processed=0 skipped=0 failed=0

  for mkv_file in "${mkv_files[@]}"; do
    if is_cached "$mkv_file"; then
      # is_cached already respects RESCAN, so this branch is only reached
      # when the file genuinely has a valid cache entry.
      echo ""
      section "$(basename "$mkv_file")"
      detail "SKIPPED (previously scanned — hash unchanged)"
      (( skipped++ )) || true
    elif process_file "$mkv_file"; then
      (( processed++ )) || true
    else
      (( failed++ )) || true
    fi
  done

  # ── Final summary ──────────────────────────────────────────────────────────
  section "Summary"
  echo -e "  Total files  : ${BOLD}$total${RESET}"
  echo -e "  Processed    : ${GREEN}$processed${RESET}"
  echo -e "  Skipped      : ${DIM}$skipped (cached)${RESET}"
  echo -e "  Failed       : ${RED}$failed${RESET}"
  if [[ "$DRY_RUN" == true ]]; then
    echo ""
    warn "DRY RUN — no files were modified."
  fi
  echo ""
}

main "$@"