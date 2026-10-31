#!/usr/bin/env bash
# Check, or refresh, the vendored Framebriar Swift SDK in Vendor/Framebriar.
#
#   scripts/verify-framebriar-vendor.sh                          # check every file against SOURCE.json
#   scripts/verify-framebriar-vendor.sh --refresh <tag>          # re-vendor adapters/swift at a framebriar tag
#   scripts/verify-framebriar-vendor.sh --refresh <tag> --from <framebriar checkout>
#
# The check fails if a file's SHA-256 differs from SOURCE.json, if a listed file is missing, or if
# a file is present that SOURCE.json doesn't list. Untracked files count unless git ignores them, so
# a stray local copy is caught before it is committed. SOURCE.json itself is not listed.
#
# Refresh replaces the whole directory with framebriar's adapters/swift at <tag> (never a partial
# copy), then rewrites SOURCE.json with the tag, its commit and every file's hash. Without --from it
# clones SOURCE.json's repository; set FRAMEBRIAR_REPO to use another URL. It never pushes or tags.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

DEST="Vendor/Framebriar"
SUBDIR="adapters/swift"
REFRESH=""
FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --refresh) REFRESH="${2:?--refresh needs a tag}"; shift ;;
    --from) FROM="${2:?--from needs a framebriar checkout}"; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$REFRESH" ]; then
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  if [ -n "$FROM" ]; then
    SRC="$(cd "$FROM" && pwd)"
  else
    REPO="${FRAMEBRIAR_REPO:-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repository"])' "$DEST/SOURCE.json")}"
    git clone --quiet --filter=blob:none --no-checkout "$REPO" "$WORK/repo"
    SRC="$WORK/repo"
  fi
  # A tag must name a commit; refuse branches so the pin is immutable.
  git -C "$SRC" rev-parse --verify --quiet "refs/tags/$REFRESH" >/dev/null \
    || { echo "No tag $REFRESH in $SRC (run git fetch --tags there)." >&2; exit 1; }
  COMMIT="$(git -C "$SRC" rev-parse "refs/tags/$REFRESH^{commit}")"
  REPOSITORY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repository"])' "$DEST/SOURCE.json")"
  mkdir -p "$WORK/tree"
  git -C "$SRC" archive "$COMMIT" "$SUBDIR" | tar -x -C "$WORK/tree"
  [ -f "$WORK/tree/$SUBDIR/Package.swift" ] || { echo "$REFRESH has no $SUBDIR/Package.swift." >&2; exit 1; }
  rm -rf "$DEST"
  mkdir -p "$(dirname "$DEST")"
  mv "$WORK/tree/$SUBDIR" "$DEST"
  python3 - "$DEST" "$REPOSITORY" "$COMMIT" "$REFRESH" "$SUBDIR" <<'PY'
import hashlib, json, os, sys

dest, repository, commit, tag, subdir = sys.argv[1:]
files = {}
for root, dirs, names in os.walk(dest):
    for name in names:
        path = os.path.join(root, name)
        rel = os.path.relpath(path, dest)
        if rel != "SOURCE.json":
            files[rel] = hashlib.sha256(open(path, "rb").read()).hexdigest()
source = {"repository": repository, "tag": tag, "commit": commit, "subdirectory": subdir,
          "files": dict(sorted(files.items()))}
with open(os.path.join(dest, "SOURCE.json"), "w") as out:
    json.dump(source, out, indent=2)
    out.write("\n")
print(f"Vendored {len(files)} files from {tag} ({commit[:7]}).")
PY
fi

# Tracked files plus untracked ones git doesn't ignore (.build/, .swiftpm/ and .DS_Store are ignored).
python3 - "$DEST" <<'PY'
import hashlib, json, os, subprocess, sys

dest = sys.argv[1]
source = json.load(open(os.path.join(dest, "SOURCE.json")))
expected = source["files"]
listed = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", dest],
                        check=True, capture_output=True).stdout.decode().split("\0")
present = {os.path.relpath(p, dest) for p in listed if p and os.path.isfile(p)}
present.discard("SOURCE.json")
problems = []
for rel in sorted(set(expected) - present):
    problems.append(f"missing   {rel}")
for rel in sorted(present - set(expected)):
    problems.append(f"added     {rel}")
for rel in sorted(present & set(expected)):
    digest = hashlib.sha256(open(os.path.join(dest, rel), "rb").read()).hexdigest()
    if digest != expected[rel]:
        problems.append(f"changed   {rel}")
label = f"{source.get('tag', '')} {source['commit'][:7]}".strip()
if problems:
    print(f"{dest} does not match SOURCE.json ({label}):", file=sys.stderr)
    for line in problems:
        print(f"  {line}", file=sys.stderr)
    print("Vendor the upstream directory unchanged: scripts/verify-framebriar-vendor.sh --refresh <tag>", file=sys.stderr)
    sys.exit(1)
print(f"{dest}: {len(expected)} files match SOURCE.json ({label}).")
PY
