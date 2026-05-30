#!/bin/zsh
set -u

LIBRARY_INPUT="${1:?Usage: $0 /path/to/library}"

# Apple VideoToolbox quality scale: higher = better quality and larger files.
QUALITY="${QUALITY:-70}"

# Width of the terminal progress bar.
BAR_WIDTH="${BAR_WIDTH:-32}"

if [[ ! -d "$LIBRARY_INPUT" ]]; then
  echo "ERROR: Library folder does not exist: $LIBRARY_INPUT"
  exit 1
fi

# Normalize the path so displayed filenames can be relative to the library root.
LIBRARY="$(cd "$LIBRARY_INPUT" && pwd -P)"

case "$QUALITY" in
  ''|*[!0-9]*)
    echo "ERROR: QUALITY must be an integer between 1 and 100."
    exit 1
    ;;
esac

if (( QUALITY < 1 || QUALITY > 100 )); then
  echo "ERROR: QUALITY must be between 1 and 100."
  exit 1
fi

case "$BAR_WIDTH" in
  ''|*[!0-9]*)
    echo "ERROR: BAR_WIDTH must be a positive integer."
    exit 1
    ;;
esac

if (( BAR_WIDTH < 1 )); then
  echo "ERROR: BAR_WIDTH must be a positive integer."
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1 || \
   ! command -v ffprobe >/dev/null 2>&1; then
  echo "ERROR: ffmpeg and ffprobe are required. Install them with:"
  echo "       brew install ffmpeg"
  exit 1
fi

if ! ffmpeg -hide_banner -encoders 2>/dev/null | \
     grep -q "hevc_videotoolbox"; then
  echo "ERROR: This FFmpeg installation does not expose hevc_videotoolbox."
  exit 1
fi

# Use a progress bar in Terminal, but keep redirected cron logs readable.
INTERACTIVE=0
[[ -t 1 ]] && INTERACTIVE=1
PROGRESS_ACTIVE=0

print_banner() {
  if (( INTERACTIVE )); then
    printf '\033[1;36m'
    printf '   _____ __  ________\n'
    printf '  / ___//  |/  /_  __/\n'
    printf '  \\__ \\/ /|_/ / / /\n'
    printf ' ___/ / /  / / / /\n'
    printf '/____/_/  /_/ /_/\n'
    printf '\033[0m\033[1m   simple-media-transcoder\033[0m\n'
    printf '\033[2m   HEVC library cleanup by marvinvr\033[0m\n'
    printf '\033[2m   \033]8;;https://marvinvr.ch\033\\marvinvr.ch\033]8;;\033\\\033[0m\n\n'
  else
    printf 'simple-media-transcoder by marvinvr\n'
    printf 'https://marvinvr.ch\n\n'
  fi
}

video_codec() {
  ffprobe \
    -v error \
    -select_streams V:0 \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" 2>/dev/null |
    head -n 1
}

video_resolution() {
  ffprobe \
    -v error \
    -select_streams V:0 \
    -show_entries stream=width,height \
    -of csv=s=x:p=0 \
    "$1" 2>/dev/null |
    head -n 1
}

relative_path() {
  local FILE="$1"

  if [[ "$LIBRARY" == "/" ]]; then
    printf '%s' "${FILE#/}"
  else
    printf '%s' "${FILE#"$LIBRARY"/}"
  fi
}

show_progress() {
  local COMPLETED="$1"
  local TOTAL="$2"
  local STATUS="${3:-}"
  local PERCENT=0
  local FILLED=0
  local EMPTY=0
  local BAR=""
  local PREFIX=""
  local I

  if (( ! INTERACTIVE )); then
    return
  fi

  if (( TOTAL > 0 )); then
    PERCENT=$(( COMPLETED * 100 / TOTAL ))
  fi

  FILLED=$(( PERCENT * BAR_WIDTH / 100 ))
  EMPTY=$(( BAR_WIDTH - FILLED ))

  for (( I = 0; I < FILLED; I++ )); do
    BAR+="█"
  done

  for (( I = 0; I < EMPTY; I++ )); do
    BAR+="░"
  done

  PREFIX="$(printf '[%s] %3d%%  %d/%d  ' \
    "$BAR" "$PERCENT" "$COMPLETED" "$TOTAL")"

  printf '\033[u\033[J'
  printf '%s\n%s' "$PREFIX" "$STATUS"
  PROGRESS_ACTIVE=1
}

finish_item() {
  local COMPLETED="$1"
  local TOTAL="$2"
  local STATUS="$3"
  local PERCENT=0

  if (( TOTAL > 0 )); then
    PERCENT=$(( COMPLETED * 100 / TOTAL ))
  fi

  if (( INTERACTIVE )); then
    show_progress "$COMPLETED" "$TOTAL" "$STATUS"
  else
    printf '[%3d%%] %d/%d  %s\n' \
      "$PERCENT" "$COMPLETED" "$TOTAL" "$STATUS"
  fi
}

finish_progress() {
  if (( INTERACTIVE && PROGRESS_ACTIVE )); then
    printf '\n'
    printf '\033[s'
    PROGRESS_ACTIVE=0
  fi
}

print_detail() {
  local MESSAGE="$1"

  if (( INTERACTIVE )); then
    finish_progress
    printf '%s\n' "$MESSAGE"
    printf '\033[s'
  else
    printf '%s\n' "$MESSAGE"
  fi
}

encode_file() {
  local DECODE_MODE="$1"
  local INPUT="$2"
  local OUTPUT="$3"
  local MUXER="$4"
  shift 4

  local -a EXTRA_ARGS
  local -a INPUT_ARGS

  EXTRA_ARGS=("$@")
  INPUT_ARGS=()

  if [[ "$DECODE_MODE" == "hardware" ]]; then
    INPUT_ARGS=(
      -hwaccel videotoolbox
      -hwaccel_output_format videotoolbox_vld
    )
  fi

  ffmpeg \
    -hide_banner \
    -loglevel error \
    -nostdin \
    -y \
    "${INPUT_ARGS[@]}" \
    -i "$INPUT" \
    -map 0 \
    -map_metadata 0 \
    -map_chapters 0 \
    -c copy \
    -c:V:0 hevc_videotoolbox \
    -q:V:0 "$QUALITY" \
    "${EXTRA_ARGS[@]}" \
    -f "$MUXER" \
    "$OUTPUT"
}

print_banner
(( INTERACTIVE )) && printf '\033[s'

# Build the list first so the script knows the total file count.
FILES=()

while IFS= read -r -d '' FILE; do
  FILES+=("$FILE")
done < <(
  find "$LIBRARY" -type f \( \
    -iname "*.mkv" -o \
    -iname "*.mp4" -o \
    -iname "*.m4v" -o \
    -iname "*.mov" \
  \) -print0
)

TOTAL=${#FILES[@]}
SCAN_CURRENT=0
ENCODED=0
SKIPPED_HEVC=0
SKIPPED_LARGER=0
SKIPPED_OTHER=0
FAILED=0
TRANSCODE_FILES=()
TRANSCODE_CODECS=()
TRANSCODE_RESOLUTIONS=()

if (( TOTAL == 0 )); then
  echo "No supported media files found."
  exit 0
fi

show_progress 0 "$TOTAL" "Scanning"

for FILE in "${FILES[@]}"; do
  SCAN_CURRENT=$(( SCAN_CURRENT + 1 ))
  RELATIVE_PATH="$(relative_path "$FILE")"

  show_progress $(( SCAN_CURRENT - 1 )) "$TOTAL" \
    "Scanning: $RELATIVE_PATH"

  CODEC="$(video_codec "$FILE")"
  RESOLUTION="$(video_resolution "$FILE")"

  if [[ -z "$CODEC" || -z "$RESOLUTION" ]]; then
    SKIPPED_OTHER=$(( SKIPPED_OTHER + 1 ))
    finish_item "$SCAN_CURRENT" "$TOTAL" \
      "SCAN SKIP: Could not inspect: $RELATIVE_PATH"
    continue
  fi

  # ffprobe reports both H.265 and HEVC as "hevc".
  if [[ "$CODEC" == "hevc" ]]; then
    SKIPPED_HEVC=$(( SKIPPED_HEVC + 1 ))
    finish_item "$SCAN_CURRENT" "$TOTAL" \
      "SCAN SKIP: Already HEVC: $RELATIVE_PATH"
    continue
  fi

  EXT="$(printf '%s' "${FILE##*.}" | tr '[:upper:]' '[:lower:]')"

  case "$EXT" in
    mkv|mp4|m4v|mov)
      TRANSCODE_FILES+=("$FILE")
      TRANSCODE_CODECS+=("$CODEC")
      TRANSCODE_RESOLUTIONS+=("$RESOLUTION")
      finish_item "$SCAN_CURRENT" "$TOTAL" \
        "QUEUE: $RELATIVE_PATH ($CODEC -> hevc, $RESOLUTION)"
      ;;
    *)
      SKIPPED_OTHER=$(( SKIPPED_OTHER + 1 ))
      finish_item "$SCAN_CURRENT" "$TOTAL" \
        "SCAN SKIP: Unsupported container: $RELATIVE_PATH"
      continue
      ;;
  esac
done

TRANSCODE_TOTAL=${#TRANSCODE_FILES[@]}

if (( INTERACTIVE )); then
  show_progress "$SCAN_CURRENT" "$TOTAL" \
    "Scan complete: $TRANSCODE_TOTAL to transcode"
  finish_progress
else
  echo
fi

if (( TRANSCODE_TOTAL == 0 )); then
  echo "Finished processing $TOTAL files."
  echo "  Queued for transcoding:   0"
  echo "  Encoded and replaced:     $ENCODED"
  echo "  Already HEVC:             $SKIPPED_HEVC"
  echo "  Output was not smaller:   $SKIPPED_LARGER"
  echo "  Other files skipped:      $SKIPPED_OTHER"
  echo "  Failed:                   $FAILED"
  exit 0
fi

show_progress 0 "$TRANSCODE_TOTAL" "Transcoding"

for (( CURRENT = 1; CURRENT <= TRANSCODE_TOTAL; CURRENT++ )); do
  FILE="${TRANSCODE_FILES[$CURRENT]}"
  CODEC="${TRANSCODE_CODECS[$CURRENT]}"
  RESOLUTION="${TRANSCODE_RESOLUTIONS[$CURRENT]}"
  RELATIVE_PATH="$(relative_path "$FILE")"

  EXT="$(printf '%s' "${FILE##*.}" | tr '[:upper:]' '[:lower:]')"
  EXTRA_ARGS=()

  case "$EXT" in
    mkv)
      MUXER="matroska"
      ;;
    mp4|m4v)
      MUXER="mp4"
      EXTRA_ARGS=(-tag:V:0 hvc1)
      ;;
    mov)
      MUXER="mov"
      EXTRA_ARGS=(-tag:V:0 hvc1)
      ;;
    *)
      SKIPPED_OTHER=$(( SKIPPED_OTHER + 1 ))
      finish_item "$CURRENT" "$TRANSCODE_TOTAL" \
        "SKIP: Unsupported container: $RELATIVE_PATH"
      continue
      ;;
  esac

  # Write beside the source so the final rename remains on the same filesystem.
  TEMP="${FILE}.hevc-partial"
  ERROR_LOG="${FILE}.hevc-error.log"

  rm -f "$TEMP" "$ERROR_LOG"

  show_progress $(( CURRENT - 1 )) "$TRANSCODE_TOTAL" \
    "Encoding: $RELATIVE_PATH ($CODEC -> hevc, $RESOLUTION)"

  # Attempt hardware decoding and hardware encoding first.
  if ! encode_file hardware \
    "$FILE" "$TEMP" "$MUXER" "${EXTRA_ARGS[@]}" \
    2>"$ERROR_LOG"
  then
    rm -f "$TEMP"

    show_progress $(( CURRENT - 1 )) "$TRANSCODE_TOTAL" \
      "Retrying with software decode: $RELATIVE_PATH"

    # Fall back to software decoding, but continue using hardware HEVC encoding.
    if ! encode_file software \
      "$FILE" "$TEMP" "$MUXER" "${EXTRA_ARGS[@]}" \
      2>>"$ERROR_LOG"
    then
      FAILED=$(( FAILED + 1 ))
      finish_item "$CURRENT" "$TRANSCODE_TOTAL" \
        "FAILED: Encode error: $RELATIVE_PATH"
      print_detail "        Error log: $ERROR_LOG"
      rm -f "$TEMP"
      continue
    fi
  fi

  OUTPUT_CODEC="$(video_codec "$TEMP")"
  OUTPUT_RESOLUTION="$(video_resolution "$TEMP")"

  if [[ "$OUTPUT_CODEC" != "hevc" ]]; then
    FAILED=$(( FAILED + 1 ))
    finish_item "$CURRENT" "$TRANSCODE_TOTAL" \
      "FAILED: Output is not HEVC: $RELATIVE_PATH"
    rm -f "$TEMP"
    continue
  fi

  if [[ "$OUTPUT_RESOLUTION" != "$RESOLUTION" ]]; then
    FAILED=$(( FAILED + 1 ))
    finish_item "$CURRENT" "$TRANSCODE_TOTAL" \
      "FAILED: Resolution changed $RESOLUTION -> $OUTPUT_RESOLUTION: $RELATIVE_PATH"
    rm -f "$TEMP"
    continue
  fi

  ORIGINAL_SIZE="$(stat -f '%z' "$FILE")"
  OUTPUT_SIZE="$(stat -f '%z' "$TEMP")"

  if (( OUTPUT_SIZE >= ORIGINAL_SIZE )); then
    SKIPPED_LARGER=$(( SKIPPED_LARGER + 1 ))
    finish_item "$CURRENT" "$TRANSCODE_TOTAL" \
      "SKIP: HEVC output is not smaller: $RELATIVE_PATH"
    rm -f "$TEMP" "$ERROR_LOG"
    continue
  fi

  # Preserve permissions and modification timestamp where possible.
  chmod "$(stat -f '%Lp' "$FILE")" "$TEMP" 2>/dev/null || true
  touch -r "$FILE" "$TEMP" 2>/dev/null || true

  if mv -f "$TEMP" "$FILE"; then
    ENCODED=$(( ENCODED + 1 ))
    rm -f "$ERROR_LOG"
    finish_item "$CURRENT" "$TRANSCODE_TOTAL" \
      "DONE: Replaced original: $RELATIVE_PATH"
  else
    FAILED=$(( FAILED + 1 ))
    finish_item "$CURRENT" "$TRANSCODE_TOTAL" \
      "FAILED: Could not replace original: $RELATIVE_PATH"
    rm -f "$TEMP"
  fi
done

if (( INTERACTIVE )); then
  show_progress "$TRANSCODE_TOTAL" "$TRANSCODE_TOTAL" "Transcoding complete"
  finish_progress
else
  echo
fi

echo "Finished processing $TOTAL files."
echo "  Queued for transcoding:   $TRANSCODE_TOTAL"
echo "  Encoded and replaced:     $ENCODED"
echo "  Already HEVC:             $SKIPPED_HEVC"
echo "  Output was not smaller:   $SKIPPED_LARGER"
echo "  Other files skipped:      $SKIPPED_OTHER"
echo "  Failed:                   $FAILED"
