"""Read narrow ownership surfaces using the SwiftParser bundled with Xcode."""
import hashlib
from functools import lru_cache
import json
import os
import pathlib
import subprocess


@lru_cache(maxsize=8)
def _compiler_version(compiler, identity, selection):
    """Cache metadata within this process, not source surfaces or scanner output.

    identity and selection participate in the key: replacing the selected file
    or changing selection environment must not borrow the old compiler version.
    Run the resolved tool itself so a later xcode-select change cannot select a
    different compiler for this version request.
    """
    return subprocess.check_output([compiler, '--version'], stderr=subprocess.STDOUT)


def extract(root, sources):
    root = pathlib.Path(root)
    swift = pathlib.Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip())
    stat = swift.stat()
    identity = (str(swift.resolve()), stat.st_dev, stat.st_ino, stat.st_size,
                stat.st_mtime_ns, stat.st_ctime_ns, stat.st_mode)
    selection = tuple(os.environ.get(key) for key in ('DEVELOPER_DIR', 'SDKROOT', 'TOOLCHAINS', 'PATH'))
    host = swift.parent.parent / 'lib/swift/host'
    source = root / 'scripts/isolated-deinit-surface.swift'
    version = _compiler_version(str(swift), identity, selection)
    context = json.dumps((str(swift), identity, selection), separators=(',', ':')).encode()
    key = hashlib.sha256(source.read_bytes() + version + context).hexdigest()[:16]
    binary = root / f'build/isolated-deinit-tools/surface-{key}'
    if not binary.exists():
        binary.parent.mkdir(parents=True, exist_ok=True)
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        subprocess.run([str(swift), '-sdk', sdk, '-I', str(host), '-L', str(host), '-Xlinker', '-rpath', '-Xlinker', str(host), str(source), '-o', str(binary)], check=True)
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
