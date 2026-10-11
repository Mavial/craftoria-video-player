# Craftoria video player

A CC:Tweaked video player for a **7-wide x 4-high Advanced Monitor wall**, with audio through a connected Speaker. It accepts a local combined `.32vid` file or a direct HTTP(S) download URL.

## Play Wii Shop Bling

Use your existing `video.lua` and the same monitor name as your working test:

```text
monitor scale MONITOR_NAME 0.5
monitor MONITOR_NAME video.lua https://github.com/Mavial/craftoria-video-player/releases/download/v1.1.0/wii-shop-bling.32vid
```

Hold Ctrl+T in the computer GUI to stop the previous recording before entering the new command. The new recording starts at the beginning; the YouTube radio playlist is not included.

For a new computer, download the player first:

```text
wget https://raw.githubusercontent.com/Mavial/craftoria-video-player/main/video.lua video.lua
```

Use `peripherals` to discover the monitor name. The test clip is available at:

```text
monitor MONITOR_NAME video.lua https://github.com/Mavial/craftoria-video-player/releases/download/v1.1.0/wii-shop-bling-test.32vid
```

## Recording and hardware

Source: [Wii Shop Bling, uploaded by eck](https://www.youtube.com/watch?v=gYOEyzBFYa4).

The recording uses **7 FPS**, 286x156 subpixels (143 columns x 52 rows at text scale 0.5), ANS video compression and mono 48 kHz DFPWM audio. It covers the complete video, with final-frame and silent padding to 244 seconds. The encoded picture is letterboxed rather than stretched. The full file is kept below the inspected local 16 MiB HTTP response limit; the dedicated server's active configuration can differ.

Use 28 joined Advanced Monitors, one dedicated Advanced Computer and one connected Speaker. The computer may touch the wall directly or connect over wired modems and Networking Cable. HTTP playback avoids writing the full recording to the computer disk. The server must permit GitHub and its release-download redirect hosts.

Release assets contain the full recording, a ten-second test and SHA-256 checksums. `manifest.json` records exact dimensions, frame count, duration and file hashes. `verification.json` records simulated file/HTTP playback, monitor output and Speaker backpressure checks. The existing player and wall were previously confirmed in-world; this replacement recording still needs an in-world playback check.

## Upstream and licensing

The player derives from [Sanjuuni 0.5's `32vid-player-mini.lua`](https://github.com/MCJack123/sanjuuni/blob/0.5/32vid-player-mini.lua). Changes retain DFPWM decoder state, retry rejected speaker buffers, yield while waiting for frames, and close the input handle after successful playback. The source is distributed with the upstream project's GNU GPL version 2 license in `LICENSE`.

The GPL applies to the software. The source video's audio and images retain their original rights and attribution.
