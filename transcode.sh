#!/bin/zsh
set -u

# Apple VideoToolbox quality scale: higher = better quality and larger files.
QUALITY="${QUALITY:-70}"

# Width of the terminal progress bar.
BAR_WIDTH="${BAR_WIDTH:-32}"

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

# Machine-readable event output for the SMT background service. When SMT_MACHINE=1
# (set by the daemon) the script emits one structured "@@SMT" line per event on
# stdout, in addition to the normal human output, so the daemon can drive a live
# web UI and persist results. Interactive and cron behavior are unchanged when
# SMT_MACHINE is unset.
SMT_MACHINE="${SMT_MACHINE:-0}"
case "$SMT_MACHINE" in
  ''|*[!0-9]*) SMT_MACHINE=0 ;;
esac

# Operating mode for the SMT daemon. Empty = legacy standalone behavior (scan
# every library argument, then transcode serially in one process). The daemon
# drives two narrower modes so it can run several encodes at once:
#   scan  — scan ONE library and emit a "queue_item" event for every file that
#           needs transcoding (after pre-filtering the worklog), then exit.
#   file  — transcode exactly ONE already-scanned file, described via SMT_FILE,
#           SMT_LIBRARY, SMT_CODEC, SMT_RES and SMT_DURATION, then exit.
SMT_MODE="${SMT_MODE:-}"

# Worklog skip set, loaded from SMT_SKIP_FILE (written by the daemon): maps an
# absolute path to the file size that was kept (HEVC output was not smaller) at
# the current quality on a previous run. Such files are skipped during scanning
# so we never waste time re-encoding a file we already decided to keep.
typeset -gA SMT_SKIP_SIZES
SMT_SKIP_LOADED=0

# Which decode path produced the last successful encode (hardware|software|-).
LAST_DECODE_MODE="-"

# The temp output and error log of the file currently being encoded. A TERM/INT
# from the daemon uses these to clean up a half-written sidecar before exiting.
CURRENT_TEMP=""
CURRENT_ERROR_LOG=""

# Encode an arbitrary string for safe single-line transport (paths may contain
# spaces, tabs, quotes, or non-UTF8 bytes). The daemon base64-decodes it.
smt_b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

# Emit one tab-delimited event line: "@@SMT<TAB>type<TAB>k=v<TAB>k=v...".
emit() {
  (( SMT_MACHINE )) || return 0
  local LINE="@@SMT"$'\t'"$1"
  shift
  local FIELD
  for FIELD in "$@"; do
    LINE+=$'\t'"$FIELD"
  done
  printf '%s\n' "$LINE"
}

# Load the worklog skip set from SMT_SKIP_FILE. Each line is
# "<size><TAB><base64 absolute path>"; base64 keeps arbitrary bytes in paths
# intact. Safe to call repeatedly — it reads the file at most once.
load_skip_set() {
  (( SMT_SKIP_LOADED )) && return 0
  SMT_SKIP_LOADED=1
  local SKIP_FILE="${SMT_SKIP_FILE:-}"
  [[ -n "$SKIP_FILE" && -r "$SKIP_FILE" ]] || return 0
  local SIZE B64 DECODED_PATH
  while IFS=$'\t' read -r SIZE B64; do
    [[ -z "$B64" ]] && continue
    DECODED_PATH="$(printf '%s' "$B64" | base64 -d 2>/dev/null)" || continue
    [[ -z "$DECODED_PATH" ]] && continue
    SMT_SKIP_SIZES[$DECODED_PATH]="$SIZE"
  done < "$SKIP_FILE"
}

smt_cleanup_on_signal() {
  # Kill the in-flight ffmpeg (and the progress-reading subshell) so the run
  # aborts immediately instead of falling through to the next queued file, then
  # remove the half-written sidecar before exiting.
  pkill -P $$ 2>/dev/null
  [[ -n "$CURRENT_TEMP" ]] && rm -f "$CURRENT_TEMP"
  [[ -n "$CURRENT_ERROR_LOG" ]] && rm -f "$CURRENT_ERROR_LOG"
  exit 143
}

if (( SMT_MACHINE )); then
  trap 'smt_cleanup_on_signal' TERM INT
fi

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

video_duration() {
  ffprobe \
    -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" 2>/dev/null |
    awk 'NR == 1 && $1 ~ /^[0-9]+([.][0-9]+)?$/ { printf "%.0f\n", $1 }'
}

# Average frame rate of the primary video stream as a decimal (e.g. 23.976).
# Used to derive encode progress from the frame counter when ffmpeg reports
# out_time as "N/A" — common with the VideoToolbox hardware-decode pipeline,
# which leaves out_time/speed/bitrate as N/A while frame/fps keep counting.
# Prints 0 when the rate cannot be determined.
video_frame_rate() {
  ffprobe \
    -v error \
    -select_streams V:0 \
    -show_entries stream=avg_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" 2>/dev/null |
    awk -F'/' 'NR == 1 {
      if ($2 + 0 > 0) { printf "%.6f\n", $1 / $2; }
      else if ($1 ~ /^[0-9.]+$/) { printf "%.6f\n", $1; }
      else { print "0"; }
      exit
    }'
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
  local DETAIL="${4:-}"
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
  if [[ -n "$DETAIL" ]]; then
    printf '\n%s' "$DETAIL"
  fi
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

format_duration() {
  local TOTAL_SECONDS="${1:-0}"
  local HOURS=0
  local MINUTES=0
  local SECONDS=0

  case "$TOTAL_SECONDS" in
    ''|*[!0-9]*)
      printf '%s' '--:--:--'
      return
      ;;
  esac

  HOURS=$(( TOTAL_SECONDS / 3600 ))
  MINUTES=$(( (TOTAL_SECONDS % 3600) / 60 ))
  SECONDS=$(( TOTAL_SECONDS % 60 ))

  printf '%02d:%02d:%02d' "$HOURS" "$MINUTES" "$SECONDS"
}

show_encode_progress() {
  local COMPLETED="$1"
  local TOTAL="$2"
  local STATUS="$3"
  local DURATION_SECONDS="$4"
  local OUT_TIME_US="${5:-0}"
  local FPS="${6:-?}"
  local SPEED="${7:-?}"
  local OUT_SECONDS=0
  local FILE_PERCENT_TEXT=""
  local DETAIL=""

  case "$OUT_TIME_US" in
    ''|*[!0-9]*)
      OUT_TIME_US=0
      ;;
  esac

  OUT_SECONDS=$(( OUT_TIME_US / 1000000 ))

  if [[ "$FPS" == "N/A" || -z "$FPS" ]]; then
    FPS="?"
  fi

  if [[ "$SPEED" == "N/A" || -z "$SPEED" ]]; then
    SPEED="?"
  fi

  case "$DURATION_SECONDS" in
    ''|*[!0-9]*|0)
      FILE_PERCENT_TEXT="--%"
      ;;
    *)
      if (( OUT_SECONDS > DURATION_SECONDS )); then
        OUT_SECONDS="$DURATION_SECONDS"
      fi
      FILE_PERCENT_TEXT="$(( OUT_SECONDS * 100 / DURATION_SECONDS ))%"
      ;;
  esac

  DETAIL="$(printf 'Current file: %s  %s / %s  %s fps  %s' \
    "$FILE_PERCENT_TEXT" \
    "$(format_duration "$OUT_SECONDS")" \
    "$(format_duration "$DURATION_SECONDS")" \
    "$FPS" \
    "$SPEED")"

  show_progress "$COMPLETED" "$TOTAL" "$STATUS" "$DETAIL"
}

encode_file() {
  local DECODE_MODE="$1"
  local INPUT="$2"
  local OUTPUT="$3"
  local MUXER="$4"
  local COMPLETED="$5"
  local TOTAL="$6"
  local STATUS="$7"
  local DURATION_SECONDS="$8"
  shift 8

  local -a EXTRA_ARGS
  local -a INPUT_ARGS
  local KEY=""
  local VALUE=""
  local OUT_TIME_US=0
  local FRAME=0
  local FPS="?"
  local SPEED="?"
  local -a PIPE_STATUS

  EXTRA_ARGS=("$@")
  INPUT_ARGS=()

  if [[ "$DECODE_MODE" == "hardware" ]]; then
    INPUT_ARGS=(
      -hwaccel videotoolbox
      -hwaccel_output_format videotoolbox_vld
    )
  fi

  # Source frame rate and a wall-clock anchor, used to keep progress moving when
  # ffmpeg reports out_time/speed as N/A (see video_frame_rate). Resolved before
  # the encode so they are visible inside the progress-reading subshell below.
  local FRAME_RATE
  FRAME_RATE="$(video_frame_rate "$INPUT")"
  local PROG_START=$SECONDS

  ffmpeg \
    -hide_banner \
    -loglevel error \
    -stats_period 1 \
    -progress pipe:1 \
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
    "$OUTPUT" |
    while IFS='=' read -r KEY VALUE; do
      case "$KEY" in
        frame)
          FRAME="$VALUE"
          ;;
        fps)
          FPS="$VALUE"
          ;;
        out_time_ms|out_time_us)
          OUT_TIME_US="$VALUE"
          ;;
        speed)
          SPEED="$VALUE"
          ;;
        progress)
          # Output position in whole seconds. ffmpeg's VideoToolbox HW-decode
          # pipeline frequently reports out_time as N/A even while frame/fps
          # keep advancing, so fall back to (frame / source fps) to keep the
          # percentage and ETA from stalling at zero.
          local PROG_OUT=0
          case "$OUT_TIME_US" in
            ''|*[!0-9]*) PROG_OUT=0 ;;
            *) PROG_OUT=$(( OUT_TIME_US / 1000000 )) ;;
          esac
          if (( PROG_OUT == 0 )) && [[ "$FRAME" == <-> ]] && (( FRAME > 0 )); then
            PROG_OUT=$(awk -v f="$FRAME" -v r="$FRAME_RATE" \
              'BEGIN { if (r + 0 > 0) printf "%d", f / r; else print 0 }')
          fi
          if (( DURATION_SECONDS > 0 && PROG_OUT > DURATION_SECONDS )); then
            PROG_OUT=$DURATION_SECONDS
          fi

          # Prefer ffmpeg's speed; when it is N/A, derive it from output
          # position versus wall-clock time so the ETA can still be computed.
          local PROG_SPEED="$SPEED"
          if [[ "$SPEED" == "N/A" || "$SPEED" == "?" || -z "$SPEED" ]]; then
            local WALL=$(( SECONDS - PROG_START ))
            if (( WALL > 0 && PROG_OUT > 0 )); then
              PROG_SPEED="$(awk -v o="$PROG_OUT" -v w="$WALL" \
                'BEGIN { printf "%.2fx", o / w }')"
            else
              PROG_SPEED="?"
            fi
          fi

          show_encode_progress "$COMPLETED" "$TOTAL" "$STATUS" \
            "$DURATION_SECONDS" "$(( PROG_OUT * 1000000 ))" "$FPS" "$PROG_SPEED"
          if (( SMT_MACHINE )); then
            local PROG_PCT=0
            if (( DURATION_SECONDS > 0 )); then
              PROG_PCT=$(( PROG_OUT * 100 / DURATION_SECONDS ))
            fi
            emit file_prog "pct=$PROG_PCT" "out=$PROG_OUT" \
              "dur=$DURATION_SECONDS" "fps=$FPS" "speed=$PROG_SPEED"
          fi
          ;;
      esac
    done

  PIPE_STATUS=("${pipestatus[@]}")
  return "${PIPE_STATUS[1]}"
}

# Map a lowercase file extension to its ffmpeg muxer and any container-specific
# encoder arguments. Sets MUXER and EXTRA_ARGS in the caller's scope and returns
# non-zero for unsupported containers. Shared by the library run and the tryout.
select_muxer() {
  local EXT="$1"

  case "$EXT" in
    mkv)
      MUXER="matroska"
      EXTRA_ARGS=()
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
      return 1
      ;;
  esac
}

# Encode INPUT to OUTPUT, trying hardware decoding first and falling back to
# software decoding (HEVC encoding stays on the hardware encoder either way).
# ffmpeg stderr is captured in ERROR_LOG. Returns the encoder's exit status.
# Shared by the library run and the single-file tryout.
encode_with_fallback() {
  local INPUT="$1"
  local OUTPUT="$2"
  local MUXER="$3"
  local COMPLETED="$4"
  local TOTAL="$5"
  local STATUS="$6"
  local DURATION_SECONDS="$7"
  local ERROR_LOG="$8"
  local RETRY_STATUS="$9"
  shift 9

  local -a EXTRA_ARGS
  EXTRA_ARGS=("$@")

  # Attempt hardware decoding and hardware encoding first.
  if encode_file hardware \
    "$INPUT" "$OUTPUT" "$MUXER" \
    "$COMPLETED" "$TOTAL" "$STATUS" \
    "$DURATION_SECONDS" \
    "${EXTRA_ARGS[@]}" \
    2>"$ERROR_LOG"
  then
    LAST_DECODE_MODE="hardware"
    return 0
  fi

  rm -f "$OUTPUT"

  show_progress "$COMPLETED" "$TOTAL" "$RETRY_STATUS"

  # Fall back to software decoding, but continue using hardware HEVC encoding.
  if encode_file software \
    "$INPUT" "$OUTPUT" "$MUXER" \
    "$COMPLETED" "$TOTAL" "$RETRY_STATUS" \
    "$DURATION_SECONDS" \
    "${EXTRA_ARGS[@]}" \
    2>>"$ERROR_LOG"
  then
    LAST_DECODE_MODE="software"
    return 0
  fi

  return 1
}

print_section() {
  local TITLE="$1"

  finish_progress
  if (( INTERACTIVE )); then
    printf '\033[1m== %s ==\033[0m\n' "$TITLE"
    printf '\033[s'
  else
    printf '== %s ==\n' "$TITLE"
  fi
}

# Probe one media file and classify it. Emits exactly one machine event:
#   queue_item  — needs transcoding (carries codec/res/dur)
#   scan_skip   — skipped, with reason=worklog|hevc|other
# It also appends to the TRANSCODE_* arrays and bumps the SKIPPED_* counters, but
# those parent-side effects only take hold when the probe runs in the foreground
# (serial scan). In a background probe job they are discarded with the subshell;
# the daemon instead tallies everything from the emitted events. SCAN_TOTAL and
# the counters/arrays are resolved via the caller's (scan_library) scope.
scan_probe_one() {
  local FILE="$1"
  local INDEX="$2"
  local LIBRARY="$3"
  local RELATIVE_PATH CODEC RESOLUTION DURATION EXT CURRENT_SIZE

  RELATIVE_PATH="$(relative_path "$FILE")"

  # Worklog skip: same file (path + size) was already encoded at this quality and
  # the HEVC output was not smaller, so we decided to keep the original.
  if [[ -n "${SMT_SKIP_SIZES[$FILE]:-}" ]]; then
    CURRENT_SIZE="$(stat -f '%z' "$FILE" 2>/dev/null || printf '0')"
    if [[ "${SMT_SKIP_SIZES[$FILE]}" == "$CURRENT_SIZE" ]]; then
      SKIPPED_WORKLOG=$(( SKIPPED_WORKLOG + 1 ))
      emit scan_skip "reason=worklog" "rel_b64=$(smt_b64 "$RELATIVE_PATH")"
      finish_item "$INDEX" "$SCAN_TOTAL" \
        "SCAN SKIP: Kept on a previous run (q$QUALITY): $RELATIVE_PATH"
      return 0
    fi
  fi

  CODEC="$(video_codec "$FILE")"
  RESOLUTION="$(video_resolution "$FILE")"
  DURATION="$(video_duration "$FILE")"
  [[ -z "$DURATION" ]] && DURATION=0

  if [[ -z "$CODEC" || -z "$RESOLUTION" ]]; then
    SKIPPED_OTHER=$(( SKIPPED_OTHER + 1 ))
    emit scan_skip "reason=other" "rel_b64=$(smt_b64 "$RELATIVE_PATH")"
    finish_item "$INDEX" "$SCAN_TOTAL" \
      "SCAN SKIP: Could not inspect: $RELATIVE_PATH"
    return 0
  fi

  # ffprobe reports both H.265 and HEVC as "hevc".
  if [[ "$CODEC" == "hevc" ]]; then
    SKIPPED_HEVC=$(( SKIPPED_HEVC + 1 ))
    emit scan_skip "reason=hevc" "rel_b64=$(smt_b64 "$RELATIVE_PATH")"
    finish_item "$INDEX" "$SCAN_TOTAL" \
      "SCAN SKIP: Already HEVC: $RELATIVE_PATH"
    return 0
  fi

  EXT="$(printf '%s' "${FILE##*.}" | tr '[:upper:]' '[:lower:]')"

  case "$EXT" in
    mkv|mp4|m4v|mov)
      TRANSCODE_FILES+=("$FILE")
      TRANSCODE_LIBRARIES+=("$LIBRARY")
      TRANSCODE_CODECS+=("$CODEC")
      TRANSCODE_RESOLUTIONS+=("$RESOLUTION")
      TRANSCODE_DURATIONS+=("$DURATION")
      emit queue_item "codec=$CODEC" "res=$RESOLUTION" "dur=$DURATION" \
        "rel_b64=$(smt_b64 "$RELATIVE_PATH")" "path_b64=$(smt_b64 "$FILE")"
      finish_item "$INDEX" "$SCAN_TOTAL" \
        "QUEUE: $RELATIVE_PATH ($CODEC -> hevc, $RESOLUTION)"
      ;;
    *)
      SKIPPED_OTHER=$(( SKIPPED_OTHER + 1 ))
      emit scan_skip "reason=other" "rel_b64=$(smt_b64 "$RELATIVE_PATH")"
      finish_item "$INDEX" "$SCAN_TOTAL" \
        "SCAN SKIP: Unsupported container: $RELATIVE_PATH"
      ;;
  esac
  return 0
}

scan_library() {
  local LIBRARY_INPUT="$1"
  local LIBRARY=""
  local FILE=""
  local SCAN_CURRENT=0
  local SCAN_TOTAL=0
  local QUEUED_BEFORE=0
  local SCAN_JOBS=1
  local -a FILES

  # Normalize the path so displayed filenames can be relative to the library root.
  LIBRARY="$(cd "$LIBRARY_INPUT" && pwd -P)"
  print_section "Scanning: $LIBRARY"

  emit scan_start "lib_b64=$(smt_b64 "$LIBRARY")"
  load_skip_set

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

  SCAN_TOTAL=${#FILES[@]}
  TOTAL_FILES=$(( TOTAL_FILES + SCAN_TOTAL ))
  QUEUED_BEFORE=${#TRANSCODE_FILES[@]}

  emit scan_total "total=$SCAN_TOTAL"

  if (( SCAN_TOTAL == 0 )); then
    emit scan_done "queued=${#TRANSCODE_FILES[@]}" "total=$SCAN_TOTAL"
    echo "No supported media files found."
    return
  fi

  show_progress 0 "$SCAN_TOTAL" "Scanning"

  # How many files to probe at once. Parallel probing is only used when the
  # daemon drives the scan (SMT_MACHINE); interactive/standalone scans stay
  # serial so the live progress bar and printed summary stay coherent (and the
  # SKIPPED_* counters, which a background subshell cannot propagate, are right).
  SCAN_JOBS="${SMT_SCAN_JOBS:-1}"
  case "$SCAN_JOBS" in ''|*[!0-9]*) SCAN_JOBS=1 ;; esac
  (( SCAN_JOBS < 1 )) && SCAN_JOBS=1

  if (( SCAN_JOBS <= 1 || ! SMT_MACHINE )); then
    for FILE in "${FILES[@]}"; do
      SCAN_CURRENT=$(( SCAN_CURRENT + 1 ))
      show_progress $(( SCAN_CURRENT - 1 )) "$SCAN_TOTAL" \
        "Scanning: $(relative_path "$FILE")"
      scan_probe_one "$FILE" "$SCAN_CURRENT" "$LIBRARY"
    done
  else
    # Probe up to SCAN_JOBS files concurrently. Each job writes its event lines
    # to its own temp file; the parent prints them in order once a batch finishes
    # so the daemon never sees interleaved partial lines from concurrent writers.
    local SCAN_TMPDIR="" IDX INFLIGHT=0
    local -a BATCH
    SCAN_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/smt-scan.XXXXXX" 2>/dev/null)" || SCAN_TMPDIR=""

    if [[ -z "$SCAN_TMPDIR" ]]; then
      for FILE in "${FILES[@]}"; do
        SCAN_CURRENT=$(( SCAN_CURRENT + 1 ))
        scan_probe_one "$FILE" "$SCAN_CURRENT" "$LIBRARY"
      done
    else
      BATCH=()
      for FILE in "${FILES[@]}"; do
        SCAN_CURRENT=$(( SCAN_CURRENT + 1 ))
        scan_probe_one "$FILE" "$SCAN_CURRENT" "$LIBRARY" \
          > "$SCAN_TMPDIR/$SCAN_CURRENT" 2>/dev/null &
        BATCH+=("$SCAN_CURRENT")
        if (( ++INFLIGHT >= SCAN_JOBS )); then
          wait
          for IDX in "${BATCH[@]}"; do
            cat "$SCAN_TMPDIR/$IDX" 2>/dev/null
            rm -f "$SCAN_TMPDIR/$IDX"
          done
          BATCH=()
          INFLIGHT=0
        fi
      done
      wait
      for IDX in "${BATCH[@]}"; do
        cat "$SCAN_TMPDIR/$IDX" 2>/dev/null
        rm -f "$SCAN_TMPDIR/$IDX"
      done
      rmdir "$SCAN_TMPDIR" 2>/dev/null
    fi
  fi

  emit scan_done "queued=${#TRANSCODE_FILES[@]}" "total=$SCAN_TOTAL"

  if (( INTERACTIVE )); then
    show_progress "$SCAN_CURRENT" "$SCAN_TOTAL" \
      "Scan complete: $((${#TRANSCODE_FILES[@]} - QUEUED_BEFORE)) queued from this path"
    finish_progress
  else
    echo
  fi
}

# Transcode a single, already-scanned file in place. All metadata is passed in
# (no probing here) and the function emits file_start/file_prog/file_done and
# updates the counters. It always returns 0: a per-file failure must never abort
# the caller (the legacy loop or a single daemon worker). Used by both
# transcode_all (legacy serial run) and file mode (one daemon worker).
transcode_one_file() {
  local FILE="$1"
  local LIBRARY="$2"
  local CODEC="$3"
  local RESOLUTION="$4"
  local DURATION="$5"
  local CURRENT="$6"
  local TRANSCODE_TOTAL="$7"

  local RELATIVE_PATH=""
  local EXT=""
  local MUXER=""
  local TEMP=""
  local ERROR_LOG=""
  local OUTPUT_CODEC=""
  local OUTPUT_RESOLUTION=""
  local ORIGINAL_SIZE=0
  local OUTPUT_SIZE=0
  local ENC_START=0
  local -a EXTRA_ARGS

  RELATIVE_PATH="$(relative_path "$FILE")"

  EXT="$(printf '%s' "${FILE##*.}" | tr '[:upper:]' '[:lower:]')"

  if ! select_muxer "$EXT"; then
    SKIPPED_OTHER=$(( SKIPPED_OTHER + 1 ))
    finish_item "$CURRENT" "$TRANSCODE_TOTAL" \
      "SKIP: Unsupported container: $RELATIVE_PATH"
    emit file_done "status=skipped_other" "size_before=0" "size_after=0" \
      "decode=-" "enc=0" "rel_b64=$(smt_b64 "$RELATIVE_PATH")" \
      "path_b64=$(smt_b64 "$FILE")"
    return 0
  fi

  # Write beside the source so the final rename remains on the same filesystem.
  TEMP="${FILE}.hevc-partial"
  ERROR_LOG="${FILE}.hevc-error.log"

  rm -f "$TEMP" "$ERROR_LOG"

  ORIGINAL_SIZE="$(stat -f '%z' "$FILE" 2>/dev/null || printf '0')"
  LAST_DECODE_MODE="-"
  ENC_START=$SECONDS
  CURRENT_TEMP="$TEMP"
  CURRENT_ERROR_LOG="$ERROR_LOG"

  emit file_start "index=$CURRENT" "total=$TRANSCODE_TOTAL" \
    "size_before=$ORIGINAL_SIZE" "codec=$CODEC" "res=$RESOLUTION" \
    "dur=$DURATION" "rel_b64=$(smt_b64 "$RELATIVE_PATH")" \
    "path_b64=$(smt_b64 "$FILE")"

  show_progress $(( CURRENT - 1 )) "$TRANSCODE_TOTAL" \
    "Encoding: $RELATIVE_PATH ($CODEC -> hevc, $RESOLUTION)"

  if ! encode_with_fallback \
    "$FILE" "$TEMP" "$MUXER" \
    $(( CURRENT - 1 )) "$TRANSCODE_TOTAL" \
    "Encoding: $RELATIVE_PATH ($CODEC -> hevc, $RESOLUTION)" \
    "$DURATION" "$ERROR_LOG" \
    "Retrying with software decode: $RELATIVE_PATH" \
    "${EXTRA_ARGS[@]}"
  then
    FAILED=$(( FAILED + 1 ))
    finish_item "$CURRENT" "$TRANSCODE_TOTAL" \
      "FAILED: Encode error: $RELATIVE_PATH"
    print_detail "        Error log: $ERROR_LOG"
    emit file_done "status=failed" "size_before=$ORIGINAL_SIZE" \
      "size_after=0" "decode=$LAST_DECODE_MODE" \
      "enc=$(( SECONDS - ENC_START ))" \
      "rel_b64=$(smt_b64 "$RELATIVE_PATH")" \
      "path_b64=$(smt_b64 "$FILE")" \
      "err_b64=$(smt_b64 "$(tail -c 800 "$ERROR_LOG" 2>/dev/null)")"
    CURRENT_TEMP=""
    CURRENT_ERROR_LOG=""
    rm -f "$TEMP"
    return 0
  fi

  OUTPUT_CODEC="$(video_codec "$TEMP")"
  OUTPUT_RESOLUTION="$(video_resolution "$TEMP")"

  if [[ "$OUTPUT_CODEC" != "hevc" ]]; then
    FAILED=$(( FAILED + 1 ))
    finish_item "$CURRENT" "$TRANSCODE_TOTAL" \
      "FAILED: Output is not HEVC: $RELATIVE_PATH"
    emit file_done "status=failed" "size_before=$ORIGINAL_SIZE" \
      "size_after=0" "decode=$LAST_DECODE_MODE" \
      "enc=$(( SECONDS - ENC_START ))" \
      "rel_b64=$(smt_b64 "$RELATIVE_PATH")" \
      "path_b64=$(smt_b64 "$FILE")" \
      "err_b64=$(smt_b64 "Output codec was ${OUTPUT_CODEC:-unknown}, not hevc")"
    CURRENT_TEMP=""
    CURRENT_ERROR_LOG=""
    rm -f "$TEMP"
    return 0
  fi

  if [[ "$OUTPUT_RESOLUTION" != "$RESOLUTION" ]]; then
    FAILED=$(( FAILED + 1 ))
    finish_item "$CURRENT" "$TRANSCODE_TOTAL" \
      "FAILED: Resolution changed $RESOLUTION -> $OUTPUT_RESOLUTION: $RELATIVE_PATH"
    emit file_done "status=failed" "size_before=$ORIGINAL_SIZE" \
      "size_after=0" "decode=$LAST_DECODE_MODE" \
      "enc=$(( SECONDS - ENC_START ))" \
      "rel_b64=$(smt_b64 "$RELATIVE_PATH")" \
      "path_b64=$(smt_b64 "$FILE")" \
      "err_b64=$(smt_b64 "Resolution changed $RESOLUTION -> $OUTPUT_RESOLUTION")"
    CURRENT_TEMP=""
    CURRENT_ERROR_LOG=""
    rm -f "$TEMP"
    return 0
  fi

  OUTPUT_SIZE="$(stat -f '%z' "$TEMP")"

  if (( OUTPUT_SIZE >= ORIGINAL_SIZE )); then
    SKIPPED_LARGER=$(( SKIPPED_LARGER + 1 ))
    finish_item "$CURRENT" "$TRANSCODE_TOTAL" \
      "SKIP: HEVC output is not smaller: $RELATIVE_PATH"
    emit file_done "status=not_smaller" "size_before=$ORIGINAL_SIZE" \
      "size_after=$OUTPUT_SIZE" "decode=$LAST_DECODE_MODE" \
      "enc=$(( SECONDS - ENC_START ))" \
      "rel_b64=$(smt_b64 "$RELATIVE_PATH")" \
      "path_b64=$(smt_b64 "$FILE")"
    CURRENT_TEMP=""
    CURRENT_ERROR_LOG=""
    rm -f "$TEMP" "$ERROR_LOG"
    return 0
  fi

  # Preserve permissions and modification timestamp where possible.
  chmod "$(stat -f '%Lp' "$FILE")" "$TEMP" 2>/dev/null || true
  touch -r "$FILE" "$TEMP" 2>/dev/null || true

  if mv -f "$TEMP" "$FILE"; then
    ENCODED=$(( ENCODED + 1 ))
    rm -f "$ERROR_LOG"
    finish_item "$CURRENT" "$TRANSCODE_TOTAL" \
      "DONE: Replaced original: $RELATIVE_PATH"
    emit file_done "status=replaced" "size_before=$ORIGINAL_SIZE" \
      "size_after=$OUTPUT_SIZE" "decode=$LAST_DECODE_MODE" \
      "enc=$(( SECONDS - ENC_START ))" \
      "rel_b64=$(smt_b64 "$RELATIVE_PATH")" \
      "path_b64=$(smt_b64 "$FILE")"
  else
    FAILED=$(( FAILED + 1 ))
    finish_item "$CURRENT" "$TRANSCODE_TOTAL" \
      "FAILED: Could not replace original: $RELATIVE_PATH"
    emit file_done "status=failed" "size_before=$ORIGINAL_SIZE" \
      "size_after=$OUTPUT_SIZE" "decode=$LAST_DECODE_MODE" \
      "enc=$(( SECONDS - ENC_START ))" \
      "rel_b64=$(smt_b64 "$RELATIVE_PATH")" \
      "path_b64=$(smt_b64 "$FILE")" \
      "err_b64=$(smt_b64 "Could not replace original file")"
    rm -f "$TEMP"
  fi
  CURRENT_TEMP=""
  CURRENT_ERROR_LOG=""
  return 0
}

transcode_all() {
  local CURRENT=0
  local TRANSCODE_TOTAL=${#TRANSCODE_FILES[@]}

  print_section "Transcoding"

  emit queue_total "total=$TRANSCODE_TOTAL"

  if (( TRANSCODE_TOTAL == 0 )); then
    emit run_end "total=$TOTAL_FILES" "queued=0" "encoded=$ENCODED" \
      "skipped_hevc=$SKIPPED_HEVC" "skipped_larger=$SKIPPED_LARGER" \
      "skipped_other=$SKIPPED_OTHER" "failed=$FAILED"
    echo "Finished processing $TOTAL_FILES files."
    echo "  Queued for transcoding:   0"
    echo "  Encoded and replaced:     $ENCODED"
    echo "  Already HEVC:             $SKIPPED_HEVC"
    echo "  Output was not smaller:   $SKIPPED_LARGER"
    echo "  Other files skipped:      $SKIPPED_OTHER"
    echo "  Failed:                   $FAILED"
    return
  fi

  show_progress 0 "$TRANSCODE_TOTAL" "Transcoding"

  for (( CURRENT = 1; CURRENT <= TRANSCODE_TOTAL; CURRENT++ )); do
    transcode_one_file \
      "${TRANSCODE_FILES[$CURRENT]}" \
      "${TRANSCODE_LIBRARIES[$CURRENT]}" \
      "${TRANSCODE_CODECS[$CURRENT]}" \
      "${TRANSCODE_RESOLUTIONS[$CURRENT]}" \
      "${TRANSCODE_DURATIONS[$CURRENT]}" \
      "$CURRENT" "$TRANSCODE_TOTAL"
  done

  if (( INTERACTIVE )); then
    show_progress "$TRANSCODE_TOTAL" "$TRANSCODE_TOTAL" "Transcoding complete"
    finish_progress
  else
    echo
  fi

  emit run_end "total=$TOTAL_FILES" "queued=$TRANSCODE_TOTAL" \
    "encoded=$ENCODED" "skipped_hevc=$SKIPPED_HEVC" \
    "skipped_larger=$SKIPPED_LARGER" "skipped_other=$SKIPPED_OTHER" \
    "failed=$FAILED"

  echo "Finished processing $TOTAL_FILES files."
  echo "  Queued for transcoding:   $TRANSCODE_TOTAL"
  echo "  Encoded and replaced:     $ENCODED"
  echo "  Already HEVC:             $SKIPPED_HEVC"
  echo "  Output was not smaller:   $SKIPPED_LARGER"
  echo "  Other files skipped:      $SKIPPED_OTHER"
  echo "  Failed:                   $FAILED"
}

# Reset the run/scan counters and the queue accumulator arrays.
smt_init_counters() {
  TOTAL_FILES=0
  ENCODED=0
  SKIPPED_HEVC=0
  SKIPPED_LARGER=0
  SKIPPED_OTHER=0
  SKIPPED_WORKLOG=0
  FAILED=0
  TRANSCODE_FILES=()
  TRANSCODE_LIBRARIES=()
  TRANSCODE_CODECS=()
  TRANSCODE_RESOLUTIONS=()
  TRANSCODE_DURATIONS=()
}

# Legacy / standalone entry point: scan every library argument, then transcode
# the whole queue serially. Used for interactive and cron runs (no SMT_MODE).
run_library() {
  if (( $# == 0 )); then
    echo "Usage: $0 /path/to/library [/path/to/another-library ...]"
    exit 1
  fi

  local -a LIBRARY_INPUTS
  LIBRARY_INPUTS=("$@")

  local LIBRARY_INPUT=""
  for LIBRARY_INPUT in "${LIBRARY_INPUTS[@]}"; do
    if [[ ! -d "$LIBRARY_INPUT" ]]; then
      echo "ERROR: Library folder does not exist: $LIBRARY_INPUT"
      exit 1
    fi
  done

  smt_init_counters

  print_banner
  (( INTERACTIVE )) && printf '\033[s'

  for LIBRARY_INPUT in "${LIBRARY_INPUTS[@]}"; do
    scan_library "$LIBRARY_INPUT"
  done

  transcode_all
}

# Daemon scan mode: scan ONE library and emit a queue_item event per file that
# needs transcoding (worklog hits are pre-filtered inside scan_library). No
# encoding happens here — the daemon drives transcoding separately.
run_scan_mode() {
  local LIBRARY_INPUT="$1"
  if [[ -z "$LIBRARY_INPUT" || ! -d "$LIBRARY_INPUT" ]]; then
    echo "ERROR: Library folder does not exist: $LIBRARY_INPUT"
    exit 1
  fi

  smt_init_counters
  scan_library "$LIBRARY_INPUT"
}

# Daemon worker mode: transcode exactly ONE already-scanned file, described via
# environment variables set by the daemon.
run_file_mode() {
  local FILE="${SMT_FILE:-}"
  local LIBRARY="${SMT_LIBRARY:-}"

  if [[ -z "$FILE" || ! -f "$FILE" ]]; then
    echo "ERROR: SMT_FILE is missing or not a file: $FILE"
    exit 1
  fi

  # Strip a trailing slash so relative paths render cleanly.
  LIBRARY="${LIBRARY%/}"

  smt_init_counters

  transcode_one_file \
    "$FILE" \
    "$LIBRARY" \
    "${SMT_CODEC:-}" \
    "${SMT_RES:-}" \
    "${SMT_DURATION:-0}" \
    "${SMT_INDEX:-1}" \
    "${SMT_TOTAL:-1}"
}

main() {
  case "$SMT_MODE" in
    scan)
      run_scan_mode "$1"
      ;;
    file)
      run_file_mode
      ;;
    *)
      run_library "$@"
      ;;
  esac
}

# Only launch a run when executed directly. tryout.sh sets SMT_SOURCE_ONLY
# before sourcing this file so it can reuse the functions (media probing and the
# ffmpeg encode command) without starting a run.
if [[ -z "${SMT_SOURCE_ONLY:-}" ]]; then
  main "$@"
fi
