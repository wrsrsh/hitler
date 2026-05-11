# Sync

Multi-Mac speaker syncing over Wi-Fi. One Mac plays anything (Apple Music,
Spotify, browser, etc.), every other Mac on the same network plays the same
audio in sample-accurate sync.

## How it works

- **Discovery**: Bonjour (`_syncaudio._tcp`) over `Network.framework`, no
  configuration. Same Wi-Fi (or peer-to-peer Wi-Fi) is the only requirement.
- **Capture**: `ScreenCaptureKit` taps system audio on the host
  (`excludesCurrentProcessAudio` so we don't loop our own output back in).
- **Clock sync**: NTP-style ping-pong (peer ↔ host) twice per second. We keep
  the offset from the lowest-RTT sample.
- **Transport**: A single TCP connection per peer (Nagle off). Each audio
  frame is stamped with a future host-clock presentation time
  (`now + 250 ms`).
- **Playback**: Peers translate that host time to local time using the clock
  offset, then schedule the buffer with `AVAudioPlayerNode.scheduleBuffer(at:)`.
  All speakers fire at the same wall-clock instant.

## Generate the Xcode project

```bash
brew install xcodegen   # already done on this machine
xcodegen generate
open Sync.xcodeproj
```

Then in Xcode:

1. Select the `Sync` target → **Signing & Capabilities**, pick your team
   (or leave it unsigned + check "Sign to Run Locally").
2. Build & Run on each Mac you want to involve.

## Using it

On the **host** Mac:

- Click **Host Audio**. The first time, macOS will prompt for **Screen &
  System Audio Recording** permission — grant it (audio capture via SCK is
  gated on this permission). Restart the app.
- Play anything. The audio is captured and streamed to every peer.

On each **peer** Mac:

- Click **Join a Host**. macOS will prompt for **Local Network** permission —
  allow. It will discover the host automatically.
- Wait a second or two for "Synced — offset X ms".
- You should hear the host's audio playing through your speakers, in sync
  with every other peer.

## Tunables

- `bufferDelay` in `AppModel.swift` (currently 250 ms). Lower it for less
  latency, raise it if you hear glitches.
- Sample rate / channels are forced to 48 kHz stereo in `AudioCapture.swift`.

## Echo on the host machine

The host's own speakers will keep playing the original audio live, while
peers play the delayed sync'd copy. If you want the host machine itself to
play the synced (delayed) version too — making it just another speaker in
the cluster — toggle **"Host plays through its own speakers"** on the idle
screen. But the host's original output (from Music/Spotify) is still going
to its speakers, so you'll get an echo unless you route the source through a
virtual audio device like [BlackHole](https://github.com/ExistentialAudio/BlackHole)
and set system output to it.

For a "host is just the streamer" setup, leave the toggle off and put the
host across the room.

## Limits

- macOS 14+ on every machine (ScreenCaptureKit audio + `AVAudioTime.hostTime`).
- Same Wi-Fi network, or peer-to-peer Wi-Fi (Bonjour with
  `includePeerToPeer = true`). Wired Ethernet works too.
- No congestion control or jitter buffer beyond the fixed presentation
  delay. On a clean LAN, this is fine; on a saturated one, raise
  `bufferDelay`.
