# convert_4k_to_1080p.sh

Recursively scans a directory for 4K UHD HEVC (H.265) MKV files and converts them to 1080p HD AVC (H.264) MKV files with HDR→SDR tone mapping. Audio and subtitle tracks are copied without modification.

Hardware acceleration: Apple VideoToolbox (macOS) is used for all pipelines. The script automatically selects the best available tier at startup:

Tier 1 - Full GPU (`jellyfin-ffmpeg` required):
  All processing stays on the GPU. HEVC decoded via VideoToolbox, HDR->SDR tone-mapping performed by `tonemap_videotoolbox` (Apple Metal compute shaders), scaled via `scale_vt`, and encoded by `h264_videotoolbox`.

Tier 2 - Hybrid GPU/CPU (evermeet.cx static `ffmpeg` or `jellyfin-ffmpeg`):
  VideoToolbox HW decode and encode, with CPU-side HDR->SDR tone-mapping via zscale + tonemap (libzimg). Frames are transferred from GPU to CPU for tone-mapping then back to GPU for encoding.

Tier 3 - Software fallback (automatic):
  Used if VideoToolbox fails to initialise for a given file. Full software pipeline using libx264 with CPU zscale+tonemap tone-mapping.

## Requirements:
ffmpeg + ffprobe — the script checks for binaries in this priority order:
1. `jellyfin-ffmpeg` (preferred — enables full GPU tone-mapping via `tonemap_videotoolbox` / Metal, which standard `ffmpeg` builds lack):
  - `/usr/lib/jellyfin-ffmpeg/ffmpeg`
  - `/Applications/Jellyfin.app/Contents/MacOS/ffmpeg`

Install: https://github.com/jellyfin/jellyfin-ffmpeg/releases

2. evermeet.cx static build (fallback — CPU tone-mapping via `zscale`, HW encode/decode still active via VideoToolbox):
  https://evermeet.cx/ffmpeg/
  - `curl -L https://evermeet.cx/ffmpeg/get/zip -o ffmpeg.zip && unzip ffmpeg.zip`
  - `curl -L https://evermeet.cx/ffmpeg/get/ffprobe/zip -o ffprobe.zip && unzip ffprobe.zip`
  - `sudo mv ffmpeg ffprobe /usr/local/bin/`
  - `sudo xattr -d com.apple.quarantine /usr/local/bin/ffmpeg /usr/local/bin/ffprobe`

The standard Homebrew `ffmpeg` lacks both `tonemap_videotoolbox` and `zscale` and will not work for HDR tone-mapping.

- macOS 10.13+ (VideoToolbox HEVC decode requires Metal/macOS 10.13+)

## Usage:
`./convert_4k_to_1080p.sh [OPTIONS] <input>`

`<input>` can be:
- A directory: recursively scanned for 4K HEVC MKV files
- A single MKV file: converted directly (must be 4K HEVC)

Options:
- `-o <dir>`
  - Output directory for converted files
  - (default: same directory as each source file)
  - Output filename is always `<original name> - 1080p.mkv`
- `-b <rate>`
  - VideoToolbox encode bitrate (default: `8000k`)
  - Examples: `6000k`, `8000k`, `12000k`. Ignored in SW mode.
- `-c <val>`
  - Software fallback CRF 0-51 (default: `18`, lower=better)
- `-p <preset>`
  - Software fallback x264 preset (default: `slow`)
- `-t <method>`
  - Tone-mapping algorithm (default: `mobius`)
  - Options: `hable` `mobius` `reinhard` `clip` `linear` `gamma` `none`
  - Note: bt2390 is only valid for the libplacebo-based tonemap2 filter, not the tonemap filter used by this script
- `-k <val>`
  - Peak brightness for tone-mapping in nits (default: omitted, letting ffmpeg auto-detect from source metadata)
  - Example: `-k 1000` for a 1000-nit mastered source
- `-l <nits>`
  - Nominal peak luminance of the SDR output display in nits
  - (default: `100`). Raise this if the output appears overbright; values of 150-250 suit most modern displays. Higher values give the tone-mapper more headroom, reducing highlight clipping.
  - Example: `-l 203` (reference white for HDR displays)
- `-s`
  - Force software encode only (skip VideoToolbox entirely)
- `-n`
  - Dry-run: detect files and print commands without converting
- `-h`
  - Show this help message

## Examples:
  `./convert_4k_to_1080p.sh /Volumes/NAS/Movies`

  `./convert_4k_to_1080p.sh "/Volumes/NAS/Movies/My Film (2024).mkv"`

  `./convert_4k_to_1080p.sh -o ~/Desktop/output -b 10000k /Volumes/NAS/Movies`

  `./convert_4k_to_1080p.sh -s /Volumes/NAS/Movies   # force software`

  `./convert_4k_to_1080p.sh -n /Volumes/NAS/Movies   # dry-run`

## Example Output:
(Shortened for brevity)

`./convert_4k_to_1080p.sh movies`

```

╔══════════════════════════════════════════════════════════╗
║        4K HEVC -> 1080p AVC Batch Converter              ║
║              Apple VideoToolbox Edition                  ║
╚══════════════════════════════════════════════════════════╝

  Input         : movies
  Output dir    : <same as source>
  HW decode     : VideoToolbox (-hwaccel videotoolbox)
  HW encode     : h264_videotoolbox (8000k)
  SW fallback   : libx264 crf=18 preset=slow
  Tone-map      : mobius via zscale
  Dry-run       : false

Scanning 114 MKV file(s)...

  SKIP  (not 4K HEVC) -> movies/1408 (2007).mkv
  SKIP  (not 4K HEVC) -> movies/Amadeus (1984).mkv
  SKIP  (not 4K HEVC) -> movies/Apollo 13 (1995).mkv

[1] Found 4K HEVC: movies/Avatar - Fire and Ash (2025).mkv
  HDR detected — hybrid: VT HW decode -> CPU tone-map (mobius) -> VT HW encode
  Output : movies/Avatar - Fire and Ash (2025) - 1080p.mkv
  Pipeline : HW-hybrid (VT decode + CPU tone-map + VT encode)
  Converting...
frame=281641 fps= 36 q=-0.0 Lsize=12661088KiB time=03:17:08.89 bitrate=8768.3kbits/s dup=0 drop=2252 speed=1.53x elapsed=2:08:51.88    
  Done [HW-hybrid (VT decode + CPU tone-map + VT encode)]

  SKIP  (not 4K HEVC) -> movies/Bill & Ted Face the Music (2020).mkv
  SKIP  (not 4K HEVC) -> movies/Bill & Ted's Bogus Journey (1991).mkv
  SKIP  (not 4K HEVC) -> movies/Bill & Ted's Excellent Adventure (1989).mkv

[2] Found 4K HEVC: movies/Captain Phillips (2013).mkv
  HDR detected — hybrid: VT HW decode -> CPU tone-map (mobius) -> VT HW encode
  Output : movies/Captain Phillips (2013) - 1080p.mkv
  Pipeline : HW-hybrid (VT decode + CPU tone-map + VT encode)
  Converting...
frame=192887 fps= 38 q=-0.0 Lsize=10648138KiB time=02:14:04.95 bitrate=10842.8kbits/s speed=1.57x elapsed=1:25:18.30    
  Done [HW-hybrid (VT decode + CPU tone-map + VT encode)]

[3] Found 4K HEVC: movies/Casino Royale (2006).mkv
  HDR detected — hybrid: VT HW decode -> CPU tone-map (mobius) -> VT HW encode
  Output : movies/Casino Royale (2006) - 1080p.mkv
  Pipeline : HW-hybrid (VT decode + CPU tone-map + VT encode)
  Converting...
frame=192887 fps= 38 q=-0.0 Lsize=10648138KiB time=02:14:04.95 bitrate=10842.8kbits/s speed=1.57x elapsed=1:25:18.30    
  Done [HW-hybrid (VT decode + CPU tone-map + VT encode)]


========================================
Summary
  4K HEVC files found : 15
  Converted           : 15
  Errors              : 0
  Skipped             : 99
========================================

```