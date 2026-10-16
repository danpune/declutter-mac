#!/bin/zsh
# Builds DeClutter.app with only the Xcode Command Line Tools.
#   ./build.sh            build into build/
#   ./build.sh install    build, copy to /Applications and open it
#   ./build.sh release    build and zip it for GitHub Releases (build/DeClutter-mac.zip)
set -euo pipefail
cd "${0:A:h}"

NAME="DeClutter"
VERSION="1.1"
BUILD_NUMBER="2"
MIN_OS="14.0"
APP="build/$NAME.app"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset
for arch in arm64 x86_64; do   # universal: Apple silicon and Intel
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos$MIN_OS" DeClutter.swift -o "build/$NAME-$arch"
done
lipo -create "build/$NAME-arm64" "build/$NAME-x86_64" -output "$APP/Contents/MacOS/$NAME"

swift icon.swift build/icon.png
for px in 16 32 128 256 512; do
  sips -z $px $px build/icon.png --out "build/AppIcon.iconset/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) build/icon.png --out "build/AppIcon.iconset/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>io.github.danpune.declutter</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# Signed with a certificate that exists only on this Mac, kept in its own keychain under ~/.config/declutter (made on
# the first build), so every build has the same identity and macOS keeps DeClutter's Accessibility permission. An ad-hoc
# signature would look like a new app each time. Sharing it with others still needs a Developer ID + notarization.
SIGN_DIR=~/.config/declutter
KEYCHAIN=$SIGN_DIR/signing.keychain-db
IDENTITY="DeClutter Local Signing"
if [[ ! -f $KEYCHAIN ]]; then
  echo "Creating DeClutter's local signing certificate (once)"
  mkdir -p $SIGN_DIR && chmod 700 $SIGN_DIR
  (umask 077; openssl rand -hex 24 > $SIGN_DIR/keychain-password)
  tmp=$(mktemp -d)
  printf '%s\n' '[req]' 'distinguished_name = dn' 'x509_extensions = ext' 'prompt = no' '[dn]' "CN = $IDENTITY" \
    '[ext]' 'basicConstraints = critical, CA:false' 'keyUsage = critical, digitalSignature' \
    'extendedKeyUsage = critical, codeSigning' > $tmp/cert.cnf
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config $tmp/cert.cnf -keyout $tmp/key.pem -out $tmp/cert.pem 2>/dev/null
  openssl pkcs12 -export -inkey $tmp/key.pem -in $tmp/cert.pem -name "$IDENTITY" -passout pass:import -out $tmp/id.p12
  security create-keychain -p "$(<$SIGN_DIR/keychain-password)" $KEYCHAIN   # not added to the keychain search list
  security import $tmp/id.p12 -k $KEYCHAIN -P import -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(<$SIGN_DIR/keychain-password)" $KEYCHAIN >/dev/null
  rm -rf $tmp
fi
security unlock-keychain -p "$(<$SIGN_DIR/keychain-password)" $KEYCHAIN
codesign --force --keychain $KEYCHAIN --sign "$IDENTITY" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "release" ]]; then
  ditto -c -k --keepParent "$APP" build/DeClutter-mac.zip
  shasum -a 256 build/DeClutter-mac.zip
fi

if [[ "${1:-}" == "install" ]]; then
  pkill -x "$NAME" 2>/dev/null || true
  for _ in {1..50}; do pgrep -x "$NAME" >/dev/null || break; sleep 0.1; done
  rm -rf "/Applications/$NAME.app"
  cp -R "$APP" /Applications/
  # LaunchServices sometimes refuses (-600) right after the old copy quits; one retry is enough.
  open "/Applications/$NAME.app" 2>/dev/null || { sleep 1; open "/Applications/$NAME.app"; }
  echo "Installed to /Applications and opened"
fi
