# Craftoria video player

A CC:Tweaked video player for a **7-wide x 4-high Advanced Monitor wall**, with audio through a connected Speaker. Start without arguments for a Cloudflare R2 video menu, or supply a local combined `.32vid` file or a direct HTTP(S) download URL.

## Open the video menu

Stop the existing player with Ctrl+T. Update the script and launch it with the same monitor name as your working test:

```text
wget https://raw.githubusercontent.com/Mavial/craftoria-video-player/main/video.lua video-r2.lua
monitor scale MONITOR_NAME 0.5
monitor MONITOR_NAME video-r2.lua
```

Choose an unused filename if `video-r2.lua` already exists. The R2 catalogue URL is configured in the script, so no further source setting is needed.

Click a video on the monitor, or use Up/Down and Enter from the computer. Click during playback or press Backspace to stop and return to the menu. Completed videos return automatically. The menu also has clickable Previous, Next, Refresh and Quit buttons; Left/Right changes pages, R refreshes, and Q quits.

The menu lists the `.32vid` objects under `videos/` in the dedicated `craftoria-video-player` R2 bucket, including test clips. A Cloudflare Worker builds the catalogue dynamically, follows R2 pagination, and streams recordings from the bucket. Upload or delete a converted recording in that prefix, then click Refresh to update the menu. Each row includes the file size. See [R2 deployment and upload instructions](r2/README.md).

HTTP access must allow `craftoria-video-player.raftoria.workers.dev`. The list loads on launch and on explicit refresh; playback uses the current session's list. A failed refresh keeps the previous list and displays the error. Video files are downloaded over HTTP and are not saved to the computer disk. The player retains its GitHub source adapter for migration and continues to accept direct file/URL arguments.

## Play Wii Shop Bling

Use the updated `video-r2.lua` and the same monitor name as your working test:

```text
monitor scale MONITOR_NAME 0.5
monitor MONITOR_NAME video-r2.lua https://craftoria-video-player.raftoria.workers.dev/videos/wii-shop-bling.32vid
```

Hold Ctrl+T in the computer GUI to stop the previous recording before entering the new command. The new recording starts at the beginning; the YouTube radio playlist is not included.

For a new computer, download the player first:

```text
wget https://raw.githubusercontent.com/Mavial/craftoria-video-player/main/video.lua video-r2.lua
```

Use `peripherals` to discover the monitor name. The ten-second test clip has been removed from R2 and GitHub; click Refresh in the menu to update the list.

## Recording and hardware

Source: [Wii Shop Bling, uploaded by eck](https://www.youtube.com/watch?v=gYOEyzBFYa4).

The recording uses **7 FPS**, 286x156 subpixels (143 columns x 52 rows at text scale 0.5), ANS video compression and mono 48 kHz DFPWM audio. It covers the complete video, with final-frame and silent padding to 244 seconds. The encoded picture is letterboxed rather than stretched. The full file is kept below the inspected local 16 MiB HTTP response limit; the dedicated server's active configuration can differ.

Use 28 joined Advanced Monitors, one dedicated Advanced Computer and one connected Speaker. The computer may touch the wall directly or connect over wired modems and Networking Cable. HTTP playback avoids writing the full recording to the computer disk. The server must permit the configured R2 Worker hostname.

The full recording is available through R2 and the GitHub release. The test clip was removed; its original conversion and validation records remain as historical metadata. `manifest.json` records exact dimensions, frame count, duration and file hashes. `verification.json` records simulated file/HTTP playback, monitor output and Speaker backpressure checks. `menu-verification.json` records menu checks with the installed CC:Tweaked scheduler and monitor program, covering clicks, keyboard selection, pagination, refresh, errors, stopping, replay and audio state, plus the live public GitHub and R2 libraries. The Worker checks cover catalogue pagination, exact download bytes, metadata, and route restrictions. The R2 menu and player were confirmed working in-world by the user.

## Upstream and licensing

The player derives from [Sanjuuni 0.5's `32vid-player-mini.lua`](https://github.com/MCJack123/sanjuuni/blob/0.5/32vid-player-mini.lua). Changes retain DFPWM decoder state, retry rejected speaker buffers, yield while waiting for frames, and close the input handle after successful playback. The source is distributed with the upstream project's GNU GPL version 2 license in `LICENSE`.

The GPL applies to the software. The source video's audio and images retain their original rights and attribution.
