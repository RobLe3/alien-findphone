# alien-findphone

Find nearby devices using terminal signal intelligence with an alien-scan interface.

Built for the case where Find My is unavailable — for example when a device is
enrolled in MDM that disables it — but the device is still within Bluetooth
range and you just need to know which corner of the room it is in.

## Attribution

This is a forked and adapted build of [ben-z/findphone](https://github.com/ben-z/findphone), with substantial additions:

- Atomized m4a-based tracker audio (distance and source-aware sound shaping).
- Multi-source scanner surface (BLE advert/link, classic link, Wi‑Fi, and anchors).
- Expanded tracker display with source-spectrum and distance meter output.

## Install

Grab the universal binary from [Releases](https://github.com/RobLe3/alien-findphone/releases):

```sh
tar -xzf findphone-macos-universal.tar.gz
xattr -dr com.apple.quarantine findphone
./findphone --help
```

It is unsigned, so macOS quarantines it on download; the `xattr` line clears
that. Requires macOS 13 or later.

## Build

```sh
swift build -c release
cp .build/release/findphone ~/bin/findphone
```

Requires the Swift toolchain from Xcode Command Line Tools. No dependencies.
For a universal arm64 + x86_64 binary, which is what CI ships:

```sh
./scripts/build-universal.sh dist
```

## Use

```sh
findphone            # survey mode: nearby Wi‑Fi + BLE candidates
findphone iphone     # hunt mode: track one device by name (defaulting to on-screen alien GUI + audio)
findphone --list     # paired devices and their addresses
```

Hunt mode defaults to alien GUI and atomized audio feedback from the default
audio pack (`detector_asssets/audio.m4a`), split into 5 RSSI bands.
Survey mode also starts the tracker output so nearby stable assets get a continuous
distance-aware feed automatically.

(`--audio-pack` can always override this default.)
`--sound` remains a legacy alias in this fork and force-enables the same tracker.

Add `--redact` if you are recording the screen. It masks Bluetooth addresses.

Two things stay visible deliberately: the name you typed in hunt mode, and the
names in `--list`, because picking a target means reading them. `--list` is
not safe to film even with `--redact`.

Walk slowly and watch the bar. The reading is signal strength in dBm, which is
negative and closer to zero when nearer:

| dBm     | Rough meaning          |
|---------|------------------------|
| -45 up  | arm's reach            |
| -60     | same table             |
| -72     | same room              |
| -85     | far, or behind cover   |
| below   | very far, or shielded  |

Signal strength is a coarse proxy for distance. Metal, walls and human bodies
attenuate it heavily, so a device in a filing cabinet two metres away can read
the same as one fifteen metres away in open air. Trust the trend as you move,
not any single number.

## How it works

Four sources feed the scanner surface, in descending order of directness:

1. **GATT link** — once connected to the device over BLE, `readRSSI()` returns
   a fresh measurement about three times a second. This is the good one.
2. **BLE advertisements** — passively observed. Apple devices rotate their
   advertising addresses roughly every fifteen minutes and only include the
   device name on occasional packets, so this source is sparse.
3. **Wi‑Fi scans** — nearby access-point RSSI and SSID observations.
4. **Classic link RSSI** — read from `system_profiler SPBluetoothDataType`,
   keyed by the stable public address of a paired device.

Source 4 has a trap worth knowing about: macOS refreshes that value only every
three to twelve seconds and serves a cached number in between. Polling it
faster does not yield more information. Measured over 112 polls at 0.4s, every
poll returned a value but the same value repeated for runs of 8 to 31 polls.
The tool therefore counts a measurement only when the value actually changes,
which is why the reported measurement count is far lower than the poll rate —
and honest.

## Permissions

Needs Bluetooth access for whichever terminal runs it, under
System Settings > Privacy & Security > Bluetooth. It will say so if missing.

## Limitations

- Cannot make a device ring. There is no path to that without Find My.
- Cannot give a bearing. One radio yields distance only, not direction.
- Triangulation is coarse and only as good as configured anchors/cell geometry.
- Only finds devices with Bluetooth powered on and in range, roughly 10-20 m
  indoors and much less through walls.

## Scanner options

```sh
findphone --wifi        # force-enable Wi‑Fi (default: enabled)
findphone --no-wifi     # disable Wi‑Fi input
findphone --anchors     # path to JSON anchor file with optional coordinates
findphone --audio-pack  # path to custom m4a pack for hunt audio (defaults to detector_asssets/audio.m4a)
```
