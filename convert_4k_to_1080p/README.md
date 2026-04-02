# convert_4k_to_1080p.sh

Recursively scans a directory for 4K UHD HEVC (H.265) MKV files and
converts them to 1080p HD AVC (H.264) MKV files with HDR→SDR tone mapping.
Audio and subtitle tracks are copied without modification.

Hardware acceleration: Apple VideoToolbox (macOS) is used by default for
both decoding (hevc_videotoolbox) and encoding (h264_videotoolbox).
HDR tone-mapping is performed in software (CPU) as VideoToolbox does not
support it natively; the script automatically uses a hybrid pipeline
(HW decode → CPU tone-map/scale → HW encode) for HDR sources and a
fully hardware pipeline for SDR sources.
Falls back to software (libx264) automatically if VideoToolbox is
unavailable or fails to initialise for a given file.

## Requirements:
  - ffmpeg + ffprobe: static builds from https://evermeet.cx/ffmpeg/
    These include VideoToolbox, libx264, libzimg (zscale), and all
    required filters. The standard Homebrew ffmpeg does NOT include
    libzimg/zscale and will not work for HDR tone-mapping.
     Install:
      curl -L https://evermeet.cx/ffmpeg/get/zip -o ffmpeg.zip && unzip ffmpeg.zip
      curl -L https://evermeet.cx/ffmpeg/get/ffprobe/zip -o ffprobe.zip && unzip ffprobe.zip
      sudo mv ffmpeg ffprobe /usr/local/bin/
      sudo xattr -d com.apple.quarantine /usr/local/bin/ffmpeg /usr/local/bin/ffprobe

  - macOS 10.13+ (VideoToolbox HEVC decode requires Metal/macOS 10.13+)

## Usage:
  ./convert_4k_to_1080p.sh [OPTIONS] <input>
   <input> can be:
    - A directory: recursively scanned for 4K HEVC MKV files
    - A single MKV file: converted directly (must be 4K HEVC)

 ## Options:
  -o <dir>    Output directory for converted files
              (default: same directory as each source file)
              Output filename is always "<original name> - 1080p.mkv"
  -b <rate>   VideoToolbox encode bitrate (default: 8000k)
              Examples: 6000k, 8000k, 12000k. Ignored in SW mode.
  -c <val>    Software fallback CRF 0-51 (default: 18, lower=better)
  -p <preset> Software fallback x264 preset (default: slow)
  -t <method> Tone-mapping algorithm (default: mobius)
              Options: hable mobius reinhard clip linear gamma none
              Note: bt2390 is only valid for the libplacebo-based
              tonemap2 filter, not the tonemap filter used by this script
  -k <val>    Peak brightness for tone-mapping in nits (default: omitted,
              letting ffmpeg auto-detect from source metadata)
              Example: -k 1000 for a 1000-nit mastered source
  -s          Force software encode only (skip VideoToolbox entirely)
  -n          Dry-run: detect files and print commands without converting
  -h          Show this help message

## Examples:
  ./convert_4k_to_1080p.sh /Volumes/NAS/Movies
  ./convert_4k_to_1080p.sh "/Volumes/NAS/Movies/My Film (2024).mkv"
  ./convert_4k_to_1080p.sh -o ~/Desktop/output -b 10000k /Volumes/NAS/Movies
  ./convert_4k_to_1080p.sh -s /Volumes/NAS/Movies   # force software
  ./convert_4k_to_1080p.sh -n /Volumes/NAS/Movies   # dry-run
