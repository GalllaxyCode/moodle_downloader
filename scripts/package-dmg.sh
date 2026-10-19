#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="Moodle Downloader"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"

"$ROOT_DIR/scripts/build-app.sh"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
ARCH="$(/usr/bin/lipo -archs "$APP_DIR/Contents/MacOS/MoodleDownloader")"
DMG_NAME="Moodle-Downloader-$VERSION-macOS-$ARCH.dmg"
DMG_PATH="$ROOT_DIR/dist/$DMG_NAME"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/dist/.dmg-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

/usr/bin/ditto "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
cp "$ROOT_DIR/Resources/INSTALL.txt" "$STAGING_DIR/INSTALL.txt"
/usr/bin/hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" \
  -format UDZO -ov -o "$DMG_PATH"
/usr/bin/hdiutil verify "$DMG_PATH"
cd "$ROOT_DIR/dist"
/usr/bin/shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
echo "$DMG_PATH"
