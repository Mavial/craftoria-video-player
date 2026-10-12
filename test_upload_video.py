"""Verify packet integrity, upload failure handling, and fallback selection."""
import hashlib
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import json
from unittest.mock import patch
import urllib.error

spec = importlib.util.spec_from_file_location('upload_video', Path(__file__).with_name('upload_video.py'))
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)
TEST_TMP = Path(__file__).resolve().parent / 'uploads' / 'test-tmp'
TEST_TMP.mkdir(parents=True, exist_ok=True)


class UploadTests(unittest.TestCase):
    def test_uploader_generates_display_metadata_preserves_storage_name_and_allows_manual_title(self):
        for explicit in (False, True):
            with tempfile.TemporaryDirectory(dir=TEST_TMP) as directory:
                root = Path(directory); source = root / 'source.mp4'; source.write_bytes(b'original')
                work = root / 'work'
                uploads = []
                def command_run(command, current_work, **kwargs):
                    if command[0] == 'ffprobe':
                        return json.dumps({'format': {'duration': '1'}, 'streams': [
                            {'codec_type': 'video', 'avg_frame_rate': '30/1'}, {'codec_type': 'audio'}]})
                    if command[0] == 'ffmpeg':
                        Path(command[-1]).write_bytes(b'\0' * 6000 if command[-1].endswith('.dfpwm') else b'mp4')
                    elif command[0] == 'sanjuuni':
                        packet = struct.pack('<IB', 2, 0) + b'v0'
                        Path(command[-1]).write_bytes(struct.pack('<4sHHBBHIIB', b'32VD', 143, 52, 1, 1, 21, len(packet), 1, 12) + packet)
                    elif command[0] == 'node': uploads.append(command)
                args = [str(source), '--name', 'unique-name', '--max-fps', '1', '--work-dir', str(work)]
                if explicit: args += ['--title', "My Natural Title"]
                with patch.object(upload, 'config', return_value={}), patch.object(upload, 'tool', side_effect=lambda name, _: name), \
                     patch.object(upload, 'wrangler_command', return_value=['node', 'wrangler']), \
                     patch.object(upload, 'public_exists', return_value=False), patch.object(upload, 'run', side_effect=command_run), \
                     patch.object(upload, 'verify_download'), patch.object(upload, 'generate_title', return_value='Natural AI Title') as naming:
                    result = upload.main(args)
                expected_title = 'My Natural Title' if explicit else 'Natural AI Title'
                self.assertEqual(result['title'], expected_title)
                self.assertEqual(result['original_title'], 'source')
                self.assertEqual(result['file'], 'unique-name.32vid')
                self.assertTrue(result['uploaded'])
                self.assertEqual(naming.call_count, 0 if explicit else 1)
                self.assertEqual(uploads[0][uploads[0].index('--content-disposition') + 1], upload.title_disposition(expected_title))
                self.assertEqual(json.loads((work / 'manifest.json').read_text())['title'], expected_title)

    def test_frame_rates_respect_source_and_fall_back_within_requested_cap(self):
        self.assertEqual(upload.frame_rates(30, '25/1'), [25, 24, 20, 15, 10, 7, 5, 3, 2, 1])
        self.assertEqual(upload.frame_rates(30, '30000/1001')[0], 30)
        self.assertEqual(upload.frame_rates(7, '60/1'), [7, 5, 3, 2, 1])
        self.assertEqual(upload.frame_rates(30, '0/0')[0], 30)

    def test_hls_selection_and_normal_format_fallback(self):
        formats = [dict(format_id='231', protocol='m3u8_native', vcodec='h264', height=480),
                   dict(format_id='232', protocol='m3u8_native', vcodec='h264', height=720),
                   dict(format_id='234', protocol='m3u8_native', vcodec='none', tbr=128)]
        self.assertEqual(upload.prefer_hls({'formats': formats}), '231+234')
        self.assertEqual(upload.prefer_hls({}), 'bv*[height<=480]+ba/b')
        formats[-1].pop('tbr')
        formats[-1]['format_note'] = 'Default, high'
        formats.insert(-1, dict(format_id='233', protocol='m3u8_native', vcodec='none', format_note='Default, low'))
        self.assertEqual(upload.prefer_hls({'formats': formats}), '231+234')

    def test_packaging_keeps_all_audio_and_rejects_truncated_or_oversized_files(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP) as directory:
            root = Path(directory)
            self.assertEqual(root.resolve().parent, TEST_TMP.resolve())
            # The converter left only one audio packet; the complete stream must be restored.
            audio = bytes(range(256)) * 23 + bytes(range(112))
            self.assertEqual(len(audio), 6000)
            (root / 'audio').write_bytes(audio)
            payload = struct.pack('<IB', 2, 0) + b'v0' + struct.pack('<IB', 3, 1) + b'bad'
            header = struct.pack('<4sHHBBHIIB', b'32VD', 143, 52, 1, 1, 21, len(payload), 2, 12)
            source = header + payload
            (root / 'input').write_bytes(source)
            result = upload.package_video(root/'input', root/'audio', root/'output', 1, 1, 20000)
            data = (root/'output').read_bytes()
            count = struct.unpack_from('<I', data, 16)[0]
            pos, restored = 21, b''
            for _ in range(count):
                length, kind = struct.unpack_from('<IB', data, pos)
                if kind == 1: restored += data[pos+5:pos+5+length]
                pos += 5 + length
            self.assertEqual(restored, audio)
            self.assertEqual(result['sha256'], hashlib.sha256(data).hexdigest())
            with self.assertRaises(upload.TooLarge):
                upload.package_video(root/'input', root/'audio', root/'small', 1, 1, 6000)
            (root/'input').write_bytes(source[:-1])
            with self.assertRaises(ValueError):
                upload.package_video(root/'input', root/'audio', root/'broken', 1, 1, 20000)

    def test_existing_check_only_treats_404_as_absent(self):
        with patch.object(upload.urllib.request, 'urlopen', side_effect=urllib.error.HTTPError('url',404,'missing',{},None)):
            self.assertFalse(upload.public_exists('https://example.invalid/video'))
        with patch.object(upload.urllib.request, 'urlopen', side_effect=urllib.error.HTTPError('url',503,'error',{},None)):
            with self.assertRaises(urllib.error.HTTPError):
                upload.public_exists('https://example.invalid/video')

    def test_download_mismatch_is_an_error(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, _): return b''
        with patch.object(upload.urllib.request, 'urlopen', return_value=Response()):
            with self.assertRaises(RuntimeError):
                upload.verify_download('https://example.invalid/video', {'bytes':1,'sha256':'bad'})

    def test_validations_and_nonempty_work_directory(self):
        with self.assertRaises(ValueError): upload.main(['x', '--name', '../other'])
        with self.assertRaises(ValueError): upload.main(['x', '--duration', 'nan'])
        with tempfile.TemporaryDirectory(dir=TEST_TMP) as directory:
            root = Path(directory); source = root/'source.mp4'; source.write_bytes(b'original')
            self.assertEqual(root.resolve().parent, TEST_TMP.resolve())
            with patch.object(upload, 'tool', return_value='tool'):
                with self.assertRaises(ValueError):
                    upload.main([str(source), '--no-upload', '--work-dir', str(root)])
            self.assertEqual(source.read_bytes(), b'original')


if __name__ == '__main__':
    unittest.main()
