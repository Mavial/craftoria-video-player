# Craftoria video player

A CC:Tweaked video player and a converted PACER demonstration for a **7-wide x 4-high Advanced Monitor wall**. The player supports a local combined `.32vid` file or a direct HTTP(S) download URL, with audio through a connected Speaker.

## Play the full recording

If you already ran the local test successfully, use your existing `video.lua` and the same monitor name:

```text
monitor scale MONITOR_NAME 0.5
monitor MONITOR_NAME video.lua https://github.com/Mavial/craftoria-video-player/releases/download/v1.0.0/pacer.32vid
```

For a new computer, download the player first:

```text
wget https://raw.githubusercontent.com/Mavial/craftoria-video-player/main/video.lua video.lua
```

Use `peripherals` to find the monitor name. Hold Ctrl+T in the computer GUI to interrupt playback.

## Test clip

The ten-second clip is small enough to save on the computer:

```text
wget https://github.com/Mavial/craftoria-video-player/releases/download/v1.0.0/pacer-test.32vid pacer-test.32vid
monitor MONITOR_NAME video.lua pacer-test.32vid
```

Release assets include the full recording, the test clip, and SHA-256 checksums. The full file is **9,290,276 bytes**. HTTP playback avoids saving it to the computer's disk, but the Minecraft server must allow the full HTTP response and GitHub's download redirect hosts.

## Hardware and format

- 28 Advanced Monitors in one joined 7x4 rectangle, all facing the same way.
- One dedicated Advanced Computer, directly touching the monitor wall or connected through wired modems and Networking Cable.
- One connected Speaker.
- Text scale 0.5, expected terminal size 143 columns x 52 rows, video size 286x156 subpixels.
- Combined 32vid, ANS video compression, mono 48 kHz DFPWM audio.

The recording begins at **14 seconds** into [FitnessGram 20-Meter PACER Test OFFICIAL AUDIO (Part 1), uploaded by WrightM](https://www.youtube.com/watch?v=Y82jDHRrswc&t=14s). It runs for 887 seconds including a fraction of a second of final silent padding. The sampled frames show a static title card, so the conversion uses 1 FPS and letterboxing to preserve the encoded picture's aspect ratio. This frame rate is specific to the demo recording.

## Validation and upstream

The local ten-second test was confirmed working in-world on 2026-10-11. Before release, the player and installed CC:Tweaked 1.120.2 DFPWM decoder were exercised with simulated file/HTTP handles, monitor output and a Speaker that rejects full buffers. The complete file decoded all 887 frames and 42,576,000 audio samples. `manifest.json` and `verification.json` record those results. Full-recording playback on the dedicated server still needs commissioning.

The player derives from [Sanjuuni 0.5's `32vid-player-mini.lua`](https://github.com/MCJack123/sanjuuni/blob/0.5/32vid-player-mini.lua). Changes retain DFPWM decoder state, retry rejected speaker buffers, yield while waiting for frames, and close the input handle after successful playback. The source is distributed with the upstream project's GNU GPL version 2 license in `LICENSE`.

The GPL applies to the software. The PACER recording and title-card attribution remain with their original rights holders; the source title card credits **The Cooper Institute (FitnessGram), 2011**.
