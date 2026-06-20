#!/bin/zsh
set -u

# tryout.sh — non-destructive single-file transcode trial.
#
# Encodes ONE file to a sidecar HEVC output without ever touching the original,
# then reports the input size, output size, and space saved. Optionally sweeps
# several QUALITY values so you can pick one before running transcode.sh on a
# whole library.
#
# All probing and encoding logic is reused from transcode.sh (sourced below),
# so any change to the ffmpeg command there automatically applies here too.
#
# Usage:
#   ./tryout.sh /path/to/file.mkv
#   QUALITY=65 ./tryout.sh /path/to/file.mkv
#   QUALITIES="55 65 70 80" ./tryout.sh /path/to/file.mkv
#
# Env:
#   QUALITY     single VideoToolbox quality (default 70, same as transcode.sh)
#   QUALITIES   space-separated list to sweep; overrides QUALITY when set
#   KEEP        1 (default) keeps the encoded sidecar files so you can compare
#               them visually; set KEEP=0 to delete each one after measuring.

SCRIPT_DIR="${0:A:h}"

if [[ ! -r "${SCRIPT_DIR}/transcode.sh" ]]; then
  echo "ERROR: Cannot find transcode.sh next to tryout.sh."
  exit 1
fi

# Reuse all helpers + the ffmpeg encode command from the main script. Sourcing
# only defines functions and runs the environment checks (ffmpeg/videotoolbox);
# the library transcoder itself is guarded and will not run.
SMT_SOURCE_ONLY=1
source "${SCRIPT_DIR}/transcode.sh"

KEEP="${KEEP:-1}"

if (( $# != 1 )); then
  echo "Usage: $0 /path/to/file.{mkv,mp4,m4v,mov}"
  echo "       QUALITY=65 $0 file.mkv"
  echo "       QUALITIES=\"55 65 70 80\" $0 file.mkv"
  exit 1
fi

INPUT="$1"

if [[ ! -f "$INPUT" ]]; then
  echo "ERROR: File does not exist: $INPUT"
  exit 1
fi

EXT="$(printf '%s' "${INPUT##*.}" | tr '[:upper:]' '[:lower:]')"

MUXER=""
EXTRA_ARGS=()
if ! select_muxer "$EXT"; then
  echo "ERROR: Unsupported container: .$EXT (supported: mkv, mp4, m4v, mov)"
  exit 1
fi

# Build the list of qualities to try.
if [[ -n "${QUALITIES:-}" ]]; then
  QUALITY_LIST=(${=QUALITIES})
else
  QUALITY_LIST=("$QUALITY")
fi

for Q in "${QUALITY_LIST[@]}"; do
  case "$Q" in
    ''|*[!0-9]*)
      echo "ERROR: QUALITY values must be integers 1-100 (got '$Q')."
      exit 1
      ;;
  esac
  if (( Q < 1 || Q > 100 )); then
    echo "ERROR: QUALITY values must be between 1 and 100 (got '$Q')."
    exit 1
  fi
done

# Render a byte count as a human-readable size.
format_size() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KB MB GB TB PB", u, " ")
    i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i]
    else printf "%.2f %s", b, u[i]
  }'
}

BASENAME="${INPUT:t}"
INPUT_CODEC="$(video_codec "$INPUT")"
INPUT_RESOLUTION="$(video_resolution "$INPUT")"
DURATION="$(video_duration "$INPUT")"
[[ -z "$DURATION" ]] && DURATION=0
INPUT_SIZE="$(stat -f '%z' "$INPUT")"

echo
printf 'File:    %s\n' "$BASENAME"
printf 'Input:   %s  (%s, %s, %s)\n' \
  "$(format_size "$INPUT_SIZE")" \
  "${INPUT_CODEC:-?}" "${INPUT_RESOLUTION:-?}" \
  "$(format_duration "$DURATION")"
if [[ "$INPUT_CODEC" == "hevc" ]]; then
  printf 'Note:    input is already HEVC; re-encoding anyway for the tryout.\n'
fi
echo

SUMMARY=()
EXIT_STATUS=0

for Q in "${QUALITY_LIST[@]}"; do
  OUTPUT="${INPUT:r}.tryout-q${Q}.${EXT}"
  ERROR_LOG="${OUTPUT}.error.log"
  rm -f "$OUTPUT" "$ERROR_LOG"

  QUALITY="$Q"   # encode_file reads this global

  print_section "Tryout QUALITY=$Q"

  if ! encode_with_fallback \
    "$INPUT" "$OUTPUT" "$MUXER" \
    0 1 \
    "Encoding at QUALITY=$Q: $BASENAME" \
    "$DURATION" "$ERROR_LOG" \
    "Retrying with software decode at QUALITY=$Q: $BASENAME" \
    "${EXTRA_ARGS[@]}"
  then
    finish_progress
    printf 'QUALITY=%-3s  FAILED (see %s)\n\n' "$Q" "$ERROR_LOG"
    SUMMARY+=("$Q|FAILED|||")
    EXIT_STATUS=1
    rm -f "$OUTPUT"
    continue
  fi

  finish_progress
  rm -f "$ERROR_LOG"

  OUT_CODEC="$(video_codec "$OUTPUT")"
  OUT_RES="$(video_resolution "$OUTPUT")"
  OUT_SIZE="$(stat -f '%z' "$OUTPUT")"

  SAVED_PCT="$(awk -v i="$INPUT_SIZE" -v o="$OUT_SIZE" \
    'BEGIN { if (i > 0) printf "%.1f", (i - o) * 100 / i; else printf "0.0" }')"

  printf 'QUALITY=%-3s  %s -> %s  (saved %s%%)  %s %s\n' \
    "$Q" \
    "$(format_size "$INPUT_SIZE")" "$(format_size "$OUT_SIZE")" \
    "$SAVED_PCT" "${OUT_CODEC:-?}" "${OUT_RES:-?}"

  if [[ "$OUT_CODEC" != "hevc" ]]; then
    printf '            WARNING: output codec is %s, not hevc\n' "${OUT_CODEC:-unknown}"
    EXIT_STATUS=1
  fi
  if [[ -n "$INPUT_RESOLUTION" && "$OUT_RES" != "$INPUT_RESOLUTION" ]]; then
    printf '            WARNING: resolution changed %s -> %s\n' \
      "$INPUT_RESOLUTION" "$OUT_RES"
    EXIT_STATUS=1
  fi
  if (( OUT_SIZE >= INPUT_SIZE )); then
    printf '            NOTE: output is NOT smaller; transcode.sh would keep the original\n'
  fi

  if (( KEEP )); then
    printf '            kept: %s\n' "$OUTPUT"
  else
    rm -f "$OUTPUT"
  fi
  echo

  SUMMARY+=("$Q|$(format_size "$OUT_SIZE")|${SAVED_PCT}%|${OUT_CODEC}|${OUT_RES}")
done

if (( ${#QUALITY_LIST[@]} > 1 )); then
  print_section "Sweep summary"
  printf '  %-8s %-13s %-9s %-6s %s\n' "QUALITY" "OUTPUT" "SAVED" "CODEC" "RES"
  for ROW in "${SUMMARY[@]}"; do
    IFS='|' read -r RQ ROUT RSAVED RCODEC RRES <<< "$ROW"
    printf '  %-8s %-13s %-9s %-6s %s\n' \
      "$RQ" "${ROUT:--}" "${RSAVED:--}" "${RCODEC:--}" "${RRES:--}"
  done
  echo
  printf 'Input was %s (%s, %s).\n' \
    "$(format_size "$INPUT_SIZE")" "${INPUT_CODEC:-?}" "${INPUT_RESOLUTION:-?}"
fi

exit "$EXIT_STATUS"
