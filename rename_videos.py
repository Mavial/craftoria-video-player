"""Give existing R2 videos short GPT-6 Luna titles while retaining their keys and bytes."""
from argparse import ArgumentParser
from datetime import datetime
from pathlib import Path
import hashlib
import json
import re
import urllib.parse
import urllib.request
import uuid

from upload_video import DEFAULT_BASE, DEFAULT_BUCKET, ROOT, USER_AGENT, config, run, verify_download, wrangler_command
from video_titles import MODEL, generate_title, title_disposition


def catalogue(base):
    url, videos, seen = base + '/videos.json', [], set()
    while url:
        if url in seen or urllib.parse.urlsplit(url).netloc != urllib.parse.urlsplit(base).netloc:
            raise ValueError('Unexpected catalogue pagination link')
        seen.add(url)
        with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': USER_AGENT}), timeout=30) as response:
            data = json.load(response)
            if not isinstance(data, list): raise ValueError('Invalid video catalogue')
            videos.extend(data)
            match = re.search(r'<([^>]+)>;\s*rel="next"', response.headers.get('Link', ''))
            url = match[1] if match else None
    return videos


def retained_manifests():
    records = []
    for path in (ROOT / 'uploads').rglob('manifest.json'):
        data = json.loads(path.read_text(encoding='utf-8-sig'))
        if isinstance(data, dict) and isinstance(data.get('file'), str): records.append((path, data))
    return records


def local_recording(video, records):
    filename = urllib.parse.unquote(urllib.parse.urlsplit(video['url']).path.split('/')[-1])
    if '/' in filename or '\\' in filename or not filename.endswith('.32vid'): raise ValueError('Invalid recording key')
    matching = [(path, data) for path, data in records if data.get('file') == filename]
    for path, data in matching:
        source = path.parent / filename
        if source.is_file() and source.stat().st_size == video['size']:
            # Historical quality conversions used title="source". Recover the original
            # metadata from another retained conversion of the same named recording.
            original = next((item for _, item in matching if item.get('title') not in (None, '', 'source')), data)
            title = original.get('original_title') or original.get('title')
            if title in (None, '', 'source'): title = video['title']
            original_url = original.get('source', '')
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(original_url).query) if isinstance(original_url, str) else {}
            info = {'title': title, 'id': original.get('source_id') or query.get('v', [None])[0]}
            return path, data, source, info
    raise ValueError(f'No retained recording matches {filename} ({video["size"]} bytes).')


def verified_original(video, source, manifest):
    sha256, md5 = hashlib.sha256(), hashlib.md5()
    with source.open('rb') as stream:
        while chunk := stream.read(1024 * 1024): sha256.update(chunk); md5.update(chunk)
    checksum = sha256.hexdigest()
    if manifest.get('sha256') != checksum: raise ValueError('Retained recording checksum differs from its manifest.')
    with urllib.request.urlopen(urllib.request.Request(video['url'], method='HEAD', headers={'User-Agent': USER_AGENT}), timeout=30) as response:
        if int(response.headers['Content-Length']) != source.stat().st_size: raise ValueError('Remote size changed.')
        etag = response.headers.get('ETag', '').strip('"')
    expected = {'bytes': source.stat().st_size, 'sha256': checksum}
    if re.fullmatch(r'[0-9a-fA-F]{32}', etag):
        if etag.lower() != md5.hexdigest(): raise ValueError('Remote recording differs from the retained bytes.')
    else:
        verify_download(video['url'], expected)
    return expected


def main(argv=None):
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Upload title metadata; otherwise only save a proposed plan')
    parser.add_argument('--base-url', default=DEFAULT_BASE)
    parser.add_argument('--bucket', default=DEFAULT_BUCKET)
    args = parser.parse_args(argv)
    base = args.base_url.rstrip('/')
    parsed = urllib.parse.urlsplit(base)
    if parsed.scheme != 'https' or not parsed.netloc or parsed.path or parsed.query or parsed.fragment:
        raise ValueError('Base URL must be an HTTPS origin.')
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,100}', args.bucket): raise ValueError('Invalid bucket name')
    work = ROOT / 'uploads' / ('titles-' + datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8])
    work.mkdir(parents=True)
    settings, records, videos = config(), retained_manifests(), catalogue(base)
    plan = []
    for video in videos:
        if not isinstance(video, dict) or not str(video.get('url', '')).startswith(base + '/videos/'):
            raise ValueError('Unexpected video URL in catalogue')
        path, manifest, source, info = local_recording(video, records)
        print('Naming: ' + str(info['title']), flush=True)
        title = generate_title(info, settings, work)
        expected = verified_original(video, source, manifest)
        entry = {'url': video['url'], 'before': video['title'], 'title': title, 'file': source.name,
                 'original_title': info['title'], 'source_id': info.get('id'),
                 'local_file': str(source), 'manifest': str(path), **expected, 'changed': title != video['title'], 'applied': False}
        plan.append(entry)
        print(video['title'] + ' -> ' + title, flush=True)
    plan_path = work / 'title-plan.json'
    plan_path.write_text(json.dumps({'model': MODEL, 'videos': plan}, indent=2) + '\n', encoding='utf-8')
    if not args.apply:
        print(f'Plan saved: {plan_path}\nUse --apply to update titles. No remote files changed.')
        return plan
    command = wrangler_command(settings)
    for entry in plan:
        if entry['changed']:
            manifest_path = Path(entry['manifest'])
            manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
            verified_original({'url': entry['url']}, Path(entry['local_file']), manifest)
            run(command + ['r2', 'object', 'put', args.bucket + '/videos/' + entry['file'],
                '--file', entry['local_file'], '--content-type', 'application/octet-stream',
                '--content-disposition', title_disposition(entry['title']), '--remote'], work)
            verify_download(entry['url'], entry)
            manifest['original_title'] = entry['original_title']
            manifest['title'], manifest['naming_model'] = entry['title'], MODEL
            manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        entry['applied'] = True
        plan_path.write_text(json.dumps({'model': MODEL, 'videos': plan}, indent=2) + '\n', encoding='utf-8')
    actual = {video['url']: video for video in catalogue(base)}
    for entry in plan:
        if actual.get(entry['url'], {}).get('title') != entry['title'] or actual[entry['url']]['size'] != entry['bytes']:
            raise RuntimeError('Published title or recording size does not match the plan.')
    print(f'Titles verified: {len(plan)} recordings. URLs unchanged. Click Refresh in Minecraft.\nRecord: {plan_path}')
    return plan


if __name__ == '__main__':
    main()
