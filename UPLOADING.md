# Upload videos from your PC

On the configured Craftoria PC, open PowerShell in the Craftoria workspace and run:

```powershell
python .\video-player\upload_video.py "https://www.youtube.com/watch?v=VIDEO_ID"
```

You can use a local video instead:

```powershell
python .\video-player\upload_video.py "C:\Videos\my-video.mp4" --name my-video
```

The script reads the source metadata and asks **GPT-6 Luna** for a short, natural display title through your signed-in Codex CLI. Titles aim for 20-32 characters and are capped at 40 printable ASCII characters to fit the monitor cards. Video IDs, hashes, URLs and upload labels such as HQ and Official Video are removed; recognizable song, artist, game and version information is preserved where possible. Only the title metadata is sent to the model, and the naming request runs without shell tools. No separate OpenAI API key is needed for this Codex login path. Naming errors stop the upload instead of silently using a different model or an ugly filename title. An invalid title gets one correction attempt.

The script then downloads a single video, fits it to the existing 7x4 Advanced Monitor wall, converts mono audio, and starts at **up to 30 FPS**, capped to the source frame rate. If needed, it tries lower rates (25, 24, 20, 15, 10, 7, 5, 3, 2 and 1 FPS) until the combined `.32vid` recording fits below **64 MiB**. It uploads only the full recording to the `videos/` prefix in `craftoria-video-player`, then downloads it again to verify SHA-256 and byte count. Click Refresh in Minecraft to see it.

The friendly display title is stored in R2 HTTP metadata, separately from the unique storage filename. The Worker reads it into the catalogue, preserving capitalization and punctuation. Existing download URLs and loop selections can remain stable when a title changes. `manifest.json` records the display title, original title, source ID and naming model. `--name` controls the storage filename; **`--title` controls the menu title** and bypasses AI naming.

The default size budget is 67,108,863 bytes, one byte below the server's user-reported `max_download = 67108864` setting. It applies to the complete video and audio together. If uploading for another server, use `--max-bytes` to match its HTTP download limit; for a 16 MiB server, use `--max-bytes 16777215`.

Source, intermediate files, conversion logs and `manifest.json` are retained in a new `publish/uploads/` directory for each run. These files are ignored by Git. A failed command exits with an error and preserves the working files. The script validates packet boundaries, frame count, duration and complete audio before upload. It does not run the Lua player on each future upload; the shared format and conversion path have been checked against the actual player.

Examples:

```powershell
# Give the menu entry your own title, bypassing AI naming:
python .\video-player\upload_video.py "YOUTUBE_URL" --title "My Video"

# Choose both the storage filename and the display title:
python .\video-player\upload_video.py "YOUTUBE_URL" --name my-video --title "My Video"

# Start at 30 seconds and keep only the next 60 seconds:
python .\video-player\upload_video.py "YOUTUBE_URL" --start 30 --duration 60

# Convert locally and inspect the result before uploading:
python .\video-player\upload_video.py "YOUTUBE_URL" --no-upload

# Use a maximum of 7 FPS to skip the higher frame-rate attempts:
python .\video-player\upload_video.py "YOUTUBE_URL" --max-fps 7

# Explicitly replace a previously uploaded filename:
python .\video-player\upload_video.py "YOUTUBE_URL" --name my-video --overwrite

# Renew Cloudflare authentication through your browser:
python .\video-player\upload_video.py --login
```

Without `--overwrite`, an existing public file causes the script to stop before download/conversion/upload. AI naming, uploads and checksum checks require internet access. `--no-upload` still names the video unless you provide `--title`. YouTube playlists/radio links are treated as a single linked video, starting at the beginning unless `--start` is provided. YouTube's source file is downloaded in full even when requesting a shorter clip. Recordings that exceed the size budget even at 1 FPS need a shorter `--duration`; moving to R2 does not remove the Minecraft server's download limit.

## Set up another PC

Clone/download this repository. Install Python 3.9+, FFmpeg (with the DFPWM encoder), Node.js, [yt-dlp](https://github.com/yt-dlp/yt-dlp), and [Sanjuuni 0.5](https://github.com/MCJack123/sanjuuni/releases/tag/0.5). On Windows, keep Sanjuuni's DLLs alongside its executable. Put tools on PATH or in `tools/` (for example, `tools/yt-dlp.exe` and `tools/sanjuuni/sanjuuni.exe`).

Install the [Codex CLI](https://learn.chatgpt.com/docs/non-interactive-mode) and run `codex login` for automatic naming. The configured PC is already signed in with ChatGPT and has been live-tested with `gpt-6-luna`. Windows installations from the Codex desktop app are discovered automatically when the CLI is not on PATH; a `"codex"` executable path may also be added to the local tool configuration. To use the uploader without Codex, pass `--title` explicitly.

Install Wrangler in the repository directory:

```powershell
npm install wrangler
python .\upload_video.py --login
python .\upload_video.py "YOUTUBE_URL"
```

Optional tool paths can be configured in `upload-video.local.json` next to the script or in its parent directory:

```json
{
  "yt-dlp": "C:/Tools/yt-dlp.exe",
  "sanjuuni": "C:/Tools/sanjuuni/sanjuuni.exe",
  "ffmpeg": "C:/Tools/ffmpeg/bin/ffmpeg.exe",
  "ffprobe": "C:/Tools/ffmpeg/bin/ffprobe.exe",
  "node": "C:/Program Files/nodejs/node.exe",
  "wrangler": "C:/Tools/node_modules/wrangler/bin/wrangler.js"
}
```

This file contains tool paths, not Cloudflare credentials. Wrangler manages its own login. The configured PC reuses its existing Wrangler installation through this local file. No Python packages beyond the standard library are required.

For a different deployment, pass both `--bucket YOUR_BUCKET` and `--base-url https://YOUR-WORKER`. The Worker must expose `/videos/<filename>.32vid` using the same bucket. The supplied [R2 Worker](r2/README.md) already does this. The [Wrangler R2 command documentation](https://developers.cloudflare.com/workers/wrangler/commands/r2/) describes the remote upload command used by the script.

Run the focused uploader checks with `python test_upload_video.py` from this repository directory.

Run naming checks with `python test_video_titles.py`. The Worker checks include friendly metadata decoding and preservation of video URLs.

To clean up an existing library using retained recordings, run `python rename_videos.py` for a proposed plan or `python rename_videos.py --apply` to apply it. The tool verifies each local recording against its manifest and the public copy before updating title metadata; changed entries are uploaded using their identical bytes and verified by SHA-256 afterward. Keys and URLs stay the same. The maintenance tool requires retained files under `uploads/` and records its before/after plan there.
