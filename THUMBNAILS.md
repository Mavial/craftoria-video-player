# In-game thumbnails

The library cards show small pixel-art previews alongside the video title. PLAY, LOOP, IN/OUT, keyboard selection and the six-card wall layout keep their existing behavior. Touching a thumbnail plays that card. Very small layouts retain the full-width title instead.

Stop the old player with Ctrl+T, then download to an unused filename and run it:

```text
wget https://raw.githubusercontent.com/Mavial/craftoria-video-player/main/video.lua video-thumbnails.lua
video-thumbnails.lua
```

If the computer boots a copied player in `startup.lua`, update that copy after checking the new version. A startup script that launches a separate player file should point to the updated file.

**Settings > Display > Thumbnails** switches previews on or off. They are enabled by default. Previews appear progressively, and the controls remain usable while they load. Missing or unsupported previews show a neutral placeholder; the recording remains playable. Refresh retries failed previews.

Existing uploads work without re-uploading, converting or creating thumbnail objects. The Worker advertises an optional `thumbnail` URL per catalogue entry. This returns at most the opening 256 KiB of the existing combined `.32vid`, with HTTP 206 and the actual Content-Range. Thumbnail URLs include the recording's ETag so replacement invalidates the image. Metadata-only title changes with identical bytes reuse it. Normal recording downloads and older players keep working.

The Lua player requests only visible cards, with one request active at a time and a ten-second timeout. A separate request URL keeps thumbnail HTTP events distinct from video playback. It indexes at most 240 complete frames within the bounded prefix, decodes up to eight representative frames one per UI turn, and keeps the image with the most visual variation. It stores at most 32 tiny images in RAM and writes no thumbnail files to the computer disk. Leaving and revisiting a cached page does not fetch it again. Restarting the program clears the cache.

All cards share the monitor's menu palette. The player resamples the converted picture and draws sextant characters using that shared palette, preserving the image's aspect ratio. These previews are deliberately small and have fewer colours than full-screen playback. A dark opening or an unusually large first packet can still produce a dark or unavailable thumbnail.

With thumbnails enabled, very large low-scale layouts are capped at 32 cards per page so the current page fits in the cache instead of repeatedly fetching evicted images.

The thumbnail decoder is separate from the existing playback decoder. Unsupported dimensions, oversized ANS dictionaries, malformed packets and unbounded HTTP responses fall back to a placeholder. Completed HTTP response handles close on success and failure, including when they arrive during playback or a synchronous catalogue request.

## Validation

`thumbnail-verification.json` records the Lua regression checks, using the installed CC:Tweaked ROM scheduler with simulated HTTP and monitors. Coverage includes independent decoded-pixel comparisons, background loading, paging/cache eviction, click targets, failures, retries, limits, late responses, playback, version replacement and compact layouts. Existing menu/settings/playlist/audio checks also pass. These are simulations; the new thumbnail UI still needs an in-world check.

Run the Worker tests with `node --test r2/worker.test.mjs`. The workspace's `../verify_thumbnails.py` runs the native Lua fixtures with its existing ROM, sample video and Rust reference decoder. The preview renderer uses the actual Lua cells and the installed CC:Tweaked font; its output is a simulated monitor preview, not an in-world screenshot.
