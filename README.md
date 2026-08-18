<p align="center">
  <img src="assets/app-icon.png" alt="MacAmp" width="128">
</p>

<h1 align="center">MacAmp</h1>

A guitar amp for your Mac, in the narrow sense that matters: it takes the audio
coming in from a USB interface and plays it out of a **different** device, live
and continuously, so you can plug in and hear yourself without opening a DAW.

It does exactly one thing. Two dropdowns, one status line. The tone is your
hardware's business — MacAmp only does the part macOS itself refuses to.

> A personal project, built for a Sonicake Amphonix 2 going into a MacBook Pro.
> Nothing about it is specific to that amp; any class-compliant USB audio input
> works. Not affiliated with Sonicake.

## Why

Plug a modelling headphone amp into a Mac over USB and macOS will happily record
it. It will not simply *play it back*. There is no system setting for "take this
input and put it on those speakers" — monitoring is a thing DAWs do, so the
normal answer is to launch GarageBand, make a project you will never save, arm a
track, and leave a 700 MB application running so that a guitar makes noise.

The obvious way to write the small version of that is `AVAudioEngine`, and it
does not work. **`AVAudioEngine` cannot use a different input and output
device.** Its `inputNode` and `outputNode` share a single `AUAudioUnit` with one
`deviceID`; set the input to your interface and the output bus collapses to
0 Hz / 0 channels, then crashes when you connect it to the mixer. This is
long-standing and documented, not a bug to be worked around.

So cross-device monitoring means dropping to the C API and driving two `AUHAL`
units by hand, with a lock-free ring buffer between them and something to absorb
the fact that the two devices' clocks disagree. That is the whole program.

### Prior art

**[Loopback](https://rogueamoeba.com/loopback/)** and
**[Audio Hijack](https://rogueamoeba.com/audiohijack/)** (Rogue Amoeba) are far
better programs than this one. They route anything to anything, with a node
graph, effects, and a virtual driver that other apps can see. If you want a
general audio routing tool, buy one of those — they are excellent and worth the
money.

**[BlackHole](https://github.com/ExistentialAudio/BlackHole)** is free and
superb, but it solves an adjacent problem: it is a virtual *device* for getting
audio between applications, not a router between two pieces of hardware.

**[LadioCast](https://apps.apple.com/app/ladiocast/id411213048)** is free and
genuinely does this. It is aimed at broadcasters, so the interface is four input
strips and a matrix of routing buttons.

MacAmp is smaller than all of them on purpose. There is no matrix, no graph, no
virtual device, and nothing to configure — because when the answer is always
"this interface to those speakers," there is nothing worth asking.

## How it fits together

```
   guitar ──▶ Amphonix 2 ──USB Audio 2.0──▶ ┌──────────────────────────┐
                44,100 Hz                   │  input AUHAL             │
              (tone happens here)           │         ▼                │
                                            │  lock-free ring buffer   │
                                            │         ▼                │
                                            │  drift-corrected resample│
                                            │         ▼                │
                                            │  output AUHAL            │
                                            └────────────┬─────────────┘
                                                         ▼  48,000 Hz
                                               MacBook Pro Speakers
```

| File | Language | Role |
|---|---|---|
| `src/RingBuffer.c` | C | Lock-free SPSC ring, C11 atomics with acquire/release pairing |
| `src/AudioBridge.c` | C | Both AUHAL units, both render callbacks, the resampler |
| `src/Devices.swift` | Swift | Enumeration, UID persistence, hot-plug watching |
| `src/App.swift` | Swift | The window: two pickers and a status line |

**The realtime path is C on purpose.** Render callbacks run on a CoreAudio
thread with a hard deadline, where allocation, locks, ARC traffic and Swift's
exclusivity checks are all unsafe. Writing them in C means the audio path
provably contains no Swift runtime, which you can check rather than take on
faith:

```bash
nm build/obj/AudioBridge.o | grep swift_    # returns nothing
```

## Install

```bash
git clone https://github.com/adamkbritsch/macamp.git
cd macamp
./build.sh
cp -R build/MacAmp.app /Applications/
```

Then open it. Monitoring starts on launch and stops when you quit — there is no
on switch, because an app you opened deliberately is the on switch.

**macOS will ask for microphone access the first time.** Grant it. Capturing
from *any* audio input needs TCC authorisation, including USB interfaces that
are not microphones. This matters more than it sounds: **when access is denied,
CoreAudio returns digital silence rather than an error**, so an app that skips
the check looks like it is working and plays nothing. MacAmp checks explicitly
and tells you.

## Requirements

- **Apple Silicon Mac, macOS 13+.** Built and tested on macOS 26.
- **Command Line Tools** are enough for the app itself — `swiftc` compiles
  SwiftUI fine, and there is no Xcode project or `xcodebuild` anywhere.
- **Full Xcode, for the icon only.** `MacAmp.icon` is an Icon Composer bundle
  and `actool` ships with Xcode rather than Command Line Tools. Because
  `xcode-select` typically points at Command Line Tools, `xcrun` will not find
  it, so `build.sh` tries `xcrun` first and falls back to the absolute path
  inside `Xcode.app`. Without Xcode the build still succeeds and simply warns
  that the app will have no icon.
- **A class-compliant USB audio input.** Anything macOS shows in the input list.

## What it does

- **Routes one device to another, continuously.** That is the feature.
- **Remembers your choice by device UID**, never by `AudioDeviceID` — those get
  reassigned across reboots, so an app that persists the number reopens pointing
  at whatever inherited it.
- **Defaults output to the built-in speakers** rather than the system default.
  A virtual audio driver that has installed itself as "default output" —
  Boom 3D, Teams, Steam, a Multi-Output Device — would otherwise swallow the
  signal silently.
- **Survives unplugging.** Pull the interface mid-session and it says so; plug
  it back in and it resumes on its own.
- **Refuses to route a device into itself.** Many USB interfaces advertise both
  input and output endpoints — the Amphonix reports `in=2 out=2`, its output
  existing so backing tracks can be played into the amp — so it is a legitimate
  output device that is nonetheless never a valid destination here. It is
  filtered from the output list, and the engine refuses it outright in case a
  stale saved selection gets that far.

### Clock drift

The two devices run on independent crystals. At ±50 ppm each they can diverge by
up to 100 ppm — about **4.4 samples per second at 44.1 kHz, roughly 6 ms per
minute.** Left alone, the ring buffer drains or overflows within minutes and the
audio dies partway through a practice session.

So the output callback low-pass filters the ring's fill level and nudges the
resample ratio to hold a target backlog, clamped to **±0.2%** — well under the
~0.6% where pitch change becomes audible. Interpolation is cubic Hermite:
transparent when the two devices sit at the same rate, and materially cleaner
than linear when they do not. Underruns fade to silence rather than cutting
hard, so a glitch is a dip and not a click.

If your input and output are both capable of 44.1 kHz, matching them in **Audio
MIDI Setup** removes the rate conversion entirely and leaves the resampler doing
nothing but drift correction. MacAmp will not do this for you — a device's
nominal sample rate is shared state that every other app on the machine sees.

### One thing it deliberately does not do

**There is no EQ, no gain, no metering, no effects, and no volume slider.**

Not because they are hard — the gain is about ten lines — but because a modelling
amp already has them, in hardware, with its own editor. A second tone stage in
software would mean dialling in a sound on the amp and then having it altered on
the way out by a control you forgot you set. The signal arrives shaped and leaves
unshaped, and the only question the app asks is where to put it.

## Credits

Amp artwork from [SVG Repo](https://www.svgrepo.com/), recoloured and composited
in Icon Composer.

## Licence

MIT. See [LICENSE](LICENSE).
