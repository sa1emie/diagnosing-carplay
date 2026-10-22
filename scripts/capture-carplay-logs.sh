#!/usr/bin/env bash
# Capture live iPhone syslog for CarPlay debugging.
#
# Requires: libimobiledevice (brew install libimobiledevice)
#
# Writes two files into OUTDIR:
#   raw-<ts>.log       everything (large: ~4 MB/s)
#   filtered-<ts>.log  CarPlay-relevant processes only
#
# Usage: ./capture-carplay-logs.sh [outdir] [seconds]

set -euo pipefail

OUTDIR="${1:-$HOME/Desktop/carplay-debug}"
SECS="${2:-180}"
TS="$(date +%H%M%S)"

mkdir -p "$OUTDIR"

if ! command -v idevicesyslog >/dev/null 2>&1; then
  echo "idevicesyslog not found. Install with: brew install libimobiledevice" >&2
  exit 1
fi

echo "==> Confirming the device is paired and visible"
xcrun devicectl list devices 2>/dev/null | grep -iE "paired|available" || true

echo "==> Starting captures (${SECS}s) into $OUTDIR"

idevicesyslog --no-colors -o "$OUTDIR/raw-$TS.log" &
RAW_PID=$!

idevicesyslog --no-colors \
  -p "carkitd|iap2d|accessoryd|bluetoothd|wifid|airplayd|CarPlay|sharingd|fairplaydeviceidentityd|WirelessRadioManagerd|SpringBoard" \
  -o "$OUTDIR/filtered-$TS.log" &
FILT_PID=$!

echo "$RAW_PID"  > "$OUTDIR/capture-raw.pid"
echo "$FILT_PID" > "$OUTDIR/capture-filtered.pid"

echo "    raw PID=$RAW_PID  filtered PID=$FILT_PID"
echo "    reproduce the failure now."

sleep "$SECS"

kill "$RAW_PID" "$FILT_PID" 2>/dev/null || true
wait "$RAW_PID" "$FILT_PID" 2>/dev/null || true

echo "==> Done"
ls -lh "$OUTDIR/raw-$TS.log" "$OUTDIR/filtered-$TS.log"
echo "TS=$TS" > "$OUTDIR/latest-ts.txt"
