# CarPlay: connected, authenticated, blank screen

Diagnosing an Apple CarPlay failure on a 2024 GMC Denali from the iPhone's own
syslog, using nothing but a Mac and an iPhone on a Lightning cable.

## TL;DR

The iPhone's CarPlay **control plane** was fully up. The accessory paired, passed
MFi authentication with a genuine Apple certificate, and the session reported
`isAuthenticated:1, isActivated:1`. The head unit even received live GPS over
iAP2.

What never happened was the **video stream**. The only RTSP method the phone ever
used was `POST /command` — never `SETUP`, never `RECORD` — and there were **zero**
video-encoder hits across ~134 MB of captured log. With no display stream
negotiated, the head unit had nothing to render: **blank screen**. Meanwhile the
phone believed CarPlay was connected, which is why CarPlay-aware apps (Google
Maps) insisted "open CarPlay on your infotainment system".

**Root cause:** corrupt CarPlay pairing state on the iPhone.
**Fix:** forget the car on both sides, re-pair over a genuine Apple cable.

## Symptom

- 2024 GMC Denali, native wireless CarPlay
- iPhone 13 Pro Max, iOS 27.0.1
- CarPlay would connect, then drop within a second or two
- Pressing CarPlay on the head unit produced a **blank screen**
- Google Maps offered CarPlay, then errored: *"open Google Maps in CarPlay to continue"*

Already tried before this investigation: forget/re-pair, Siri toggle,
infotainment reboot, multiple cables, iOS update.

## Method

Nothing Apple ships streams live iPhone logs. `log stream` only reads the Mac, and
`xcrun devicectl` has no console subcommand. The tool that does it is
`idevicesyslog` from `libimobiledevice`.

```bash
brew install libimobiledevice          # provides idevicesyslog
xcrun devicectl list devices           # confirm the phone shows as paired
```

Two useful facts about the native tools:

- `log collect --device` **requires root** ("Must be root to collect logs from attached device")
- `xcrun devicectl device sysdiagnose` works **without sudo** — the right fallback

Capture is a firehose: roughly **29,000 lines/second / ~4 MB/s**. So: one raw
capture to a file, plus a second, process-filtered capture for readability. Two
concurrent `idevicesyslog` instances work fine.

```bash
idevicesyslog --no-colors -o raw.log &
idevicesyslog --no-colors \
  -p "carkitd|iap2d|accessoryd|bluetoothd|wifid|airplayd|CarPlay|sharingd|SpringBoard" \
  -o filtered.log &
```

## What the logs showed

### The control plane was healthy

```
carkitd(CarKit): session isAuthenticated:0, isActivated:0      # before
carkitd(CarKit): session isAuthenticated:1, isActivated:1      # 23:14:16.745, stays 1
carkitd: Connection success -- cleaning failure
locationd: carplayConnected = 1
locationd: AccessoryGPS,onAccessoryNotification ... isCarPlayLocationFix,1
```

`com.apple.CarPlayApp` (the on-phone CarPlay shell) was alive and actively
composing a status bar:

```
CarPlay(DashBoard): Setting status bar battery data enabled, state: 1, capacity: 82
CarPlay(DashBoard): Status Bar overrides exist and will be applied to CarPlay.
```

`accessoryd` was parsing iAP2 packets carrying NMEA sentences (`$GPGGA`, `$GPRMC`)
on an endpoint of type `[AirPlay]` — i.e. the head unit was feeding the phone GPS.

### The MFi certificate was genuine

```
airplayd(MFAAuthentication): certIssuer: Apple Accessories Certification Authority - 00000002
airplayd(MFAAuthentication): certSubject: C=US,O=Apple Inc.,OU=Apple Accessories,CN=IPA_<redacted>
airplayd(MFAAuthentication): authVersion: [V3]
airplayd(MFAAuthentication): Returning certStatus: [Valid]
```

So this was **not** a counterfeit-accessory lockout, and not an authentication
failure. That ruled out a whole class of causes.

### The video plane never started

```
HTTP Request:  POST /command      # ×88 — the ONLY RTSP method in the capture
HTTP Response: RTSP/1.0 200 OK    # ×88 — every one succeeded
```

- No `SETUP`, no `RECORD`, no `TEARDOWN`
- `grep -icE 'encoder|VTCompression|FigVideo|VideoToolbox'` → **0**
- `videocodecd` logged nothing but RunningBoard state updates
- `airplayd`'s flows carried ~1 KB/s (control only; video would be megabits)

### Two minor errors worth noting

```
carkitd <Error>: Failed to parse CarPlay MobileAssets file
carkitd <Error>: Parsing LiveActivityDenyListContent failed with error: <private>
```

Neither is fatal on its own, but together with the above they're consistent with a
damaged CarPlay state cache rather than a hardware fault.

## Why "authenticated but blank" happens

Wireless CarPlay is a sequence: Bluetooth handshake → Wi-Fi credential exchange →
phone joins the car's AP → AirPlay session → **video stream setup**. Here the
phone completed everything up to the AirPlay session and then never got a video
`SETUP`. The session was half-built and stuck, so the head unit displayed nothing
and the phone kept reporting "connected".

## Fix

Forget the car on **both** sides, then re-pair over a cable:

1. iPhone: `Settings → General → CarPlay → [car] → Forget This Car`
2. iPhone: `Settings → Bluetooth → [car] → Forget Device`
3. Head unit: delete the phone from its CarPlay device list
4. Re-pair **wired**, with a genuine Apple cable — wired pairing seeds the wireless handoff

Also worth doing while you're there: `Reset Network Settings`
(`Settings → General → Transfer or Reset iPhone → Reset → Reset Network Settings`).
That clears Wi-Fi/Bluetooth/VPN state, which is the usual culprit when CarPlay
authenticates but the display handoff dies.

## Caveats

- The `SETUP` for the video stream would have occurred at session *establishment*,
  before this capture window. What the capture proves is that **no video was
  flowing and no encoder was active** for its entire duration — not that `SETUP`
  never ran. The flow counters and the idle encoder are the load-bearing evidence.
- iOS redacts most accessory-identifying fields (`<private>`) without a special
  logging profile installed. Getting unredacted CarPlay detail requires Apple's
  CarPlay/sysdiagnose logging profile.
- Logs in this repo are **sanitized excerpts**. Raw captures are deliberately not
  included — see `.gitignore`.
