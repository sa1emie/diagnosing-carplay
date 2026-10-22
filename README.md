# Diagnosing CarPlay failures from the iPhone's own logs

A field guide drawn from a single real diagnosis.

CarPlay faults are almost always reported at the head unit: *"it doesn't work"*,
*"the screen is blank"*. It is also the worst vantage point, since of everything involved the
head unit gives up the least information. The phone, meanwhile, logs everything:
the UI, the video pipeline, the AirPlay control channel, MFi authentication, and
the accessory session underneath it all. A plain Lightning cable gets you the
lot.

So the black box opens up, provided you read it in layers.

---

## 1. The premise: CarPlay fails in layers

CarPlay is several subsystems stacked, and each one fails differently in the log.
The method follows from that. Find the highest layer that looks healthy, then
examine the one immediately above it.

| # | Layer | What it means | Fails as |
|---|-------|---------------|----------|
| 1 | Transport | USB cable (wired) or Bluetooth handshake + Wi-Fi link (wireless) | Nothing connects at all |
| 2 | iAP2 accessory session | The phone and accessory agree to talk | Accessory never enumerates |
| 3 | MFi authentication | Is this a genuine licensed accessory? | "Accessory not supported", refusal |
| 4 | CarPlay session activation | The CarPlay session is authorised and live | Connects then immediately drops |
| 5 | AirPlay control channel | The RTSP command channel between phone and unit | Connected, but nothing happens |
| 6 | Media streams | Video and audio actually start (`SETUP`/`RECORD`) | **Blank screen**, no audio |
| 7 | UI presentation | The CarPlay shell composes a screen | UI renders on phone, not in car |

Layer 6 is where most blank-screen reports actually sit. Layers 1–5 are
genuinely up, so everything looks connected. That also explains why the
intuitive fixes often go nowhere: re-pairing, rebooting and swapping the cable
all operate above a fault the user has no view of.

---

## 2. Tooling

You won't need much.

```bash
# Xcode command line tools provide devicectl
xcode-select --install

# The one third-party piece: streams the phone's syslog
brew install libimobiledevice
```

Three things waste time if you learn them late. Nothing Apple ships streams live
logs off an iPhone: `log stream` sees only the Mac, and there is no console
subcommand under `xcrun devicectl`. `idevicesyslog` is what actually does the
job. Meanwhile `log collect --device` refuses outright with *"Must be root to
collect logs from attached device"*, and `xcrun devicectl device sysdiagnose`
runs fine without sudo, which makes it the fallback to remember when a live
capture isn't practical.

Confirm the phone is paired before suspecting anything else:

```bash
xcrun devicectl list devices
# look for:  transport: wired   pairingState: paired
```

`ideviceinfo -k ProductVersion` answers quickly whether libimobiledevice can
reach the device at all.

---

## 3. Method

The volume is the first surprise. Roughly 29,000 lines/second, ~4 MB/s. Reading
that raw isn't realistic, and filtering it live by eye is worse.

Run two at once. Concurrent instances are fine:

```bash
# full raw, for completeness
idevicesyslog --no-colors -o raw.log &

# process-filtered, for reading
idevicesyslog --no-colors \
  -p "carkitd|iap2d|accessoryd|bluetoothd|wifid|airplayd|CarPlay|sharingd|SpringBoard" \
  -o filtered.log &
```

Reproduce the failure while both are running, then stop. A 3–5 minute window is
plenty, and the raw file will land in the hundreds of MB.

Two things got in the way in practice. Unplugging the phone to go and test the
car kills your capture, so diagnosing *wired* CarPlay means the phone is in the
car and not on the Mac; reproduce there, then pull the archive with
`devicectl device sysdiagnose`. Separately, keep the phone off a computer while
testing wireless. iOS reads the far end of a USB data connection as an
accessory, and that is a confound you can simply avoid.

Both halves of this live in `scripts/`.

---

## 4. Reading the evidence, layer by layer

Work bottom-up. The first layer that looks wrong is where you stop.

### Layers 2–3: is the accessory talking, and is it genuine?

```
accessoryd: Received N bytes of incoming data for endpoint ... (type:[AirPlay])
accessoryd: iAP2 packet complete!
```

Traffic here means the session is alive. Then the certificate:

```
airplayd(MFAAuthentication): certIssuer: Apple Accessories Certification Authority
airplayd(MFAAuthentication): authVersion: [V3]
airplayd(MFAAuthentication): Returning certStatus: [Valid]
```

An Apple Accessories CA `certStatus: [Valid]` settles more in one line than
anything else you'll look at early. An entire class of causes dies right there:
counterfeit hardware, unlicensed hardware, and the lockout behaviour that
follows from either. Should it say anything other than Valid, stop, because the
problem is the accessory's credentials and not the phone.

### Layer 4: did the CarPlay session actually activate?

```
carkitd(CarKit): session isAuthenticated:0, isActivated:0
carkitd(CarKit): session isAuthenticated:1, isActivated:1
```

Authenticated *and* activated is what you're after. Two details matter.
The transition ought to be one-way, and repeated `1 → 0` flapping is a different
failure altogether (session instability) that reads distinctly from a clean
drop. Second, `locationd` reports `carplayConnected = 1` on its own, so two
subsystems agreeing carries more weight than either line in isolation.

### Layer 5: is the control channel up?

```
airplayd: HTTP Request:  POST /command RTSP/1.0
airplayd: HTTP Response: RTSP/1.0 200 OK
```

Steady 1 Hz `POST /command` → `200 OK` means the phone and the unit are
conversing. Nothing in that says whether anything is being drawn.

### Layer 6: did a media stream start?

Blank screens live at this layer. Count the RTSP methods:

```bash
grep -oE "HTTP Request: +[A-Z]+ [^ ]+" filtered.log | sort | uniq -c
```

`POST /command` on its own means control plane with no media, so no `SETUP` and
no `RECORD`. Seeing `SETUP` or `RECORD` means streams were negotiated.

The encoder side is independent confirmation:

```bash
grep -icE "encoder|VTCompression|FigVideo|VideoToolbox" filtered.log
```

Zero hits means the phone isn't encoding a single video frame. Then check the
transport: once video runs, the flow accounting for `airplayd` sits in megabits,
where control alone shows roughly 1 KB/s:

```
symptomsd: Data Usage for airplayd on flow N - WiFi delta_in/delta_out: 599/133
```

That byte-rate delta settles the question. Control traffic at ~1 KB/s, 200 OKs
arriving on schedule, an encoder doing nothing: in no useful sense is that
"connected". Half a session, and the missing half is the picture.

### Layer 7: is the phone drawing UI?

```
CarPlay(DashBoard): Setting status bar battery data enabled, state: 1, capacity: 82
CarPlay(DashBoard): Status Bar overrides exist and will be applied to CarPlay.
```

`com.apple.CarPlayApp` alive and rendering its status bar means the phone
believes there is a live CarPlay display to draw into. Set that beside an idle
encoder and the fault states itself: the phone is painting a screen that never
gets transmitted.

---

## 5. Triaging a symptom

| What you see | Highest healthy layer | Likely class |
|---|---|---|
| Device not paired / no iAP2 traffic | 0–1 | Cable, port, or trust state |
| iAP2 up, MFi cert **invalid** | 2 | Counterfeit / unlicensed accessory |
| Auth valid, session never activates | 3–4 | Restrictions, pairing records, unit refusing |
| Session activates then drops within seconds | 4 | Unstable link, bad state, power |
| `carplayConnected=1`, `POST /command` 200 OK, **no `SETUP`, encoder idle** | 5 | **Display handoff / video plane never starts — blank screen** |
| Video streams present, screen still wrong | 6–7 | Decode or presentation on the unit |

Layers 1–4 failing tends to surface as *"it won't connect"*. Layer 6
failing produces *"it's connected but blank"*, a complaint that sounds like a
display fault while actually being a session and handoff fault.

---

## 6. Worked example

The case behind this guide came from a 2024 GM truck running wireless CarPlay
natively, with an iPhone 13 Pro Max on iOS 27.0.1.

**Reported:** CarPlay connected, the screen went blank, then it dropped about a
second later. Apps on the phone kept telling the user to "open CarPlay on the
infotainment system", which was the giveaway. As far as the phone was concerned,
it already was open.

**Already tried:** forget and re-pair, the Siri toggle, an infotainment reboot,
several cables, an iOS update. All of them are layer-1-through-4 fixes.

**What the logs said:**

```
MFAAuthentication: Returning certStatus: [Valid]
carkitd: session isAuthenticated:1, isActivated:1
carkitd: Connection success -- cleaning failure
locationd: carplayConnected = 1
airplayd: POST /command → 200 OK   (×88, the only RTSP method in 134 MB)
encoder/VTCompression/VideoToolbox hits: 0
```

Everything through layer 5 was healthy, and layer 6 was simply absent. Two soft
errors also pointed at a damaged state cache:

```
carkitd <Error>: Failed to parse CarPlay MobileAssets file
carkitd <Error>: Parsing LiveActivityDenyListContent failed
```

So the answer wasn't hardware, authentication or a cable. A stale CarPlay
pairing state was being rebuilt from bad records: far enough up to authenticate
and open a control channel, never far enough to negotiate video.

Forgetting the car on both sides and re-pairing **over a cable** fixed it.
Pairing over the wire rebuilds the state the wireless handoff later draws on.

Which is why each earlier attempt missed. Re-pairing through the UI reused the
same damaged records, and the new cable changed layer 1, where nothing had been
broken.

---

## 7. Fixes, cheapest first

Start with what costs nothing and undoes nothing.

**Layer 1, transport.** A genuine Apple cable, since third-party Lightning
cables fail CarPlay specifically. A different USB port, and no hub. On the
wireless side, confirm the vehicle's Wi-Fi is enabled and joinable and disable
any VPN, since they break the local handoff. Switch `Private Wi-Fi Address` off
for that network too.

**Layer 4, pairing state.** Easily the most underrated. Both records have to go:
the one under `Settings → General → CarPlay` and the one under
`Settings → Bluetooth`. Clear just one and half the pairing survives. Then
re-pair **wired first** with a genuine cable, because wireless is seeded from it.
`Reset Network Settings` wipes Wi-Fi, Bluetooth and VPN state wholesale and is
the blunt instrument for handoff corruption, at the cost of your saved Wi-Fi
passwords.

**Layer 6, display handoff.** Usually there is nothing to do on the phone.
Check that the unit's firmware is current, because wireless CarPlay fixes arrive
as infotainment updates more often than seems reasonable.

**Layer 7, unit-side.** A factory reset of the infotainment is the least
reversible step available, so it goes last.

---

## 8. What this method can't tell you

A capture can't prove everything.

- **`SETUP` happens at session establishment**, usually before you start
  recording. A mid-session capture therefore cannot prove `SETUP` never ran. What
  it can show is the present tense: nothing being encoded, no video on the wire.
  That is enough to characterise the fault, provided you state it that way. The
  byte-rates and the idle encoder carry the argument; a missing log line does
  not.
- **iOS redacts hard.** Most accessory-identifying fields arrive as `<private>`
  unless a logging profile is present. Full detail means installing Apple's
  profile on the phone first.
- **Captures are personal data.** A raw file carries device UDIDs, accessory MAC
  addresses, location data, MFi certificate serials, the phone's name, and the
  names of every app that was open. Publishing one is not acceptable,
  whatever its diagnostic value. Sanitized excerpts plus the method is the thing
  to share.
- **Correlation isn't proof.** `carplayConnected = 1` beside a healthy RTSP
  channel really does look like "connected"; the encoder count and the byte-rate
  were what showed it wasn't. Find two independent signals before concluding.
- **The case here turned up one more wrinkle.** The fault presented as layer 6
  and was fixed at layer 4. A blank screen is a symptom of the handoff failing,
  and the handoff can fail at any layer beneath the display.

---

## Repo contents

- `scripts/capture-carplay-logs.sh` — runs both captures for a fixed duration
- `scripts/analyse-carplay-logs.sh` — walks a capture layer by layer
- `.gitignore` — keeps raw captures out of git
