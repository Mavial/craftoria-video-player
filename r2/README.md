# R2 video library

Bucket: `craftoria-video-player`.

Worker: `https://craftoria-video-player.raftoria.workers.dev`.

Catalogue: `https://craftoria-video-player.raftoria.workers.dev/videos.json`.

The bucket is bound to the Worker as `VIDEOS`. The Worker exposes only GET/HEAD access to `.32vid` files under `videos/` and generates the catalogue from R2's current contents. It follows R2 cursor pagination through the catalogue's Link response header. No browser or Minecraft client credentials are needed; video downloads through the Worker are public.

Upload a new converted recording under `videos/`, then click Refresh on the monitor:

For a YouTube URL or local MP4, the [automatic uploader](../UPLOADING.md) handles downloading, conversion, upload and checksum verification for you. The command below is for files already converted to `.32vid`.

```powershell
npx wrangler r2 object put "craftoria-video-player/videos/example.32vid" --file "C:\path\example.32vid" --content-type application/octet-stream --remote
```

Keep recordings within the Minecraft server's HTTP download limit. The configured server now allows 64 MiB per request (`max_download = 67108864`, reported by the user); the automatic uploader defaults to one byte below this. The player and Worker impose no additional 16 MiB cap. Filenames supply menu titles; optional R2 custom metadata `title` overrides the generated title.

Deploy changes from this directory with `npx wrangler deploy`. Run the Worker checks with `node --test worker.test.mjs`.

To move the player to another catalogue, run `set video.r2_url https://YOUR-WORKER/videos.json` in the computer, then restart the player. The catalogue must return a JSON array of objects containing `title`, `url` (HTTPS), and `size` (bytes). If paginated, provide a Link response header with `rel="next"`. The supplied Worker generates that format automatically.
