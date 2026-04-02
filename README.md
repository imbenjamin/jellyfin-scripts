# jellyfin-scripts
Collection of scripts I use for Jellyfin / media management on macOS.

See the individual script's README files for details.

- **convert_4k_to_1080p.sh**
  - Scans a directory (or a single file) for a 4K HEVC MKV file and creates a 1080p AVC MKV copy.
  - If the source file is HDR, tonemap it to SDR in the 1080p copy.
  - **Useful to produce a low bandwidth version of videos, for mobiles, downloads, etc.**
- **convert_to_dv81_hdr10only.sh**
  - Scans a directory (or a single file) for a HEVC Dolby Vision MKV file with a HDR10/HDR10+/HLG base layer.
  - Ensures the Dolby Vision profile is Profile 8.1.
  - Converts a HDR10+ base layer to regular HDR10 (as per standard)
  - **Useful for ensuring compatibility with touchy devices like LG webOS TVs.**

## Disclaimer
These scripts havebeen heavily produced by Claude AI. They have been used and tested in my own environment and use case, and I accept no responsibility for the quality of output or usefulness in your own environment. **Review and understand the scripts before running yourself!** There are dry-run modes included in the scripts to preview the changes before running live.

**USE AT YOUR OWN RISK.**