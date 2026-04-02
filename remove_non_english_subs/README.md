# remove_non_english_subs.sh

Recursively searches a directory for MKV files and removes any subtitle tracks whose language is NOT English (i.e. not tagged "eng" or "en").

All video, audio, and other tracks are left completely untouched.

## Requirements:
- mkvtoolnix  (`brew install mkvtoolnix`)

## Usage:
`chmod +x remove_non_english_subs.sh`

`./remove_non_english_subs.sh [OPTIONS] <directory>`

## Options:
- `-d`, `--dry-run`   Show what would be done without modifying any files
- `-v`, `--verbose`   Print detailed track information for every file
- `-h`, `--help`      Show this help message