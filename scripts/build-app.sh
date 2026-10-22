#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="Moodle Downloader"
BUILD_DIR="$ROOT_DIR/.build/release"
OUTPUT_APP="$ROOT_DIR/dist/$APP_NAME.app"

cd "$ROOT_DIR"
# Command Line Tools ship the macOS 27 SDK without SwiftUIMacros; fall back to macOS 26.
DEVELOPER_DIR="$(xcode-select -p)"
if [[ -z "${SDKROOT:-}" && -d "$DEVELOPER_DIR/SDKs/MacOSX26.sdk" \
   && ! -e "$DEVELOPER_DIR/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
  export SDKROOT="$DEVELOPER_DIR/SDKs/MacOSX26.sdk"
fi
swift build -c release
mkdir -p "$ROOT_DIR/dist"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/dist/.app-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/$APP_NAME.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/MoodleDownloader" "$APP_DIR/Contents/MacOS/MoodleDownloader"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
xattr -cr "$APP_DIR"
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

# Preserve the old executable when a previous build is still running.
if [[ -e "$OUTPUT_APP" ]]; then
  BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp/}moodle-downloader-previous.XXXXXX")"
  mv "$OUTPUT_APP" "$BACKUP_DIR/$APP_NAME.app"
fi
if ! mv "$APP_DIR" "$OUTPUT_APP"; then
  if [[ -n "${BACKUP_DIR:-}" ]]; then
    mv "$BACKUP_DIR/$APP_NAME.app" "$OUTPUT_APP"
  fi
  exit 1
fi
echo "$OUTPUT_APP"
