# alien-findphone

A retro-futuristic terminal proximity scanner for finding nearby Bluetooth devices on
macOS.

`alien-findphone` began as a fork of
[ben-z/findphone](https://github.com/ben-z/findphone) and expands the original
Bluetooth locator with an interactive terminal HUD, multi-source observations,
manual target selection, optional Wi‑Fi scanning, optional anchors, and a
beat-aligned motion-tracker audio engine.

The executable remains named `findphone`.

## Why it exists

The tool is intended for cases where Find My is unavailable, disabled, or not
usable, but the device is still powered on and within radio range.

It cannot make a device ring. Instead, it helps you search by showing how the
observed signal changes as you move.

## Platform

- macOS 13 or later
- Apple Silicon or Intel Mac
- Swift 5.9+ when building from source
- Bluetooth access for the terminal application
- No third-party package dependencies

Windows and Linux are not currently supported. The scanner, audio, terminal, and
permission layers rely on macOS frameworks.

## Main features

- BLE advertisement discovery
- Direct BLE GATT RSSI readings
- Classic Bluetooth RSSI observations
- Optional Wi‑Fi scanning
- Optional configured anchors
- Ranked multi-device candidate list
- Interactive target selection and locking
- Responsive terminal HUD (adaptive tiny/compact/standard/wide layouts)
- Confidence and freshness indicators
- Privacy redaction mode
- Single-instance process protection
- Explicit silent mode
- Bundled beat-aligned tracker audio
- Custom M4A override support
- Universal arm64 and x86_64 release build

## Original project and fork comparison

| Capability | Original `ben-z/findphone` | `alien-findphone` |
|---|---|---|
| Primary purpose | Locate a Bluetooth device by RSSI | Interactive multi-source proximity scanner |
| Platform | macOS | macOS |
| Survey mode | Yes | Yes |
| Hunt by name | Yes | Yes |
| Paired-device list | Yes | Yes |
| BLE advertisements | Yes | Yes |
| Direct BLE RSSI | Yes | Yes |
| Classic Bluetooth RSSI | Yes | Yes |
| Wi‑Fi observations | No | Optional |
| Configured anchors | No | Optional |
| Multiple visible candidates | Basic list | Ranked interactive candidate list |
| Target selection | Name argument | Name argument or interactive selection |
| Manual lock | No | Yes |
| Terminal interface | Single list | Adaptive retro-futuristic HUD |
| Privacy redaction | Yes | Yes |
| Audio | Optional synthetic behavior | Deterministic beat-grid audio |
| Process replacement | No | `--replace` |
| Explicit mute | Off by default | `--mute` or `--no-sound` |
| Tests | Small baseline | Terminal and audio regression checks |

## Install from a release

Download the universal release archive, extract it, and keep the extracted directory
together:

```bash
tar -xzf findphone-macos-universal.tar.gz
xattr -dr com.apple.quarantine alien-findphone
./alien-findphone/findphone --help
```

For installation:

```bash
mkdir -p ~/Applications
rm -rf ~/Applications/alien-findphone
cp -R alien-findphone ~/Applications/alien-findphone

mkdir -p ~/bin
ln -sf ~/Applications/alien-findphone/findphone ~/bin/findphone
```

Do not copy only the executable. The tracker audio is in the adjacent resource
bundle.

## Build from source

```bash
git clone https://github.com/RobLe3/alien-findphone.git
cd alien-findphone

swift build -c release
swift test
```

Run the built executable:

```bash
./.build/release/findphone --help
```

Create the self-contained universal release directory:

```bash
./scripts/build-universal.sh dist
```

Run the packaged build:

```bash
./dist/alien-findphone/findphone --help
```

## Basic use

Survey nearby candidates:

```bash
findphone
```

Track one device by name:

```bash
findphone iphone
```

List paired Bluetooth devices:

```bash
findphone --list
```

Run without Wi‑Fi scanning:

```bash
findphone --no-wifi
```

Run silently:

```bash
findphone --mute
```

Replace a detector process that is already running:

```bash
findphone --replace
```

Combine options:

```bash
findphone --mute --replace --no-wifi
```

## Interactive controls

| Input | Action |
|---|---|
| Up arrow or `k` | Move highlight up |
| Down arrow or `j` | Move highlight down |
| Enter | Lock the highlighted candidate |
| `c` | Clear the manual lock |
| `q` | Quit |
| Ctrl-C | Quit and restore terminal state |

## Command-line options

```text
findphone
findphone <name>
findphone --list

--help, -h            show help
--redact              mask Bluetooth addresses
--sound               legacy audio-enabling alias
--wifi                force-enable Wi‑Fi scanning
--no-wifi             disable Wi‑Fi scanning
--anchors <path>      load an optional anchor configuration
--audio-pack <path>   use a custom M4A tracker source
--replace             replace an already-running detector
--replace-existing    legacy alias for --replace
--mute                disable tracker audio
--no-sound            alias for --mute
```

Run `findphone --help` for the authoritative option list.


## Tracker audio

The default audio source is loaded from the application resource bundle included with the executable.

The bundled source uses an approximately:

- 84.72 BPM pulse clock
- 0.7082-second beat duration
- Alternating strong and weak pulse structure
- Broad tonal progression across stable source regions

The source is decoded once to PCM and split into beat-aligned buffers. These
buffers are queued contiguously on one `AVAudioPlayerNode` timeline. A short timer
keeps the queue near two beats deep so playback timing stays deterministic.

The current implementation keeps the rhythm fixed at approximately 84.72 BPM and
maps the selected target’s recent RSSI to a discrete verified tone level:

- stronger measured RSSI -> higher tone level
- weaker measured RSSI -> lower tone level
- stable measured RSSI -> same tone level repeats
- target lost -> returns toward the low tone region

The same tone level is played for both beats of each two-beat phrase, and the selected
tone level only changes at phrase boundaries.

A missing source now fails loudly by default; it is not silently replaced by
`Tink.aiff`.

A custom M4A source can be used with:

```bash
findphone --audio-pack /absolute/path/to/custom.m4a
```

An explicit environment override is also supported:

```bash
ALIEN_FINDPHONE_AUDIO_FILE=/absolute/path/to/custom.m4a findphone
```

### Audio debugging

Enable audio diagnostics:

```bash
ALIEN_FINDPHONE_AUDIO_DEBUG=1 findphone --replace --no-wifi
```

Diagnostics are written to standard error and may include:

- Resolved source path
- source format
- duration
- configured BPM
- beat duration
- beat-cell count
- requested/current tone level
- requested/current source pair index
- queued beats
- queue underrun count
- scheduled beat count
- completed beat count

Disable sound through environment:

```bash
export ALIEN_FINDPHONE_MUTE=1
findphone
```

## Handling several devices in one room

Survey mode displays multiple nearby candidates rather than forcing an immediate name
match.

Use the keyboard to highlight a candidate and press Enter to lock it:

1. Start in survey mode.
2. Select a candidate.
3. Move several steps.
4. Watch and listen for a consistent signal trend.
5. Lock the candidate that responds consistently.
6. Press `c` to clear the lock and test another candidate.

This helps in crowded environments, but it does not automatically prove which
physical device belongs to which person.

## Signal sources

The scanner can present observations from several sources.

### Direct BLE link

After a BLE connection is established, CoreBluetooth can request fresh RSSI
measurements.

### BLE advertisements

Nearby BLE advertisements are observed passively.

### Classic Bluetooth

Paired-device information and cached RSSI values are read through:

```text
system_profiler SPBluetoothDataType
```

macOS can retain the same value for several polling cycles.

### Wi‑Fi

CoreWLAN can optionally add nearby Wi‑Fi observations.

Wi‑Fi networks are separate radio observations and are not automatically proven to be
the same physical device as BLE candidates.

Disable Wi‑Fi input with:

```bash
findphone --no-wifi
```

### Configured anchors

An optional JSON file can define known anchors:

```bash
findphone --anchors ./anchors.json
```

Where implemented, anchor coordinates provide a **coarse anchor-weighted estimate**,
not true triangulation.

## Understanding RSSI

RSSI is reported in dBm. Values are negative, and values closer to zero normally
indicate stronger signal.

- `-45 dBm` or stronger: Very close
- Around `-60 dBm`: Nearby
- Around `-72 dBm`: Often in same room
- Around `-85 dBm`: Weak/intermittent
- Below `-90 dBm`: Very weak or obstructed

These values are rough estimates only. Walls, furniture, enclosures, body position,
and interference affect readings significantly.

## Privacy

Use redaction when recording the terminal:

```bash
findphone --redact
```

Redaction masks Bluetooth addresses where supported.

## Permissions

The terminal application requires Bluetooth permission:

```text
System Settings > Privacy & Security > Bluetooth
```

Wi‑Fi scanning may depend on local permissions and version behavior.

## Process protection

Only one normal detector instance should run at a time.

Starting another instance while one is active reports the conflict.

Replace the existing process deliberately:

```bash
findphone --replace
```

## Terminal behavior

Interactive input uses non-canonical, non-echoing keyboard mode while preserving
terminal output flags.

The application restores the original terminal settings when it exits normally or
via supported termination signals.

If a terminal is interrupted externally and remains misconfigured, restore it with:

```bash
stty sane
```

## Limitations

- It cannot make a device ring.
- It does not replace Find My.
- One receiver cannot provide reliable physical bearing.
- RSSI is a proximity indicator, not a physical distance measurement.
- Anchor estimates are coarse.
- BLE identities can rotate or omit names.
- Similar names and rotating BLE addresses can still require manual comparison.
- Wi‑Fi and Bluetooth observations are not automatic identity fusion.
- The current implementation is macOS-only.

## Development checks

Run the full local verification:

```bash
swift package clean
swift build
swift test
swift build -c release
git diff --check
```

Run noninteractive smoke checks:

```bash
./.build/release/findphone --help
./.build/release/findphone --list
```

Run a quiet interactive smoke test:

```bash
./.build/release/findphone --mute --replace --no-wifi
```

Run with audio diagnostics:

```bash
ALIEN_FINDPHONE_AUDIO_DEBUG=1 \
./.build/release/findphone --replace --no-wifi
```

## Project structure

```text
Sources/findphone/
├── main.swift
├── Tracker.swift
├── Signal.swift
├── SignalRegistry.swift
├── WiFiScanner.swift
├── Classic.swift
├── Display.swift
├── Style.swift
├── BigText.swift
├── Sound.swift
├── MotionTrackerAudioProfile.swift
├── Resources/
│   └── alien_original_motion_tracker.m4a

Tests/findphoneTests/
├── SoundTests.swift
├── TerminalSelectionControllerTests.swift

scripts/
├── build-universal.sh
└── verify-readme-options.sh

.github/workflows/
└── ci.yml
└── release.yml
```

The exact file split may evolve as the implementation changes.

## Attribution

This project is forked from
[ben-z/findphone](https://github.com/ben-z/findphone).

The original project established the macOS Bluetooth scanning, survey, hunt,
redaction, and proximity-locator foundation.

This fork adds interactive HUD, expanded source fusion, manual selection/locking,
process controls, and the beat-aligned tracker audio system.

## License

See the repository license.
