# Upload videos from your PC

On the configured Craftoria PC, open PowerShell in the Craftoria workspace and run:

```powershell
python .\video-player\upload_video.py "https://www.youtube.com/watch?v=VIDEO_ID"
```

You can use a local video instead:

```powershell
python .\video-player\upload_video.py "C:\Videos\my-video.mp4" --name my-video
```

The script downloads a single video, fits it to the existing 7x4 Advanced Monitor wall, converts mono audio, and tries 10, 7, 5, 3, 2 and 1 FPS until the combined `.32vid` recording fits below 16 MiB. It uploads only the full recording to the `videos/` prefix in `craftoria-video-player`, then downloads it again to verify SHA-256 and byte count. Click Refresh in Minecraft to see it. Video titles in the menu come from the resulting filename.

Source, intermediate files, conversion logs and `manifest.json` are retained in a new `publish/uploads/` directory for each run. These files are ignored by Git. A failed command exits with an error and preserves the working files. The script validates packet boundaries, frame count, duration and complete audio before upload. It does not run the Lua player on each future upload; the shared format and conversion path have been checked against the actual player.

Examples:

```powershell
# Give the menu entry a short name:
python .\video-player\upload_video.py "YOUTUBE_URL" --name my-video

# Start at 30 seconds and keep only the next 60 seconds:
python .\video-player\upload_video.py "YOUTUBE_URL" --start 30 --duration 60

# Convert locally and inspect the result before uploading:
python .\video-player\upload_video.py "YOUTUBE_URL" --no-upload

# Use a maximum of 7 FPS to skip the initial 10 FPS attempt:
python .\video-player\upload_video.py "YOUTUBE_URL" --max-fps 7

# Explicitly replace a previously uploaded filename:
python .\video-player\upload_video.py "YOUTUBE_URL" --name my-video --overwrite

# Renew Cloudflare authentication through your browser:
python .\video-player\upload_video.py --login
```

Without `--overwrite`, an existing public file causes the script to stop before conversion/upload. Uploads and checksum checks require internet access. YouTube playlists/radio links are treated as a single linked video, starting at the beginning unless `--start` is provided. YouTube's source file is downloaded in full even when requesting a shorter clip. Very long recordings need `--duration`; moving to R2 does not remove the Minecraft server's download limit.

## Set up another PC

Clone/download this repository. Install Python 3.9+, FFmpeg (with the DFPWM encoder), Node.js, [yt-dlp](https://github.com/yt-dlp/yt-dlp), and [Sanjuuni 0.5](https://github.com/MCJack123/sanjuuni/releases/tag/0.5). On Windows, keep Sanjuuni's DLLs alongside its executable. Put tools on PATH or in `tools/` (for example, `tools/yt-dlp.exe` and `tools/sanjuuni/sanjuuni.exe`).

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
