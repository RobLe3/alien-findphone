# findphone

Locate a nearby Bluetooth device by signal strength, from the command line.

Built for the case where Find My is unavailable — for example when a device is
enrolled in MDM that disables it — but the device is still within Bluetooth
range and you just need to know which corner of the room it is in.

## Build

```sh
swift build -c release
cp .build/release/findphone ~/bin/findphone
```

Requires the Swift toolchain from Xcode Command Line Tools. No dependencies.

## Use

```sh
findphone            # survey mode: every nearby Apple handheld, by signal
findphone WP         # hunt mode: track one device by name (case-insensitive)
```

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

Three sources feed one reading, in descending order of quality:

1. **GATT link** — once connected to the device over BLE, `readRSSI()` returns
   a fresh measurement about three times a second. This is the good one.
2. **BLE advertisements** — passively observed. Apple devices rotate their
   advertising addresses roughly every fifteen minutes and only include the
   device name on occasional packets, so this source is sparse.
3. **Classic link RSSI** — read from `system_profiler SPBluetoothDataType`,
   keyed by the stable public address of a paired device.

Source 3 has a trap worth knowing about: macOS refreshes that value only every
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
- Only finds devices with Bluetooth powered on and in range, roughly 10-20 m
  indoors and much less through walls.
