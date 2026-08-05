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

## Original vs forked feature comparison

| Feature | Original `ben-z/findphone` | `alien-findphone` fork |
| --- | --- | --- |
| Scanner sources | BLE adverts + direct BLE link (`readRSSI`) + classic polling | BLE adverts + BLE link + classic poll + optional Wi‑Fi + optional anchors |
| Audio layer | Minimal/legacy tracker output | Default `alien_original_motion_tracker.m4a` atomized by distance band/spectrum/manual lock state |
| Visual UI | Compact single-mode text list | Alien-style HUD with focus meter, range bar, sparkline, sector view, and source spectrum |
| Manual target selection | Device name argument only | Interactive in-terminal selection (`k/j`/arrows, Enter to lock, `c` clear) |
| Stability/selection mode | Candidate list rendered at fixed density | Adaptive HUD with tiny/compact/standard/wide layouts based on terminal size |
| Tracking output | Best-effort RSSI + ranking | Confidence-aware candidates, focus freshness, stale markers, and sector tagging |
| Triangulation | Not included | Optional anchor-weighted estimate (`--anchors`) + map-like sector context |
| Defaults | Explicit CLI defaults for each mode | Audio pack defaults to `detector_asssets/alien_original_motion_tracker.m4a` unless overridden |

## Install

Build from source locally:

```sh
git clone https://github.com/RobLe3/alien-findphone.git
cd alien-findphone
swift build -c release
cp .build/release/findphone ~/bin/findphone
```

Requires macOS 13 or later and the Swift toolchain from Xcode Command Line Tools.

## Build

```sh
swift build -c release
cp .build/release/findphone ~/bin/findphone
```

`swift build -c release` only compiles and should not play tracker audio.
If you still hear tracking sounds during build, an older `findphone` instance is
still running in the background.
Use:

```sh
findphone --replace
```
to replace the stale process before you rebuild/run again.

For hands-on dev where you don't want any audio feedback, use:

```sh
findphone --mute --replace --no-wifi
```

or:

```sh
export ALIEN_FINDPHONE_MUTE=1
findphone --replace --no-wifi
```

Requires the Swift toolchain from Xcode Command Line Tools. No dependencies.

## Use

```sh
findphone            # survey mode: nearby Wi‑Fi + BLE candidates
findphone iphone     # hunt mode: track one device by name (defaulting to on-screen alien GUI + audio)
findphone --list     # paired devices and their addresses
```

In interactive terminal mode, use up/down (or j/k) and Enter to lock a highlighted
candidate, and `c` to clear manual lock.
The menu is now adaptive: in wide terminals it mirrors the classic full-width
menu format and collapses to compact symbols on narrow terminals.

Hunt mode defaults to the alien GUI and motion-tracker sound from the default
audio pack (`detector_asssets/alien_original_motion_tracker.m4a`), split into 5
RSSI bands.
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
findphone --audio-pack  # path to custom m4a pack for hunt audio (defaults to detector_asssets/alien_original_motion_tracker.m4a)
findphone --replace     # stop any existing detector process and start fresh
findphone --mute        # keep tracker silent
findphone --no-sound    # alias for --mute
```

You can also set `ALIEN_FINDPHONE_MUTE=1` for the same silent behavior.

## Interactive controls

- `k` / up-arrow: move highlight up
- `j` / down-arrow: move highlight down
- `Enter`: lock to highlighted target
- `c`: clear manual lock
- `q`: quit

In narrow terminals (`tiny` HUD), the controls are rendered as compact symbols:
`[↑][↓]` `↵` `c` `q` on a single menu line.

## Performance notes

- Use release builds for regular use (smoother rendering, tighter timer cadence):

  ```sh
  swift build -c release
  ```

- Audio atoms are discovered once at startup, then reused in memory; only mode,
  spectrum and confidence changes alter scheduling. This keeps runtime updates
  small and stable.
