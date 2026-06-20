# simple-media-transcoder

A small macOS shell script for converting a media library to HEVC/H.265.

There are capable tools for automated media transcoding, but some setups do not need a server, web UI, database, worker nodes, or a complex workflow. Sometimes an FFmpeg script and a cron job are enough.

If you _do_ want a dashboard, scheduling, per-library quality settings, and a history database, there is now an optional background service for macOS — see [Background service & web UI](#background-service--web-ui). The plain CLI below keeps working exactly as before.

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

## Trying it on a single file

Before running the transcoder on a whole library, you can test-drive it against
one file. `tryout.sh` encodes a single file to a sidecar output **without
touching the original** and reports the input size, output size, and space
saved:

```bash
chmod +x tryout.sh
./tryout.sh "/Volumes/YourNAS/Media/example.mkv"
```

It reuses `transcode.sh`'s probing and FFmpeg encode command, so the result
matches what a real run would produce.

Sweep several quality values to pick one before committing to a library run:

```bash
QUALITIES="55 65 70 80" ./tryout.sh "/Volumes/YourNAS/Media/example.mkv"
```

Encoded sidecar files are kept (named `example.tryout-q70.mkv`, etc.) so you can
compare them visually. Set `KEEP=0` to delete each one after measuring when you
only care about the sizes.

## Background service & web UI

Beyond the one-shot CLI, SMT can run as an always-on macOS background service with
a small web UI to start, stop, and schedule runs, configure libraries (each with
its own quality), and watch live progress. Every processed file is logged to
SQLite: path, size before/after, space saved, whether it was replaced (only when
the HEVC output is smaller), the decode path used (hardware/software), and the
encode time.

It is built on [Bun](https://bun.sh) with zero external dependencies — Bun's
built-in HTTP server, `bun:sqlite`, and process spawning. The service simply
orchestrates the same `transcode.sh` you use from the CLI.

### Requirements

In addition to FFmpeg, install Bun:

```bash
curl -fsSL https://bun.sh/install | bash
```

### Install (auto-start at login)

```bash
bash install/install.sh
```

This installs a per-user LaunchAgent (`ch.marvinvr.smt`) that starts the service
at login and restarts it if it crashes. It runs as you, so it can see your
mounted volumes under `/Volumes`.

Then open the web UI:

* On this Mac: <http://localhost:8787>
* From your phone or another device on the same network:
  `http://<your-mac-name>.local:8787`

There is no login — the dashboard is open to anyone who can reach it on your
network, so keep it on a trusted LAN.

### Using it

* **Settings** → add your library folders, each with its own quality (1–100).
  Paths are stored in SQLite, so you never have to type them again.
* **Run now** transcodes all enabled libraries. **Stop** aborts safely — originals
  are only ever replaced after a verified, smaller HEVC output, so a stop at worst
  discards an in-progress temporary file.
* **Schedule** a daily or weekly automatic run in Settings (the service has its own
  scheduler; no cron needed).
* The dashboard shows live per-file progress, lifetime space saved, recent files,
  and past runs.

### Where data lives

`~/Library/Application Support/simple-media-transcoder/`

* `config.json` — port, default quality, schedule
* `smt.db` — SQLite history (runs, files, libraries)
* `run.log` — service and run output

### Run in the foreground (without installing)

```bash
bun run server/server.ts
```

### Uninstall

```bash
bash install/uninstall.sh
```

This stops and removes the service but keeps your database. The uninstaller prints
the exact command to fully purge the data directory if you want to.

## Cron example

Run the script every night at 03:00:

```cron
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
0 3 * * * /absolute/path/to/transcode.sh "/Volumes/YourNAS/Media" >> /tmp/simple-media-transcoder.log 2>&1
```

## Warning

This script replaces original files after a successful conversion. Test it against a copied folder before running it on your full library.
