#!/usr/bin/env python3
"""Verify standalone recommendation patch hook ABIs against a supplied decrypted executable."""
import argparse
import mmap
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Tools'))
from inspect_recommendations import ObjCImage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    args = parser.parse_args()
    source = (ROOT / 'Tweak/Features/Recommendations/RecommendationHooks.mm').read_text()
    hooks = re.findall(r'YTRCInstall\(@"([^"]+)",\s*\n?\s*@"([^"]+)",\s*\n?\s*"([^"]+)"', source)
    if len(hooks) != 30:
        raise SystemExit(f'Expected 30 hook declarations; found {len(hooks)}')
    names = {cls for cls, _, _ in hooks}
    with args.executable.open('rb') as handle, mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
        image = ObjCImage(data)
        metadata = image.inspect(names)['classes']
        # Resolve inherited selectors using the same instance-method lookup as runtime hooks.
        while True:
            parents = {entry['superclass'] for entry in metadata.values()} - set(metadata) - {'<external>'}
            extra = image.inspect(parents)['classes'] if parents else {}
            if not extra:
                break
            metadata.update(extra)
    errors = []
    normalize = lambda value: re.sub(r'\d+', '', value)
    for cls, selector, expected in hooks:
        current = cls
        found = None
        visited = set()
        while current in metadata and current not in visited:
            visited.add(current)
            found = next((m for m in metadata[current]['instanceMethods'] if m['selector'] == selector), None)
            if found:
                break
            current = metadata[current]['superclass']
        if found is None or normalize(found['types']) != expected:
            errors.append(f'{cls}.{selector}: expected {expected}, found {found}')
    if errors:
        raise SystemExit('\n'.join(errors))
    print(f'Verified {len(hooks)} hook signatures against the executable')


if __name__ == '__main__':
    main()
