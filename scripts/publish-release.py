#!/usr/bin/env python3
"""Publish already prepared Image Relay artifacts, verify delivery, then report Linear.

Default is local validation only. --publish is the explicit publication step.
For an already published release, use report_linear_release.py instead.
"""
import argparse
import json
import plistlib
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

import linear_release as lr
import report_linear_release as reporter


def publisher_root():
    return Path(__file__).resolve().parent.parent


def validate_artifacts(version, directory):
    name = f'ImageRelayClient-{version}.dmg'
    paths = [directory / name, directory / (name + '.sha256'), directory / 'appcast.xml']
    if not all(path.is_file() for path in paths):
        raise ValueError('DMG, SHA-256 file, and appcast are required')
    if paths[1].read_text().split()[0] != lr.digest(paths[0]):
        raise ValueError('DMG checksum is incorrect')
    enclosure = ET.parse(paths[2]).find('channel/item/enclosure')
    version_in_feed = ET.parse(paths[2]).findtext('channel/item/' + lr.SPARKLE + 'shortVersionString')
    expected_url = f'https://github.com/oliverames/imagerelay-client/releases/download/v{version}/{name}'
    if (enclosure is None or version_in_feed != version or enclosure.get('url') != expected_url
            or not enclosure.get(lr.SPARKLE + 'edSignature')
            or int(enclosure.get('length', '-1')) != paths[0].stat().st_size):
        raise ValueError('Appcast does not describe the requested signed artifact')
    public_key = plistlib.loads((publisher_root() / 'ImageRelayClient/Info.plist').read_bytes())['SUPublicEDKey']
    lr.run(['xcrun', 'swift', publisher_root() / 'scripts/verify_sparkle.swift',
            paths[2], public_key, paths[0], enclosure.get(lr.SPARKLE + 'edSignature')])
    lr.run(['xcrun', 'stapler', 'validate', paths[0]])
    return paths


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--artifacts', required=True, type=Path)
    parser.add_argument('--notes-file', required=True, type=Path)
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args(argv)
    lr.validate_version(args.version)
    if not args.notes_file.is_file() or not args.notes_file.read_text().strip():
        raise ValueError('Reviewed release notes file is required')
    paths = validate_artifacts(args.version, args.artifacts)
    if not args.publish:
        print('Local validation passed. Add --publish after committing and pushing the built source tag.')
        return
    # Only an already pushed release tag may identify the prepared build.
    sha = lr.source_commit(reporter.ROOT, reporter.REPO, args.version)
    existing = json.loads(lr.run(['gh', 'api', 'repos/oliverames/imagerelay-client/releases', '--paginate', '--slurp']))
    if any(release.get('tag_name') == 'v' + args.version for page in existing for release in page):
        raise ValueError('Release already exists. Finish any draft manually, then use report_linear_release.py only')
    beta = '-' in args.version
    lr.run(['gh', 'release', 'create', 'v' + args.version, *paths,
            '--repo', 'oliverames/imagerelay-client', '--verify-tag', '--draft',
            '--title', 'Image Relay ' + args.version, '--notes-file', args.notes_file,
            *(['--prerelease'] if beta else [])])
    lr.run(['gh', 'release', 'edit', 'v' + args.version, '--repo', 'oliverames/imagerelay-client', '--draft=false',
            '--latest=false' if beta else '--latest=true'])
    reporter.main(['--version', args.version, '--artifacts', str(args.artifacts), '--source-ref', sha])


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, OSError, KeyError, IndexError, ET.ParseError, subprocess.TimeoutExpired):
        print('Publication or release reporting failed. Inspect the existing GitHub release before retrying. '
              'If assets are already published, use report_linear_release.py only.', file=sys.stderr)
        sys.exit(1)
