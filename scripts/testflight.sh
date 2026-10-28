#!/usr/bin/env bash
# Archive Clubhouse Go for App Store Connect and, with --upload, send it to TestFlight.
#
#   scripts/testflight.sh            # archive + export an .ipa to build/testflight/
#   scripts/testflight.sh --upload   # archive + upload to App Store Connect
#
# The build number is the commit count of HEAD, so every upload from a later commit is higher.
# The marketing version comes from the project (MARKETING_VERSION). See docs/testflight.md.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

UPLOAD=0
ALLOW_UNTAGGED=0
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=1 ;;
    --allow-untagged) ALLOW_UNTAGGED=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

PROJECT=Annex/Annex.xcodeproj
SCHEME=ClubhouseGo
TEAM_ID=4Z8XC9T77W

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "Commit or stash tracked changes first: the archive must match a commit." >&2
  exit 1
fi

TAG=$(git describe --tags --exact-match HEAD 2>/dev/null || true)
if [ -z "$TAG" ] && [ "$ALLOW_UNTAGGED" -ne 1 ]; then
  echo "HEAD has no release tag (e.g. v2.0.0-beta.1). Tag it first, or pass --allow-untagged." >&2
  exit 1
fi

VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION = / { print $2; exit }')
BUILD=$(git rev-list --count HEAD)
OUT="build/testflight/${VERSION}-${BUILD}"
ARCHIVE="$OUT/ClubhouseGo.xcarchive"

echo "Clubhouse Go ${VERSION} (${BUILD}) from $(git rev-parse --short HEAD)${TAG:+ [$TAG]}"
rm -rf "$OUT" && mkdir -p "$OUT"

xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD" \
  -quiet

PLIST="$ARCHIVE/Products/Applications/ClubhouseGo.app/Info.plist"
echo "Archived $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST"))"

DESTINATION=export
[ "$UPLOAD" -eq 1 ] && DESTINATION=upload
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>${DESTINATION}</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" \
  -allowProvisioningUpdates

if [ "$UPLOAD" -eq 1 ]; then
  echo "Uploaded ${VERSION} (${BUILD}) to App Store Connect. It appears in TestFlight after processing."
else
  echo "Exported to $OUT/export. Re-run with --upload to send it to App Store Connect."
fi
