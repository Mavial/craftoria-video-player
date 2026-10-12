"""Check short title generation, exact Luna selection, metadata and failure handling."""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import video_titles as titles
import rename_videos as rename

TEST_TMP = Path(__file__).resolve().parent / 'uploads' / 'test-tmp'
TEST_TMP.mkdir(parents=True, exist_ok=True)


class TitleTests(unittest.TestCase):
    def test_readable_ascii_title_and_encoded_http_metadata(self):
        self.assertEqual(titles.validate_title('  Michèle Mouton – Rally House  '), 'Michele Mouton - Rally House')
        self.assertEqual(titles.title_disposition("Don't Feel At All"), "inline; filename*=UTF-8''Don%27t%20Feel%20At%20All.32vid")
        for title in ('', 'x' * 41, 'Two\nLines', 'movie.32vid', 'https://example.invalid', 12):
            with self.assertRaises(ValueError): titles.validate_title(title)
        with self.assertRaises(ValueError): titles.validate_title('Crazy Frog k85mrpqvmbe', 'k85mRPqvMbE')

    def test_codex_uses_luna_saved_login_stdin_schema_and_readonly_tools(self):
        def invoke(command, **kwargs):
            self.assertEqual(command[command.index('--model') + 1], 'gpt-6-luna')
            self.assertIn('--ignore-user-config', command)
            self.assertIn('--ephemeral', command)
            self.assertEqual(command[command.index('--sandbox') + 1], 'read-only')
            self.assertIn('features.shell_tool=false', command)
            self.assertEqual(command[-1], '-')
            self.assertNotIn('source title', ' '.join(command))
            self.assertIn('source title', kwargs['input'])
            self.assertEqual(kwargs['timeout'], 90)
            self.assertEqual(json.loads(Path(command[command.index('--output-schema') + 1]).read_text())['required'], ['title'])
            self.assertEqual(json.loads(Path(command[command.index('--output-schema') + 1]).read_text())['properties']['title']['maxLength'], 40)
            Path(command[command.index('--output-last-message') + 1]).write_text(json.dumps({'title': 'Natural Title'}))
            return subprocess.CompletedProcess(command, 0, stdout='{"type":"item.completed","item":{"type":"agent_message"}}', stderr='')
        with tempfile.TemporaryDirectory(dir=TEST_TMP) as directory:
            with patch.object(titles, 'codex_path', return_value='codex.exe'), patch.object(titles.subprocess, 'run', side_effect=invoke):
                self.assertEqual(titles.generate_title({'title': 'source title', 'id': 'abc123xyz99'}, {}, Path(directory)), 'Natural Title')

    def test_generation_rejects_bad_output_errors_timeout_and_unexpected_tools(self):
        for value, code, events in (({'title': 'x' * 41}, 0, ''), ({'title': 'Bad\nTitle'}, 0, ''),
                                   ({'title': 'Title', 'extra': 'field'}, 0, ''), ({'title': 'Title'}, 1, ''),
                                   ({'title': 'Title'}, 0, '{"type":"item.completed","item":{"type":"command_execution"}}')):
            def invoke(command, **kwargs):
                Path(command[command.index('--output-last-message') + 1]).write_text(json.dumps(value))
                return subprocess.CompletedProcess(command, code, stdout=events, stderr='failure' if code else '')
            with tempfile.TemporaryDirectory(dir=TEST_TMP) as directory:
                with patch.object(titles, 'codex_path', return_value='codex.exe'), patch.object(titles.subprocess, 'run', side_effect=invoke):
                    with self.assertRaises((ValueError, RuntimeError)): titles.generate_title({'title': 'Title'}, {}, Path(directory))
        with tempfile.TemporaryDirectory(dir=TEST_TMP) as directory:
            with patch.object(titles, 'codex_path', return_value='codex.exe'), patch.object(titles.subprocess, 'run', side_effect=subprocess.TimeoutExpired('codex', 90)):
                with self.assertRaises(RuntimeError): titles.generate_title({'title': 'Title'}, {}, Path(directory))

    def test_existing_quality_recordings_recover_source_title_from_old_metadata(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP) as directory:
            root = Path(directory)
            (root / 'movie-id.32vid').write_bytes(b'32VD')
            current = {'file': 'movie-id.32vid', 'title': 'source', 'source': 'source.mp4'}
            previous = {'file': 'movie-id.32vid', 'title': 'Real Song (Official Video)', 'source': 'https://www.youtube.com/watch?v=abc123xyz99'}
            _, _, source, info = rename.local_recording({'url': 'https://video.example/videos/movie-id.32vid', 'size': 4},
                [(root / 'manifest.json', current), (root / 'old/manifest.json', previous)])
            self.assertEqual(info, {'title': 'Real Song (Official Video)', 'id': 'abc123xyz99'})
            self.assertEqual(source.read_bytes(), b'32VD')


if __name__ == '__main__': unittest.main()
