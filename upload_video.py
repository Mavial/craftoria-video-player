"""Convert one video for the Craftoria monitor and upload it to Cloudflare R2."""
from argparse import ArgumentParser
from datetime import datetime
from fractions import Fraction
from pathlib import Path
import hashlib
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import uuid
from video_titles import MODEL, generate_title, title_disposition, validate_title

ROOT = Path(__file__).resolve().parent
DEFAULT_BASE = 'https://craftoria-video-player.raftoria.workers.dev'
DEFAULT_BUCKET = 'craftoria-video-player'
MAX_BYTES = 64 * 1024 * 1024 - 1
USER_AGENT = 'Craftoria-Video-Uploader/1.0'


class TooLarge(ValueError):
    pass


def slug(title):
    title = unicodedata.normalize('NFKD', title).encode('ascii', 'ignore').decode().lower()
    return re.sub(r'[^a-z0-9]+', '-', title).strip('-')[:80].rstrip('-') or 'video'


def config():
    for directory in (ROOT, ROOT.parent):
        path = directory / 'upload-video.local.json'
        if path.exists():
            return json.loads(path.read_text(encoding='utf-8-sig'))
    return {}


def tool(name, settings):
    configured = settings.get(name)
    suffix = '.exe' if os.name == 'nt' else ''
    candidates = [Path(configured)] if configured else []
    for directory in (ROOT / 'tools', ROOT.parent / 'tools'):
        candidates.extend([directory / (name + suffix), directory / name / (name + suffix)])
    located = shutil.which(name)
    if located:
        candidates.append(Path(located))
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate.resolve())
    raise ValueError(f'Missing {name}. Install it on PATH or set its path in upload-video.local.json.')


def wrangler_command(settings):
    node = tool('node', settings)
    candidates = [Path(settings['wrangler'])] if settings.get('wrangler') else []
    candidates.extend(directory / 'node_modules/wrangler/bin/wrangler.js' for directory in (ROOT, ROOT.parent))
    for candidate in candidates:
        if candidate.is_file():
            return [node, str(candidate.resolve())]
    raise ValueError('Missing Wrangler. Run npm install --prefix "' + str(ROOT) + '" wrangler, or configure its JS entry point.')


def run(command, work, log=None, capture=False):
    env = dict(os.environ, WRANGLER_LOG_PATH=str(work / 'wrangler.log'))
    if log:
        with log.open('w', encoding='utf-8') as stream:
            result = subprocess.run(command, cwd=work, env=env, stdout=stream, stderr=subprocess.STDOUT)
    else:
        result = subprocess.run(command, cwd=work, env=env, stdout=subprocess.PIPE if capture else None,
                                text=True, encoding='utf-8', errors='replace')
    if result.returncode:
        raise RuntimeError(f'{Path(command[0]).name} failed (exit {result.returncode})' + (f'; see {log}' if log else ''))
    return result.stdout if capture else None


def public_exists(url):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, method='HEAD', headers={'User-Agent': USER_AGENT}), timeout=30):
            return True
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise


def prefer_hls(info):
    formats = info.get('formats', [])
    videos = [f for f in formats if str(f.get('protocol', '')).startswith('m3u8')
              and f.get('vcodec') not in (None, 'none') and 0 < (f.get('height') or 0) <= 480]
    audios = [f for f in formats if str(f.get('protocol', '')).startswith('m3u8') and f.get('vcodec') == 'none']
    if videos and audios:
        video = max(videos, key=lambda f: (f.get('height') or 0, f.get('tbr') or 0))
        audio = max(audios, key=lambda f: (f.get('tbr') or f.get('abr') or 0,
                    'high' in str(f.get('format_note', '')).lower()))
        return video['format_id'] + '+' + audio['format_id']
    return 'bv*[height<=480]+ba/b'


def frame_rates(max_fps, source_rate):
    try:
        natural_fps = round(Fraction(source_rate))
        if natural_fps > 0:
            max_fps = min(max_fps, natural_fps)
    except (ValueError, TypeError, ZeroDivisionError):
        pass
    return sorted({max_fps, *(fps for fps in (30, 25, 24, 20, 15, 10, 7, 5, 3, 2, 1)
                              if fps <= max_fps)}, reverse=True)


def package_video(converted, audio_path, output, seconds, fps, max_bytes):
    data, audio = converted.read_bytes(), audio_path.read_bytes()
    if len(data) < 21 or struct.unpack_from('<4sHHBBH', data) != (b'32VD', 143, 52, fps, 1, 21):
        raise ValueError('Invalid converter header')
    size, count, stream_type = struct.unpack_from('<IIB', data, 12)
    if size != len(data) - 21 or stream_type != 12 or len(audio) != seconds * 6000:
        raise ValueError('Invalid stream header or incomplete audio')
    offset, audio_offset, video_count = 21, 0, 0
    packets = []
    for _ in range(count):
        if offset + 5 > len(data):
            raise ValueError('Truncated packet header')
        length, kind = struct.unpack_from('<IB', data, offset)
        payload = data[offset + 5:offset + 5 + length]
        if len(payload) != length or kind not in (0, 1):
            raise ValueError('Invalid video packet')
        if kind == 1:
            payload = audio[audio_offset:audio_offset + length]
            audio_offset += length
            if len(payload) != length:
                raise ValueError('Audio packet extends past recording')
        else:
            video_count += 1
        packets.append((kind, payload))
        offset += 5 + length
    if offset != len(data) or video_count != seconds * fps:
        raise ValueError('Video duration/frame count mismatch')
    while audio_offset < len(audio):
        chunk = audio[audio_offset:audio_offset + 3000]
        packets.append((1, chunk)); audio_offset += len(chunk)
    payload = b''.join(struct.pack('<IB', len(chunk), kind) + chunk for kind, chunk in packets)
    recording = data[:12] + struct.pack('<IIB', len(payload), len(packets), 12) + payload
    if len(recording) > max_bytes:
        raise TooLarge(f'{len(recording):,} bytes exceeds {max_bytes:,}')
    output.write_bytes(recording)
    return dict(bytes=len(recording), sha256=hashlib.sha256(recording).hexdigest(),
                video_frames=video_count, audio_seconds=seconds, fps=fps, columns=143, rows=52)


def verify_download(url, expected):
    digest, length = hashlib.sha256(), 0
    with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': USER_AGENT}), timeout=60) as response:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk); length += len(chunk)
    if length != expected['bytes'] or digest.hexdigest() != expected['sha256']:
        raise RuntimeError('Uploaded video failed checksum verification; local files have been retained.')


def parser():
    result = ArgumentParser(description=__doc__)
    result.add_argument('source', nargs='?', help='YouTube URL or local video file')
    result.add_argument('--name', help='Storage filename, using letters, numbers and hyphens; separate from the display title')
    result.add_argument('--title', help='Explicit display title (up to 40 characters); skips GPT-6 Luna naming')
    result.add_argument('--start', type=float, default=0, help='Start time in seconds')
    result.add_argument('--duration', type=float, help='Convert only this many seconds')
    result.add_argument('--max-fps', type=int, default=30, choices=range(1, 31),
                        help='Maximum frame rate (default: 30; also capped to the source frame rate)')
    result.add_argument('--max-bytes', type=int, default=MAX_BYTES,
                        help='Maximum recording size in bytes (default: 64 MiB minus one byte)')
    result.add_argument('--bucket', default=DEFAULT_BUCKET)
    result.add_argument('--base-url', default=DEFAULT_BASE)
    result.add_argument('--work-dir', type=Path, help='Directory for retained source and conversion files')
    result.add_argument('--no-upload', action='store_true', help='Convert and validate locally only')
    result.add_argument('--overwrite', action='store_true', help='Permit replacing an existing video with the same name')
    result.add_argument('--login', action='store_true', help='Open Cloudflare CLI browser login and exit')
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    settings = config()
    if args.login:
        work = ROOT / 'uploads'; work.mkdir(exist_ok=True)
        run(wrangler_command(settings) + ['login'], work)
        return
    if not args.source:
        raise ValueError('Provide a YouTube URL or local video file.')
    if not math.isfinite(args.start) or args.start < 0 or (args.duration is not None and
            (not math.isfinite(args.duration) or args.duration <= 0)) or args.max_bytes <= 0:
        raise ValueError('Start, duration and byte limit must be valid positive values (start may be zero).')
    base = args.base_url.rstrip('/')
    parsed = urllib.parse.urlsplit(base)
    if parsed.scheme != 'https' or not parsed.netloc or parsed.query or parsed.fragment or parsed.path:
        raise ValueError('--base-url must be an HTTPS origin, without a path or query.')
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,100}', args.bucket):
        raise ValueError('Invalid bucket name')
    local_source = None if args.source.startswith(('https://', 'http://')) else Path(args.source).resolve()
    if local_source is not None and not local_source.is_file():
        raise ValueError(f'Local video does not exist: {local_source}')
    if args.name and not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,100}', args.name):
        raise ValueError('--name accepts lowercase letters, numbers and hyphens only.')
    ffmpeg, ffprobe, converter = (tool(name, settings) for name in ('ffmpeg', 'ffprobe', 'sanjuuni'))
    upload_command = None if args.no_upload else wrangler_command(settings)
    work = (args.work_dir or ROOT / 'uploads' / (datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8])).resolve()
    if work.exists() and any(work.iterdir()):
        raise ValueError('--work-dir must be empty. Choose a new directory to preserve previous results.')
    work.mkdir(parents=True, exist_ok=True)
    print(f'Working files: {work}', flush=True)
    if local_source:
        source = local_source
        info = dict(title=source.stem, id=hashlib.sha256(str(source).encode()).hexdigest()[:8])
    else:
        downloader, node = tool('yt-dlp', settings), tool('node', settings)
        options = [downloader, '--no-playlist', '--no-progress', '--js-runtimes', 'node:' + node]
        print('Reading video information...', flush=True)
        info = json.loads(run(options + ['--dump-single-json', '--skip-download', '--', args.source], work, capture=True))
        if info.get('is_live') or info.get('live_status') == 'is_live':
            raise ValueError('Use a completed video rather than a live stream.')
    print('Naming for the monitor' + ('...' if args.title else ' with GPT-6 Luna...'), flush=True)
    display_title = validate_title(args.title) if args.title is not None else generate_title(info, settings, work)
    print('Display title: ' + display_title, flush=True)
    name = args.name or (slug(info['title']) + '-' + slug(str(info['id'])))[:101].rstrip('-')
    public_url = base + '/videos/' + name + '.32vid'
    if not args.no_upload and public_exists(public_url) and not args.overwrite:
        raise ValueError(f'{name} already exists. Choose another --name, or explicitly use --overwrite.')
    if not local_source:
        print('Downloading: ' + info['title'], flush=True)
        run(options + ['-f', prefer_hls(info), '--merge-output-format', 'mp4',
            '-o', str(work / 'source.%(ext)s'), '--', args.source], work)
        sources = [p for p in work.glob('source.*') if p.suffix.lower() in ('.mp4', '.mkv', '.webm', '.mov')]
        if len(sources) != 1:
            raise ValueError('Could not identify the downloaded video file')
        source = sources[0]
    probe = json.loads(run([ffprobe, '-v', 'error', '-show_format', '-show_streams', '-of', 'json', str(source)], work, capture=True))
    if not any(s['codec_type'] == 'video' for s in probe['streams']):
        raise ValueError('Source has no video stream')
    duration = float(probe['format']['duration']) - args.start
    if args.duration is not None:
        duration = min(duration, args.duration)
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError('Start time is past the end of the video')
    seconds = math.ceil(duration)
    if seconds * 6000 >= args.max_bytes:
        raise ValueError('Audio alone exceeds the download limit. Choose a shorter --duration.')
    inputs = ['-ss', str(args.start), '-t', str(duration), '-i', str(source)]
    has_audio = any(s['codec_type'] == 'audio' for s in probe['streams'])
    audio_inputs = inputs if has_audio else ['-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=mono']
    audio_path = work / 'audio.dfpwm'
    run([ffmpeg, '-y', '-hide_banner', '-loglevel', 'error', *audio_inputs, '-vn', '-af', 'apad', '-t', str(seconds),
        '-ac', '1', '-ar', '48000', '-c:a', 'dfpwm', '-f', 'dfpwm', str(audio_path)], work)
    video_stream = next(s for s in probe['streams'] if s['codec_type'] == 'video')
    candidates = frame_rates(args.max_fps, video_stream.get('avg_frame_rate', '0/0'))
    output = work / (name + '.32vid')
    for fps in candidates:
        print(f'Converting {seconds}s at {fps} FPS...', flush=True)
        ready, converted = work / f'ready-{fps}fps.mp4', work / f'converted-{fps}fps.32vid'
        ready_inputs = inputs if has_audio else [*inputs, '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=mono']
        run([ffmpeg, '-y', '-hide_banner', '-loglevel', 'error', *ready_inputs, '-map', '0:v:0',
            '-map', '0:a:0' if has_audio else '1:a:0', '-vf',
            f'fps={fps},scale=286:156:force_original_aspect_ratio=decrease,pad=286:156:(ow-iw)/2:(oh-ih)/2:black,tpad=stop_mode=clone:stop_duration=1',
            '-af', 'apad', '-t', str(seconds), '-c:v', 'libx264', '-tune', 'zerolatency', '-bf', '0', '-crf', '18',
            '-c:a', 'aac', '-ac', '1', '-ar', '48000', str(ready)], work)
        run([converter, '-3', '-d', '-W', '286', '-H', '156', '--disable-opencl', '-i', str(ready), '-o', str(converted)],
            work, log=work / f'conversion-{fps}fps.log')
        try:
            result = package_video(converted, audio_path, output, seconds, fps, args.max_bytes)
            break
        except TooLarge as error:
            print(str(error) + '; trying a lower frame rate.', flush=True)
    else:
        raise ValueError('Recording still exceeds the limit at 1 FPS. Choose a shorter --duration.')
    manifest = dict(result, title=display_title, original_title=info['title'], source_id=info['id'],
                    naming_model=MODEL if args.title is None else 'manual',
                    source=args.source, file=output.name, url=public_url, uploaded=False)
    (work / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(f'Validated: {result["bytes"]:,} bytes, {result["fps"]} FPS, complete {seconds}s audio.', flush=True)
    if args.no_upload:
        print(f'Converted file: {output}')
        return manifest
    print('Uploading to R2...', flush=True)
    run(upload_command + ['r2', 'object', 'put', args.bucket + '/videos/' + output.name,
        '--file', str(output), '--content-type', 'application/octet-stream',
        '--content-disposition', title_disposition(display_title), '--remote'], work)
    print('Verifying public download...', flush=True)
    verify_download(public_url, result)
    manifest['uploaded'] = True
    (work / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(f'Uploaded and verified: {public_url}\nClick Refresh on your Minecraft monitor.', flush=True)
    return manifest


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
