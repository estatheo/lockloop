#!/bin/sh
# Builds the app and the CLI in release mode, puts them in build/<Name>.app,
# signs both ad hoc and zips the result. Needs Xcode or its command line tools.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The names live in Sources/AerialKit/Brand.swift. Read them from there so a rename is one edit.
brand() { sed -n "s/.*static let $1 = \"\(.*\)\".*/\1/p" Sources/AerialKit/Brand.swift | head -1; }
NAME="$(brand displayName)"
CLI="$(brand cliName)"
BUNDLE_ID="$(brand bundleID)"
VERSION="$(brand version)"

swift build -c release --product AerialApp
swift build -c release --product "$CLI"
BIN="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/AerialApp" "$APP/Contents/MacOS/$NAME"
cp "$BIN/$CLI" "$APP/Contents/Helpers/$CLI"
sed -e "s/@NAME@/$NAME/g" -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" -e "s/@VERSION@/$VERSION/g" \
    Resources/Info.plist.in > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
cp Resources/Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign the helper first, then the bundle around it. "-" means ad hoc: no Apple ID, not notarised.
codesign --force --options runtime --timestamp=none --identifier "$BUNDLE_ID.cli" --sign - "$APP/Contents/Helpers/$CLI"
codesign --force --options runtime --timestamp=none --sign - "$APP"
codesign --verify --strict --deep "$APP"

rm -f "$ROOT/build/$NAME.zip"
ditto -c -k --keepParent "$APP" "$ROOT/build/$NAME.zip"
echo "Built $APP"
echo "Zipped $ROOT/build/$NAME.zip"
