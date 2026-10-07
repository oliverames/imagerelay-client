#!/usr/bin/env python3
"""Isolated publication ordering tests. External commands are mocked."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import linear_release as lr

spec = importlib.util.spec_from_file_location('publisher', Path(__file__).with_name('publish-release.py'))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PublicationTests(unittest.TestCase):
    def invoke(self, *, version='1.2.3', publish=False, existing=False, fail_upload=False):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            notes = folder / 'Release Notes.md'
            notes.write_text('Reviewed changes')
            arguments = ['--version', version, '--artifacts', directory, '--notes-file', str(notes)]
            if publish:
                arguments.append('--publish')
            commands = []
            def run(args, **kwargs):
                commands.append(args)
                if 'api' in args:
                    return json.dumps([[{'tag_name': 'v' + version}]]) if existing else '[[]]'
                if 'create' in args and fail_upload:
                    raise RuntimeError('Upload failed')
                return ''
            with patch.object(publisher, 'validate_artifacts', return_value=[folder/'app.dmg', folder/'app.dmg.sha256', folder/'appcast.xml']), patch.object(lr, 'source_commit', return_value='a'*40), patch.object(lr, 'run', side_effect=run), patch.object(publisher.reporter, 'main') as report:
                if existing or fail_upload:
                    with self.assertRaises((ValueError, RuntimeError)):
                        publisher.main(arguments)
                    report.assert_not_called()
                else:
                    publisher.main(arguments)
                return commands, list(report.call_args_list)

    def test_default_never_publishes_or_reports(self):
        commands, reports = self.invoke()
        self.assertEqual(commands, [])
        self.assertEqual(reports, [])

    def test_stable_reports_only_after_draft_upload_and_publication(self):
        commands, reports = self.invoke(publish=True)
        self.assertEqual([c[1] for c in commands], ['api', 'release', 'release'])
        self.assertIn('--draft', commands[1])
        self.assertIn('--verify-tag', commands[1])
        self.assertIn('--draft=false', commands[2])
        self.assertIn('--latest=true', commands[2])
        self.assertEqual(len(reports), 1)

    def test_beta_never_moves_the_stable_latest_release(self):
        commands, _ = self.invoke(publish=True, version='1.2.3-beta.1')
        self.assertIn('--prerelease', commands[1])
        self.assertIn('--latest=false', commands[2])

    def test_existing_release_cannot_be_overwritten(self):
        commands, _ = self.invoke(publish=True, existing=True)
        self.assertEqual([c[1] for c in commands], ['api'])

    def test_failed_upload_never_publishes_draft_or_reports(self):
        commands, _ = self.invoke(publish=True, fail_upload=True)
        self.assertFalse(any('edit' in command for command in commands))

    def test_wrong_checksum_stops_before_notarization_or_publication(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(lr, 'run') as command:
            folder = Path(directory)
            (folder/'ImageRelayClient-1.2.3.dmg').write_bytes(b'app')
            (folder/'ImageRelayClient-1.2.3.dmg.sha256').write_text('wrong')
            (folder/'appcast.xml').write_text('<rss/>')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                publisher.validate_artifacts('1.2.3', folder)
            command.assert_not_called()


    def test_empty_notes_block_before_artifact_validation(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(publisher, 'validate_artifacts') as validate:
            notes = Path(directory)/'Notes.md'
            notes.write_text('  \n')
            with self.assertRaisesRegex(ValueError, 'release notes'):
                publisher.main(['--version', '1.2.3', '--artifacts', directory, '--notes-file', str(notes)])
            validate.assert_not_called()

class SignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import subprocess
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.directory = Path(cls.temp.name)
        cls.verifier = cls.directory/'verify'
        cls.generator = cls.directory/'generate'
        fixture = cls.directory/'generate.swift'
        fixture.write_text(r'''import CryptoKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let artifact = Data("fixture artifact".utf8)
let signature = try key.signature(for: artifact).base64EncodedString()
let unsigned = "<rss><channel/></rss>\n"
let feedSignature = try key.signature(for: Data(unsigned.utf8)).base64EncodedString()
let feed = unsigned + "<!-- sparkle-signatures: edSignature: \(feedSignature) length: \(unsigned.utf8.count) -->\n"
try artifact.write(to: root.appendingPathComponent("artifact"))
try Data(feed.utf8).write(to: root.appendingPathComponent("feed.xml"))
let metadata = ["key": key.publicKey.rawRepresentation.base64EncodedString(),
                "wrongKey": Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
                "signature": signature]
try JSONSerialization.data(withJSONObject: metadata).write(to: root.appendingPathComponent("metadata.json"))
''')
        for source, output in [(Path(__file__).with_name('verify_sparkle.swift'), cls.verifier), (fixture, cls.generator)]:
            subprocess.run(['xcrun', 'swiftc', str(source), '-o', str(output)], check=True, capture_output=True)

    def setUp(self):
        import subprocess
        self.fixture = tempfile.TemporaryDirectory(dir=self.directory)
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name)
        subprocess.run([str(self.generator), str(self.root)], check=True, capture_output=True)
        self.metadata = json.loads((self.root/'metadata.json').read_text())

    def verify(self, key=None):
        import subprocess
        return subprocess.run([str(self.verifier), str(self.root/'feed.xml'), key or self.metadata['key'],
                               str(self.root/'artifact'), self.metadata['signature']], capture_output=True).returncode

    def test_valid_fixture_passes_with_public_key_only(self):
        self.assertEqual(self.verify(), 0)

    def test_tampered_feed_rejected(self):
        path=self.root/'feed.xml'
        path.write_text(path.read_text().replace('channel','changed'))
        self.assertNotEqual(self.verify(), 0)

    def test_tampered_artifact_rejected(self):
        (self.root/'artifact').write_bytes(b'tampered artifact')
        self.assertNotEqual(self.verify(), 0)

    def test_wrong_app_trust_anchor_rejected(self):
        self.assertNotEqual(self.verify(self.metadata['wrongKey']), 0)

    def test_unsigned_feed_rejected(self):
        (self.root/'feed.xml').write_text('<rss/>')
        self.assertNotEqual(self.verify(), 0)


if __name__ == '__main__':
    unittest.main()
