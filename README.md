# MacAmp

A lightweight native macOS app that routes a USB audio input to any output
device, live. Built for practising guitar through a Sonicake Amphonix 2 without
opening a DAW.

It is a router and nothing else. Tone shaping belongs to the hardware and its
own companion app; MacAmp only does the thing macOS itself won't: take audio
from one device and play it out of a different one, continuously.

## Why this exists

`AVAudioEngine` cannot use a different input and output device. Its `inputNode`
and `outputNode` share a single `AUAudioUnit` with one `deviceID`; setting the
input collapses the output bus to 0 Hz / 0 channels. Cross-device monitoring
therefore needs two `AUHAL` units bridged by hand.

## Design

Four pieces:

| Component | Language | Role |
|---|---|---|
| `RingBuffer.c` | C | Lock-free SPSC ring, C11 atomics with acquire/release pairing |
| `AudioBridge.c` | C | Two AUHAL units, both render callbacks, drift-corrected resampler |
| `Devices.swift` | Swift | Device enumeration, UID persistence, hot-plug watching |
| `App.swift` | Swift | SwiftUI window: two pickers and a status line |

The realtime path is C on purpose. Render callbacks run on a CoreAudio thread
with a hard deadline where allocation, locks, ARC traffic and Swift's
exclusivity checks are all unsafe. Keeping them in C means the audio path
provably contains no Swift runtime — verifiable with
`nm build/obj/AudioBridge.o | grep swift_`, which returns nothing.

### Clock drift

The two devices run on independent crystals. At ±50 ppm each they can diverge
by up to 100 ppm — about 4.4 samples/sec at 44.1 kHz, roughly 6 ms per minute.
Left alone the ring buffer would drain or overflow within minutes.

The output callback low-pass filters the ring's fill level and nudges the
resample ratio to hold a target backlog, clamped to ±0.2% so the correction
stays well under the ~0.6% where pitch shift becomes audible. Interpolation is
cubic Hermite, which is transparent at ratio ≈ 1.0 and materially cleaner than
linear when the devices sit at different rates.

Underruns fade to silence rather than cutting hard, so a glitch is a dip and
not a click.

## Build

Requires only Command Line Tools — no Xcode.

```bash
./build.sh
```

Compiles are `nice`d so they yield to the window server.

## Permissions

Capturing from any audio input device requires TCC microphone authorization,
including USB interfaces that are not microphones. If denied, CoreAudio returns
digital silence rather than an error, so MacAmp checks authorization explicitly
and says so instead of appearing to work while playing nothing.

## Notes

- Device IDs are reassigned across reboots. Selections persist by
  `kAudioDevicePropertyDeviceUID`, never by `AudioDeviceID`.
- Output defaults to the built-in speakers rather than the system default,
  since a virtual audio driver holding "default output" would otherwise
  silently capture the signal.
