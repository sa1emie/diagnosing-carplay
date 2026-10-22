#!/usr/bin/env bash
# Walk a CarPlay capture from the bottom of the stack upwards.
#
# The first layer that looks wrong is where the trouble is, so read in order and
# stop when something stops adding up. This prints the evidence and leaves the
# conclusion to you.
#
# Usage: ./analyse-carplay-logs.sh <filtered.log>

set -euo pipefail
F="${1:?usage: analyse-carplay-logs.sh <filtered.log>}"

hdr() { printf '\n=== %s ===\n' "$1"; }

hdr "Layers 2-3: is the accessory talking, and is it genuine"
echo "iAP2 traffic (any hits means the session is alive):"
grep -c "iAP2 packet complete" "$F" 2>/dev/null || echo "0  <- no iAP2 at all, so drop back to layer 1: cable, port, trust"
echo "certificate verdict (you want certStatus: [Valid]):"
grep -E "certIssuer|certSubject|certStatus|authVersion" "$F" \
  | sed -E 's/^[A-Za-z]+ +[0-9]+ [0-9:.]+ //' || echo "no MFi lines in here"

hdr "Layer 4: did the session activate (transitions only)"
grep -E "session isAuthenticated" "$F" \
  | awk '{v=$(NF-1)" "$NF; if (v!=prev) {print $3, v; prev=v}}' || echo "no session lines in here"
echo "cross-check against the carplayConnected policy:"
grep -oE "carplayConnected = [0-9]" "$F" | sort | uniq -c || true

hdr "Layer 5: is the control channel up"
echo "RTSP methods (video needs SETUP or RECORD, control is just POST /command):"
grep -oE "HTTP Request: +[A-Z]+ [^ ]+" "$F" | sort | uniq -c || true
echo "response codes (200 OK means the channel is healthy):"
grep -oE "HTTP Response: RTSP/[0-9.]+ [0-9]+ [A-Za-z]+" "$F" | sort | uniq -c || true

hdr "Layer 6: did a media stream start (zero encoder hits means nothing is being produced)"
grep -icE "encoder|VTCompression|FigVideo|VideoToolbox" "$F" || true
echo "byte rates (control sits near 1KB/s, video would be megabits):"
grep -E "Data Usage for airplayd" "$F" \
  | grep -oE "WiFi delta_in/delta_out: [0-9]+/[0-9]+" | sort -u | head -5 || true

hdr "Layer 7: is the phone drawing CarPlay UI"
grep -E "CarPlay\(DashBoard\)|CarPlay\(SystemStatusUI\)" "$F" | cut -c1-140 | head -5 || true

hdr "Soft errors, which usually mean a damaged state cache"
grep -E "<Error>|<Fault>" "$F" | grep -iE "carkitd|airplayd|accessoryd" | cut -c1-180 | head -10 || true

hdr "Drops at the transport level"
grep -E "ACL disconnected" "$F" | cut -c1-160 | head -5 || true
