# Craftoria video player

A CC:Tweaked video player for a **7-wide x 4-high Advanced Monitor wall**, with audio through a connected Speaker. Start without arguments for a GitHub video menu, or supply a local combined `.32vid` file or a direct HTTP(S) download URL.

## Open the video menu

Stop the existing player with Ctrl+T. Update the script and launch it with the same monitor name as your working test:

```text
wget https://raw.githubusercontent.com/Mavial/craftoria-video-player/main/video.lua video-new.lua
move video.lua video-backup.lua
move video-new.lua video.lua
monitor scale MONITOR_NAME 0.5
monitor MONITOR_NAME video.lua
```

Choose unused temporary and backup filenames if those files already exist. For a new computer, download directly to `video.lua` and skip the two moves.

Click a video on the monitor, or use Up/Down and Enter from the computer. Click during playback or press Backspace to stop and return to the menu. Completed videos return automatically. The menu also has clickable Previous, Next, Refresh and Quit buttons; Left/Right changes pages, R refreshes, and Q quits.

The menu reads every published release and its assets from this repository using GitHub's public API. It follows release and asset pagination and lists all uploaded `.32vid` files, including test clips. Deleted files and drafts do not appear. Upload future converted videos as release assets, then click Refresh to see them without editing the script. Asset labels become menu titles; otherwise the filename supplies the title. Each row includes its release tag and size.

HTTP access must allow `api.github.com` as well as GitHub's download hosts. The list loads on launch and on explicit refresh; playback uses the current session's list. A failed refresh keeps the previous list and displays the error. A GitHub request limit can be retried later. Video files stream over HTTP and are not saved to the computer disk.

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

Release assets contain the full recording, a ten-second test and SHA-256 checksums. `manifest.json` records exact dimensions, frame count, duration and file hashes. `verification.json` records simulated file/HTTP playback, monitor output and Speaker backpressure checks. `menu-verification.json` records menu checks with the installed CC:Tweaked scheduler and monitor program, covering clicks, keyboard selection, pagination, refresh, errors, stopping, replay and audio state, plus the live public GitHub library. The earlier player and wall were confirmed in-world; the new menu still needs an in-world check.

## Upstream and licensing

The player derives from [Sanjuuni 0.5's `32vid-player-mini.lua`](https://github.com/MCJack123/sanjuuni/blob/0.5/32vid-player-mini.lua). Changes retain DFPWM decoder state, retry rejected speaker buffers, yield while waiting for frames, and close the input handle after successful playback. The source is distributed with the upstream project's GNU GPL version 2 license in `LICENSE`.

The GPL applies to the software. The source video's audio and images retain their original rights and attribution.
