#!/usr/bin/env python3
"""Raise the pubspec build number so an APK/installer upgrades in place.

Android compares versionCode, and the installer compares the version it
finds in the bundle, so a build that reuses the checked-in number either
looks identical or looks older than what is installed. The checked-in number
is large (date based), so the CI run number is added to it rather than
replacing it: the result only grows across runs.
"""

import os
import pathlib
import re
import sys

# Bumped for every artifact published from this workflow, so two builds in the
# same run cannot collide either.
_EXTRA = 0

_pattern = re.compile(r'(?m)^version:\s*([^\s+]+)(?:\+(\d+))?\s*$')


def main() -> int:
    bump = int(os.environ.get('VERSION_BUMP') or 0)
    pubspec = pathlib.Path('pubspec.yaml')
    text = pubspec.read_text(encoding='utf-8')

    def replace(match: re.Match[str]) -> str:
        name = match.group(1)
        current = int(match.group(2) or 0)
        return f'version: {name}+{current + bump + _EXTRA}'

    updated, count = _pattern.subn(replace, text, count=1)
    if count != 1:
        print('no version line in pubspec.yaml', file=sys.stderr)
        return 1

    pubspec.write_text(updated, encoding='utf-8')
    print(next(line for line in updated.splitlines() if line.startswith('version:')))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
