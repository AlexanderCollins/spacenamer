#!/usr/bin/env bash
# Builds SpaceNamer.app (universal: Apple silicon + Intel) into ./build.
#
#   scripts/build-app.sh                 release build, signed
#   CONFIGURATION=debug scripts/build-app.sh
#   ARCHS="arm64" scripts/build-app.sh   single architecture (faster)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# Signing: uses $SIGN_IDENTITY if set, else the local identity made by
# scripts/setup-signing.sh if present, else ad-hoc. A stable identity matters:
# macOS ties the Accessibility permission to the signature, so with ad-hoc signing
# you have to grant it again after every rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="SpaceNamer"
CONFIGURATION="${CONFIGURATION:-release}"
ARCHS="${ARCHS:-arm64 x86_64}"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
DEPLOYMENT_TARGET="13.0"

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
SIGNING_DIR="$ROOT/.signing"
SIGNING_KEYCHAIN="$SIGNING_DIR/spacenamer-signing.keychain-db"
SIGNING_NAME="SpaceNamer Local Signing"

binaries=()
helpers=()
for arch in $ARCHS; do
  echo "› Building $CONFIGURATION for $arch"
  for product in "$APP_NAME" SpaceNamerAgent; do
    swift build \
      --configuration "$CONFIGURATION" \
      --triple "$arch-apple-macosx$DEPLOYMENT_TARGET" \
      --product "$product" >/dev/null
  done
  bin_path="$(swift build --configuration "$CONFIGURATION" --triple "$arch-apple-macosx$DEPLOYMENT_TARGET" --show-bin-path)"
  binaries+=("$bin_path/$APP_NAME")
  helpers+=("$bin_path/SpaceNamerAgent")
done

echo "› Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
# The command-line helper for agents (Claude Code plugin, MCP server, scripts).
HELPER="$APP/Contents/Helpers/spacenamer"
if [ "${#binaries[@]}" -gt 1 ]; then
  lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
  lipo -create "${helpers[@]}" -output "$HELPER"
else
  cp "${binaries[0]}" "$APP/Contents/MacOS/$APP_NAME"
  cp "${helpers[0]}" "$HELPER"
fi
sed -e "s/\$(VERSION)/$VERSION/" -e "s/\$(BUILD)/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
# What the update check compares with GitHub, and where it runs `git pull && make install`.
if COMMIT="$(git rev-parse HEAD 2>/dev/null)"; then
  /usr/libexec/PlistBuddy -c "Add :SpaceNamerCommit string $COMMIT" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SpaceNamerSource string $ROOT" "$APP/Contents/Info.plist"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

sign_args=(--force --options runtime --timestamp=none)
# Nested code first: the helper, then the app around it.
sign() {
  codesign "${sign_args[@]}" --sign "$1" "$HELPER"
  codesign "${sign_args[@]}" --sign "$1" "$APP"
}
if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "› Signing with $SIGN_IDENTITY"
  sign "$SIGN_IDENTITY"
elif [ -f "$SIGNING_KEYCHAIN" ]; then
  echo "› Signing with the local identity ($SIGNING_NAME)"
  # codesign only looks in the search list, so add the signing keychain just for this
  # step and always put the user's list back.
  original_keychains=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%\"}"
    original_keychains+=("${line#\"}")
  done < <(security list-keychains -d user)
  restore_keychains() { security list-keychains -d user -s "${original_keychains[@]}"; }
  trap restore_keychains EXIT
  security unlock-keychain -p "spacenamer" "$SIGNING_KEYCHAIN"
  security list-keychains -d user -s "${original_keychains[@]}" "$SIGNING_KEYCHAIN"
  sign "$SIGNING_NAME"
  restore_keychains
  trap - EXIT
else
  echo "› Signing ad-hoc (run scripts/setup-signing.sh to keep permissions across rebuilds)"
  sign -
fi

codesign --verify --strict "$APP"
echo "✓ $APP ($VERSION, build $BUILD, $(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"
