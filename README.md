# simple-media-transcoder

A small macOS shell script for converting a media library to HEVC/H.265.

There are capable tools for automated media transcoding, but some setups do not need a server, web UI, database, worker nodes, or a complex workflow. Sometimes an FFmpeg script and a cron job are enough.

`transcode.sh` recursively scans a media folder and:

* Skips files that are already HEVC/H.265
* Encodes other video files to HEVC using Apple VideoToolbox hardware acceleration
* Tries hardware decoding first and falls back to software decoding when needed
* Keeps the original resolution
* Copies audio tracks, subtitles, chapters, attachments, and metadata
* Replaces the original only after verifying the output
* Keeps the original when the transcoded file is not smaller
* Shows separate scanning, transcoding, and per-file encode progress with relative paths

Supported containers: MKV, MP4, M4V, and MOV.

## Requirements

Install FFmpeg with Homebrew:

```bash
brew install ffmpeg
```

## Usage

```bash
chmod +x transcode.sh
./transcode.sh "/Volumes/YourNAS/Media"
```

You can pass multiple folders. The script scans each folder first, then
transcodes one combined queue:

```bash
./transcode.sh "/Volumes/YourNAS/Movies" "/Volumes/YourNAS/Shows"
```

The default quality setting is `70`. Override it for a specific run with:

```bash
QUALITY=65 ./transcode.sh "/Volumes/YourNAS/Media"
```

## Cron example

Run the script every night at 03:00:

```cron
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
0 3 * * * /absolute/path/to/transcode.sh "/Volumes/YourNAS/Media" >> /tmp/simple-media-transcoder.log 2>&1
```

## Warning

This script replaces original files after a successful conversion. Test it against a copied folder before running it on your full library.
