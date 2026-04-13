# mkv_original_english_audio_subtitle_tracks.sh

Recursively scans a directory for MKV files and strips tracks that are unlikely to be needed, keeping only:
- Audio tracks that are English or the movie's original language
- Audio tracks tagged as undetermined (`und`), no linguistic content (`zxx`), or multilingual (`mul`) — kept as a precaution
- Subtitle tracks that are English

If removal would eliminate all audio tracks, all audio is kept untouched.

## Original language detection:
The movie's or show's original language is resolved via the TMDB API using an IMDB or TVDB ID embedded in the filename or its immediate parent directory name. The supported patterns are:
- `Movie.Title.[imdbid-tt1234567].mkv`
- `My.Show.[tvdbid-12345]/My.Show.S01E01.mkv`

The filename is checked first; the parent directory is used as a fallback.

IMDB IDs take precedence over TVDB IDs when both are present.

If no ID is found, or the TMDB lookup fails, audio is filtered to English only as a safe fallback.

## TMDB API token:
Required for original language detection. Supply it either as an environment variable or via the `--tmdb-token` option:
```
export TMDB_TOKEN="your_token_here"
./mkv_original_english_audio_subtitle_tracks.sh /path/to/media
```

or:
```
./mkv_original_english_audio_subtitle_tracks.sh /path/to/media --tmdb-token "your_token_here"
```

If no token is provided, original language detection is skipped and audio is filtered to English only as a safe fallback.

## Scan cache:
A dotfile named ".mkv_track_cache" is written into each directory containing processed MKV files. It records the filename and a fingerprint (file size + modification time) for every successfully processed file. On subsequent runs, files whose fingerprint matches the cache entry are skipped automatically. If a file is replaced or modified, its fingerprint changes and it will be re-processed on the next run. Use `--rescan` to ignore the cache and process all files fresh.

## Output:
By default, each source file is replaced in-place with the cleaned version. Use `--new-file` to write a "_cleaned.mkv" file alongside the original instead, leaving the original untouched.

## Dependencies (must be on PATH):
- `mkvmerge`
  - part of MKVToolNix
  - `brew install mkvtoolnix`
- `jq`
  - JSON processor
  - `brew install jq`
- `curl`
  - HTTP client
  - pre-installed on macOS

## Usage:
- `chmod +x mkv_original_english_audio_subtitle_tracks.sh`
- `./mkv_original_english_audio_subtitle_tracks.sh /path/to/media [options]`

## Options:
- `--tmdb-token <token>`
  - TMDB API read access token.
- `--dry-run`
  - Print what would be changed without modifying any files. instead of replacing it.
- `--new-file`
  - Write a "_cleaned.mkv" file alongside each original instead of replacing it.
- `--rescan`
  - Ignore the scan cache and process all files fresh.