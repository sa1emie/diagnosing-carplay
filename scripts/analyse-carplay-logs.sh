#!/usr/bin/env bash
# Pull the CarPlay-relevant signal out of an idevicesyslog capture.
#
# Usage: ./analyse-carplay-logs.sh <filtered.log>

set -euo pipefail
F="${1:?usage: analyse-carplay-logs.sh <filtered.log>}"

echo "=== CarPlay session state transitions ==="
grep -E "session isAuthenticated" "$F" \
  | awk '{v=$(NF-1)" "$NF; if (v!=prev) {print $3, v; prev=v}}' || true

echo
echo "=== RTSP methods used (SETUP/RECORD == video, POST /command == control) ==="
grep -oE "HTTP Request: +[A-Z]+ [^ ]+" "$F" | sort | uniq -c || true

echo
echo "=== RTSP response codes ==="
grep -oE "HTTP Response: RTSP/[0-9.]+ [0-9]+ [A-Za-z]+" "$F" | sort | uniq -c || true

echo
echo "=== MFi certificate verdict ==="
grep -E "certIssuer|certStatus|authVersion" "$F" | sed -E 's/^[A-Za-z]+ +[0-9]+ [0-9:.]+ //' || true

echo
echo "=== Encoder / video activity (expect 0 if the display stream never started) ==="
grep -icE "encoder|VTCompression|FigVideo|VideoToolbox" "$F" || true

echo
echo "=== carkitd errors ==="
grep -E "carkitd" "$F" | grep -E "<Error>|<Fault>" | cut -c1-200 || true

echo
echo "=== carplayConnected policy state ==="
grep -oE "carplayConnected = [0-9]" "$F" | sort | uniq -c || true

echo
echo "=== Bluetooth ACL disconnects ==="
grep -E "bluetoothd" "$F" | grep -i "ACL disconnected" | cut -c1-200 || true
