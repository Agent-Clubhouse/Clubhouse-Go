"""Read narrow ownership surfaces using the SwiftParser bundled with Xcode."""
import hashlib
import json
import pathlib
import subprocess


def extract(root, sources):
    root = pathlib.Path(root)
    swift = pathlib.Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip())
    host = swift.parent.parent / 'lib/swift/host'
    source = root / 'scripts/isolated-deinit-surface.swift'
    version = subprocess.check_output(['xcrun', 'swiftc', '--version'], stderr=subprocess.STDOUT)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    key = hashlib.sha256(source.read_bytes() + version).hexdigest()[:16]
    binary = root / f'build/isolated-deinit-tools/surface-{key}'
    if not binary.exists():
        binary.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-I', str(host), '-L', str(host), '-Xlinker', '-rpath', '-Xlinker', str(host), str(source), '-o', str(binary)], check=True)
    paths = sorted(str(root / p) for p in sources)
    raw = json.loads(subprocess.check_output([str(binary), *paths]))
    return {str(pathlib.Path(p).relative_to(root)): value for p, value in raw.items()}


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='Show review inputs without updating ownership approvals')
    choice = parser.add_mutually_exclusive_group(required=True)
    choice.add_argument('--class', dest='class_name')
    choice.add_argument('--captures', metavar='SOURCE_PATH')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    data = extract(root, [str(p.relative_to(root)) for p in (root / 'Annex/Annex').rglob('*.swift')])
    if args.class_name:
        matches = {p: d['classes'][args.class_name] for p, d in data.items() if args.class_name in d['classes']}
        if not matches:
            parser.error('No class with that qualified name in Annex/Annex')
        print(json.dumps(matches, indent=2))
    else:
        if args.captures not in data:
            parser.error('Expected a Swift source path under Annex/Annex')
        print(json.dumps(data[args.captures]['captureSites'], indent=2))
