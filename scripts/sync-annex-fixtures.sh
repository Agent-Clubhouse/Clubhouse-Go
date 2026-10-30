#!/usr/bin/env bash
# Vendor the desktop's Annex mobile protocol fixtures into Tests/Fixtures/AnnexContract/.
#
#   scripts/sync-annex-fixtures.sh                    # from desktop main
#   scripts/sync-annex-fixtures.sh --ref <sha|branch> # from another desktop commit
#   scripts/sync-annex-fixtures.sh --from <checkout>  # from a local desktop checkout (its HEAD)
#   scripts/sync-annex-fixtures.sh --check            # exit 1 if desktop main's fixtures differ from ours
#
# The desktop (Agent-Clubhouse/Clubhouse) writes them with `npm run fixtures:annex-mobile` from its real
# annex-server code; see its docs/mobile-control-v1.md#contract-fixtures. SOURCE.json records the commit.
# The contract tests (AnnexContract*Tests) decode every file, so a sync that changes them may need code changes.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

REPO="${ANNEX_DESKTOP_REPO:-https://github.com/Agent-Clubhouse/Clubhouse.git}"
FIXTURES="test/fixtures/annex-mobile"
DEST="Tests/Fixtures/AnnexContract"
REF="main"
FROM=""
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="$2"; shift ;;
    --from) FROM="$2"; shift ;;
    --check) CHECK=1 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -n "$FROM" ]; then
  SRC="$(cd "$FROM" && pwd)"
  COMMIT="$(git -C "$SRC" rev-parse HEAD)"
  SOURCE_REF="$(git -C "$SRC" rev-parse --abbrev-ref HEAD)"
else
  # Only the fixtures directory, at one commit.
  git -C "$WORK" init -q desktop
  SRC="$WORK/desktop"
  git -C "$SRC" remote add origin "$REPO"
  git -C "$SRC" sparse-checkout set --no-cone "/$FIXTURES/"
  git -C "$SRC" fetch -q --depth 1 --filter=blob:none origin "$REF"
  git -C "$SRC" checkout -q FETCH_HEAD
  COMMIT="$(git -C "$SRC" rev-parse HEAD)"
  SOURCE_REF="$REF"
fi

if [ ! -f "$SRC/$FIXTURES/index.json" ]; then
  echo "No $FIXTURES/index.json at $SOURCE_REF ($COMMIT)" >&2
  exit 1
fi

if [ "$CHECK" = 1 ]; then
  # Compare the files only: SOURCE.json names the commit they came from.
  if diff -r -q -x SOURCE.json "$SRC/$FIXTURES" "$DEST" >"$WORK/diff.txt"; then
    echo "Annex contract fixtures match desktop $SOURCE_REF ($COMMIT)."
    exit 0
  fi
  echo "Annex contract fixtures differ from desktop $SOURCE_REF ($COMMIT):"
  sed "s|$SRC/$FIXTURES|desktop|; s|$DEST|vendored|" "$WORK/diff.txt"
  echo "Run scripts/sync-annex-fixtures.sh, then swift test, and commit the result."
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$SRC/$FIXTURES/." "$DEST/"
cat >"$DEST/SOURCE.json" <<EOF
{
  "commit": "$COMMIT",
  "path": "$FIXTURES",
  "ref": "$SOURCE_REF",
  "repository": "Agent-Clubhouse/Clubhouse"
}
EOF
echo "Vendored $(find "$DEST" -name '*.json' ! -name SOURCE.json | wc -l | tr -d ' ') fixtures from desktop $SOURCE_REF ($COMMIT)."
