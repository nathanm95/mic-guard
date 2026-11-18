# mic-guard

**Stop your AirPods (or any Bluetooth headphones) sounding muffled on a Mac.**

macOS sometimes switches the microphone to your Bluetooth headphones on its own:
when they connect, when an app asks for audio input, or for no obvious reason.
When that happens, music and video suddenly sound flat, mono and muffled.

mic-guard is a tiny background helper that stops this. It keeps the Mac's
microphone off your Bluetooth headphones, so they stay in high-quality mode.

## Why it happens

Bluetooth headphones have two modes:

| Mode | Used for | Sound |
|---|---|---|
| A2DP (AAC/SBC) | Listening only | High-quality stereo, 44.1 or 48 kHz |
| HFP (headset) | Listening **and** using the mic | Low-quality mono, 16 or 24 kHz |

They can't use the mic and play high-quality stereo at the same time, so as soon
as anything uses the headphones' mic, macOS drops them into headset mode.
Sometimes they stay stuck there even after the mic is no longer in use.

## What mic-guard does

- **Keeps the mic off Bluetooth.** When the Mac's input device becomes a
  Bluetooth device, mic-guard switches it straight back to the mic you were
  using before (or the built-in mic, or a USB mic on a Mac without one).
- **Un-sticks headphones.** If the headphones are stuck in headset mode and
  nothing is using their mic, it puts them back into high-quality mode.
- **Leaves everything else alone.** USB headsets, audio interfaces and the
  built-in mic are never touched.
- **Can be paused** when you do want to use your headphones' mic.

It uses Apple's Core Audio API, has no dependencies, and doesn't record or
listen to anything, so it needs no microphone permission.

## Install

You need macOS 12 (Monterey) or later and the Xcode Command Line Tools. If you
don't have them, run `xcode-select --install`.

```sh
git clone https://github.com/nathanm95/mic-guard.git
cd mic-guard
./install.sh
```

That builds mic-guard, copies it to `~/.local/bin`, and starts it. It also
starts automatically every time you log in.

## Use

It works on its own once installed. There are a few commands if you need them:

```sh
mic-guard status    # is it running, which mic is in use, are the headphones in high quality?
mic-guard pause     # allow your Bluetooth headphones' mic, e.g. for a call away from your desk
mic-guard resume    # block it again and fix things straight away
```

Example:

```
$ mic-guard status
Watcher: running
Guard:   on (Bluetooth mics are blocked)
Input:   MacBook Pro Microphone (built-in)
Output:  AirPods Pro (48000 Hz, high quality)
```

The log of everything it has switched is at `~/Library/Logs/mic-guard.log`.

## Things to know

- **Apps with their own mic setting.** mic-guard controls the Mac's *default*
  microphone. If Zoom, Teams, Meet, Discord and so on are set to use your
  headphones' mic specifically, they will still switch the headphones into
  headset mode during calls. Set the app's microphone to your built-in mic or
  "System default" instead.
- **MacBook with the lid closed.** Recent MacBooks disconnect the built-in mic
  in hardware when the lid is closed. If you use a closed MacBook with an
  external display and have no other mic, run `mic-guard pause` for calls.

## Uninstall

```sh
./uninstall.sh
```

This stops mic-guard and removes everything the installer added.

## Licence

[MIT](LICENSE)
