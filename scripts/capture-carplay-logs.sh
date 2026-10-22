#!/usr/bin/env bash
# Grab live syslog off an iPhone while you're sat at the car, for CarPlay work.
#
# Needs libimobiledevice:  brew install libimobiledevice
#
# Two files land in OUTDIR:
#   raw-<ts>.log       everything, unfiltered. About 4 MB/s, so keep the run short.
#   filtered-<ts>.log  only the processes that matter for CarPlay.
#
# Usage: ./capture-carplay-logs.sh [outdir] [seconds]

set -euo pipefail

OUTDIR="${1:-$HOME/Desktop/carplay-debug}"
SECS="${2:-180}"
TS="$(date +%H%M%S)"

mkdir -p "$OUTDIR"

if ! command -v idevicesyslog >/dev/null 2>&1; then
  echo "idevicesyslog isn't installed. Get it with: brew install libimobiledevice" >&2
  exit 1
fi

echo "Checking the phone shows up as paired"
xcrun devicectl list devices 2>/dev/null | grep -iE "paired|available" || true

echo "Recording for ${SECS}s into $OUTDIR"

idevicesyslog --no-colors -o "$OUTDIR/raw-$TS.log" &
RAW_PID=$!

idevicesyslog --no-colors \
  -p "carkitd|iap2d|accessoryd|bluetoothd|wifid|airplayd|CarPlay|sharingd|fairplaydeviceidentityd|WirelessRadioManagerd|SpringBoard" \
  -o "$OUTDIR/filtered-$TS.log" &
FILT_PID=$!

echo "$RAW_PID"  > "$OUTDIR/capture-raw.pid"
echo "$FILT_PID" > "$OUTDIR/capture-filtered.pid"

echo "  raw pid $RAW_PID, filtered pid $FILT_PID"
echo "  Go reproduce it now."

sleep "$SECS"

kill "$RAW_PID" "$FILT_PID" 2>/dev/null || true
wait "$RAW_PID" "$FILT_PID" 2>/dev/null || true

echo "Stopped."
ls -lh "$OUTDIR/raw-$TS.log" "$OUTDIR/filtered-$TS.log"
echo "TS=$TS" > "$OUTDIR/latest-ts.txt"
