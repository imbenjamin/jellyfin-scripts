# convert_to_dv81_hdr10only.sh

Recursively scans a directory for MKV files and converts any that are:
- HEVC (H.265) encoded
- Dolby Vision HDR
- NOT already Dolby Vision profile 8.1

For eligible files the script:
1. Inspects the base layer (BL) to detect whether it is HDR10 or HDR10+.
    - HDR10  → no ST 2094-40 SEI NAL units in bitstream
    - HDR10+ → ST 2094-40 dynamic metadata SEI frames present
    Detection uses two signals in priority order:
      1) `hdr10plus_tool` bitstream probe (ground truth — reads raw HEVC SEI NAL units directly, unaffected by container metadata flags)
      2) `dv_bl_signal_compatibility_id` tiebreaker (`compat_id 4` = HDR10+, only consulted if the bitstream probe fails to run)
2. If the BL is HDR10+, strips the dynamic ST 2094-40 metadata with `hdr10plus_tool` and rewrites the SEI to produce a clean HDR10 BL before running the Dolby Vision profile 8.1 conversion.
3. Converts the Dolby Vision RPU to profile 8 with `compat_id 1` (HDR10) using `dovi_tool` mode 2.

## Dependencies (must be on PATH):
- ffprobe  — part of ffmpeg      (`brew install ffmpeg`)
- ffmpeg   — with libx265        (`brew install ffmpeg`)
- dovi_tool                      (`brew install dovi_tool`)
- hdr10plus_tool                 (`brew install hdr10plus_tool`)
- mkvmerge / mkvextract          (`brew install mkvtoolnix`)

## Usage:
`chmod +x convert_to_dv81_hdr10only.sh`

`./convert_to_dv81_hdr10only.sh /path/to/media/dir [--dry-run] [--overwrite]`

`./convert_to_dv81_hdr10only.sh /path/to/file.mkv [--dry-run] [--overwrite]`

## Options:
- `--dry-run`
  - Print what would be converted without actually converting.
- `--overwrite`
  - Replace the original source file in-place with the converted version. The original is removed only after a successful conversion and verification that the output file exists. Without this flag a new file is created alongside the source.

Output files are written alongside the source file with the suffix "` - DV with HDR10.mkv`" and the originals are left untouched.