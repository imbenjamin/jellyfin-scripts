#!/usr/bin/env bash
# =============================================================================
# remove_non_english_subs.sh
#
# Recursively searches a directory for MKV files and removes any subtitle
# tracks whose language is NOT English (i.e. not tagged "eng" or "en").
# All video, audio, and other tracks are left completely untouched.
#
# Requirements:
#   - mkvtoolnix  (brew install mkvtoolnix)
#
# Usage:
#   chmod +x remove_non_english_subs.sh
#   ./remove_non_english_subs.sh [OPTIONS] <directory>
#
# Options:
#   -d, --dry-run   Show what would be done without modifying any files
#   -v, --verbose   Print detailed track information for every file
#   -h, --help      Show this help message
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Defaults ─────────────────────────────────────────────────────────────────
DRY_RUN=false
VERBOSE=false
TARGET_DIR=""

# ── Counters ─────────────────────────────────────────────────────────────────
FILES_SCANNED=0
FILES_MODIFIED=0
FILES_SKIPPED=0
FILES_ERRORED=0
TRACKS_REMOVED=0

# ── Helper functions ──────────────────────────────────────────────────────────
usage() {
    sed -n '/^# Usage:/,/^# =====/{p}' "$0" | sed 's/^# \{0,3\}//'
    cat <<EOF

Examples:
  # Process all MKVs under ~/Movies
  ./remove_non_english_subs.sh ~/Movies

  # Preview changes without touching files
  ./remove_non_english_subs.sh --dry-run ~/Movies

  # Verbose output
  ./remove_non_english_subs.sh -v ~/Movies
EOF
}

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
dry()     { echo -e "${YELLOW}[DRY]${RESET}   $*"; }

# Check that mkvtoolnix is installed
check_dependencies() {
    local missing=()
    for cmd in mkvmerge mkvinfo; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Required tools not found: ${missing[*]}"
        error "Install mkvtoolnix:  brew install mkvtoolnix"
        exit 1
    fi
}

# Returns a newline-separated list of subtitle track IDs whose language is
# NOT English (not "eng" and not "en"), using mkvmerge's JSON output.
get_non_english_subtitle_track_ids() {
    local file="$1"
    local json track_ids=()

    # mkvmerge -J gives rich JSON with all track metadata
    json=$(mkvmerge -J "$file" 2>/dev/null) || return 1

    # Parse: for each track where type=="subtitles" and language not in {eng,en}
    # We use python3 (ships with macOS) for reliable JSON parsing
    mapfile -t track_ids < <(python3 - "$file" <<'PYEOF'
import sys, json

with open('/dev/stdin') as _:
    pass  # not used; data comes from mkvmerge piped below
PYEOF
    python3 -c "
import sys, json, subprocess

file = sys.argv[1]
result = subprocess.run(
    ['mkvmerge', '-J', file],
    capture_output=True, text=True
)
data = json.loads(result.stdout)

for track in data.get('tracks', []):
    if track.get('type') != 'subtitles':
        continue
    props = track.get('properties', {})
    lang  = props.get('language', '').lower().strip()
    # 'und' = undetermined; treat as non-English
    if lang not in ('eng', 'en'):
        print(track['id'])
" "$file")

    echo "${track_ids[@]:-}"
}

# Process a single MKV file
process_file() {
    local file="$1"
    (( FILES_SCANNED++ )) || true

    if [[ $VERBOSE == true ]]; then
        info "Scanning: $file"
    fi

    # Collect non-English subtitle track IDs
    local raw_ids
    raw_ids=$(python3 -c "
import sys, json, subprocess

file = sys.argv[1]
result = subprocess.run(
    ['mkvmerge', '-J', file],
    capture_output=True, text=True
)
if result.returncode != 0:
    sys.exit(1)

data = json.loads(result.stdout)
non_eng = []
for track in data.get('tracks', []):
    if track.get('type') != 'subtitles':
        continue
    props = track.get('properties', {})
    lang  = props.get('language', '').lower().strip()
    name  = props.get('track_name', '')
    if lang not in ('eng', 'en'):
        non_eng.append(str(track['id']))
        if '$VERBOSE' == 'true':
            print(f'  [subtitle] track {track[\"id\"]} lang={lang!r} name={name!r} -> REMOVE', file=sys.stderr)
    else:
        if '$VERBOSE' == 'true':
            print(f'  [subtitle] track {track[\"id\"]} lang={lang!r} name={name!r} -> KEEP', file=sys.stderr)

print(','.join(non_eng))
" "$file" 2>&1 1>/tmp/_mkv_ids_$$) || {
        error "Failed to read track info from: $file"
        (( FILES_ERRORED++ )) || true
        return
    }

    # Separate the printed IDs from verbose stderr lines
    local verbose_output
    verbose_output=$(cat /tmp/_mkv_ids_$$ 2>/dev/null || true)
    rm -f /tmp/_mkv_ids_$$

    # Re-run cleanly to get just the ID list
    local id_list
    id_list=$(python3 -c "
import sys, json, subprocess

file = sys.argv[1]
result = subprocess.run(
    ['mkvmerge', '-J', file],
    capture_output=True, text=True
)
if result.returncode != 0:
    sys.exit(1)

data = json.loads(result.stdout)
non_eng = []
for track in data.get('tracks', []):
    if track.get('type') != 'subtitles':
        continue
    props = track.get('properties', {})
    lang  = props.get('language', '').lower().strip()
    if lang not in ('eng', 'en'):
        non_eng.append(str(track['id']))
print(','.join(non_eng))
" "$file" 2>/dev/null) || {
        error "Failed to parse tracks in: $file"
        (( FILES_ERRORED++ )) || true
        return
    }

    if [[ $VERBOSE == true ]]; then
        # Print verbose track info via mkvinfo (human-readable)
        while IFS= read -r line; do
            echo "         $line"
        done < <(mkvinfo "$file" 2>/dev/null | grep -E "(Track (number|type|language|name)|Name:)" || true)
    fi

    # Nothing to remove
    if [[ -z "$id_list" ]]; then
        [[ $VERBOSE == true ]] && success "No non-English subtitles found — skipping."
        (( FILES_SKIPPED++ )) || true
        return
    fi

    # Count how many tracks we're removing
    local count
    count=$(echo "$id_list" | tr ',' '\n' | grep -c '[0-9]' || true)
    local track_word="track"; [[ $count -gt 1 ]] && track_word="tracks"

    if [[ $DRY_RUN == true ]]; then
        dry "Would remove $count subtitle $track_word (IDs: $id_list) from:"
        dry "  $file"
        (( TRACKS_REMOVED += count )) || true
        (( FILES_MODIFIED++ )) || true
        return
    fi

    # Build mkvmerge exclusion flags: -s !<id1>,<id2>,...
    # Also collect explicit forced/default flag overrides for every kept subtitle
    # track so mkvmerge cannot silently promote any track.
    local tmp_file="${file%.mkv}.tmp_$$.mkv"

    # Get per-track flag overrides for kept subtitle tracks as mkvmerge args,
    # e.g. "--forced-display-flag 3:0 --default-track-flag 3:0"
    local flag_args
    flag_args=$(python3 -c "
import sys, json, subprocess

file = sys.argv[1]
excl = set(sys.argv[2].split(',')) if sys.argv[2] else set()

result = subprocess.run(['mkvmerge', '-J', file], capture_output=True, text=True)
data = json.loads(result.stdout)
args = []
for track in data.get('tracks', []):
    if track.get('type') != 'subtitles':
        continue
    tid = str(track['id'])
    if tid in excl:
        continue
    props = track.get('properties', {})
    forced  = 1 if props.get('forced_track',  False) else 0
    default = 1 if props.get('default_track', False) else 0
    args.append(f'--forced-display-flag {tid}:{forced}')
    args.append(f'--default-track-flag {tid}:{default}')
print(' '.join(args))
" "$file" "$id_list" 2>/dev/null) || flag_args=""

    info "Removing $count subtitle $track_word (IDs: $id_list) from:"
    info "  $(basename "$file")"

    # shellcheck disable=SC2086
    if mkvmerge \
        --output "$tmp_file" \
        --subtitle-tracks "!${id_list}" \
        $flag_args \
        "$file" \
        > /dev/null 2>&1; then

        # Replace original atomically
        mv "$tmp_file" "$file"
        success "Done → $(basename "$file")"
        (( FILES_MODIFIED++ )) || true
        (( TRACKS_REMOVED += count )) || true
    else
        error "mkvmerge failed for: $file"
        rm -f "$tmp_file"
        (( FILES_ERRORED++ )) || true
    fi
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry-run) DRY_RUN=true ;;
        -v|--verbose) VERBOSE=true ;;
        -h|--help)    usage; exit 0 ;;
        -*)           error "Unknown option: $1"; usage; exit 1 ;;
        *)            TARGET_DIR="$1" ;;
    esac
    shift
done

if [[ -z "$TARGET_DIR" ]]; then
    error "No target directory specified."
    usage
    exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
    error "Directory not found: $TARGET_DIR"
    exit 1
fi

# ── Main ──────────────────────────────────────────────────────────────────────
check_dependencies

echo
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  MKV Non-English Subtitle Remover${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  Directory : ${CYAN}$TARGET_DIR${RESET}"
echo -e "  Mode      : $(if $DRY_RUN; then echo "${YELLOW}DRY RUN (no files changed)${RESET}"; else echo "${GREEN}LIVE${RESET}"; fi)"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo

# Recursively find all MKV files and process each one
while IFS= read -r -d '' mkv_file; do
    process_file "$mkv_file"
done < <(find "$TARGET_DIR" -type f -iname "*.mkv" -print0 | sort -z)

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Summary${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  MKV files scanned  : ${BOLD}$FILES_SCANNED${RESET}"
echo -e "  Files modified     : ${GREEN}${BOLD}$FILES_MODIFIED${RESET}"
echo -e "  Files skipped      : $FILES_SKIPPED  ${CYAN}(no non-English subs)${RESET}"
echo -e "  Files with errors  : ${RED}$FILES_ERRORED${RESET}"
echo -e "  Subtitle tracks removed : ${BOLD}$TRACKS_REMOVED${RESET}"
if [[ $DRY_RUN == true ]]; then
    echo
    echo -e "  ${YELLOW}Dry-run mode — no files were changed.${RESET}"
    echo -e "  Run without --dry-run to apply changes."
fi
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo