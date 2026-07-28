#!/usr/bin/env bash
# Record the Turkish reference samples used by bakeoff.py.
#
# Each sample is captured as 16 kHz mono PCM16 WAV, which is what every ASR API
# downsamples to anyway, so this keeps uploads small without losing accuracy.
#
# Usage:
#   ./record.sh              list audio input devices, then exit
#   ./record.sh 0            record every sample using audio device index 0
#   ./record.sh 0 03         re-record only the sample whose name starts with 03

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF_DIR="$HERE/references"
OUT_DIR="$HERE/samples"

if [ $# -eq 0 ]; then
  echo "Audio input devices:"
  echo
  ffmpeg -f avfoundation -list_devices true -i "" 2>&1 |
    sed -n '/audio devices/,$p' |
    grep -E '^\[' || true
  echo
  echo "Re-run with the index of the mic you want, e.g.  ./record.sh 0"
  exit 0
fi

DEVICE="$1"
ONLY="${2:-}"

mkdir -p "$OUT_DIR"

for ref in "$REF_DIR"/*.txt; do
  name="$(basename "$ref" .txt)"
  if [ -n "$ONLY" ] && [[ "$name" != "$ONLY"* ]]; then
    continue
  fi

  out="$OUT_DIR/$name.wav"

  echo
  echo "=============================================================="
  echo "  $name"
  echo "=============================================================="
  echo
  cat "$ref"
  echo
  echo "--------------------------------------------------------------"
  case "$name" in
    *disfluent*) echo "  Read this at natural speed. Do not clean up the fillers." ;;
    *numbers*)   echo "  Say the numbers exactly as written, in words." ;;
    *long*)      echo "  One breath, no pauses between clauses." ;;
    *)           echo "  Read at your normal dictation speed." ;;
  esac
  echo "  Press Enter to start recording, then press q to stop."
  echo "--------------------------------------------------------------"
  read -r

  ffmpeg -hide_banner -loglevel warning \
    -f avfoundation -i ":$DEVICE" \
    -ar 16000 -ac 1 -c:a pcm_s16le \
    -y "$out"

  echo "Saved $out ($(afinfo "$out" 2>/dev/null | awk '/estimated duration/ {print $3" s"}'))"
done

echo
echo "Done. Samples in $OUT_DIR"
echo "Next: export OPENROUTER_API_KEY=... && python3 $HERE/bakeoff.py"
