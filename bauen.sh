#!/bin/sh
# Baut die Lageuhr für Windows (dist/windows/Lageuhr.exe) und macOS (dist/mac/Lageuhr.app + Zip).
# Braucht: dotnet-SDK (für Windows), Xcode-Befehlszeilenwerkzeuge (für macOS), python3.
set -e
cd "$(dirname "$0")"
VERSION=1.4.2

python3 werkzeuge/symbol.py src --gross

# ---------- Windows ----------
if command -v dotnet >/dev/null 2>&1; then
  rm -rf dist/windows
  (cd src && dotnet build -c Release -o ../dist/windows -nologo -v q)
  rm -rf src/bin src/obj
  echo "Windows: dist/windows/Lageuhr.exe"
fi

# ---------- macOS ----------
if command -v swiftc >/dev/null 2>&1; then
  BAU=$(mktemp -d)
  APP=dist/mac/Lageuhr.app
  rm -rf dist/mac && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  for ARCH in arm64 x86_64; do
    swiftc -O -swift-version 5 -target $ARCH-apple-macos13.0 -o "$BAU/Lageuhr-$ARCH" mac/Gemeinsam.swift mac/Lageuhr.swift
    swiftc -O -swift-version 5 -target $ARCH-apple-macos13.0 -emit-library -module-name LageuhrSchoner \
      -o "$BAU/Schoner-$ARCH" mac/Gemeinsam.swift mac/Schoner.swift -framework ScreenSaver
  done
  lipo -create -output "$APP/Contents/MacOS/Lageuhr" "$BAU/Lageuhr-arm64" "$BAU/Lageuhr-x86_64"

  # Bildschirmschoner Lageuhr.saver (liegt in der App; „Als Bildschirmschoner einrichten“ kopiert ihn)
  SAVER="$APP/Contents/Resources/Lageuhr.saver"
  mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
  lipo -create -output "$SAVER/Contents/MacOS/LageuhrSchoner" "$BAU/Schoner-arm64" "$BAU/Schoner-x86_64"
  sips -z 116 180 src/lageuhr.png --out "$SAVER/Contents/Resources/thumbnail@2x.png" >/dev/null 2>&1 || true
  cat > "$SAVER/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Lageuhr</string>
  <key>CFBundleIdentifier</key><string>local.lageuhr.schoner</string>
  <key>CFBundleExecutable</key><string>LageuhrSchoner</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>NSPrincipalClass</key><string>LageuhrSchoner</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
EOF
  codesign --force -s - "$SAVER"

  # Symbol
  SET="$BAU/Lageuhr.iconset" && mkdir -p "$SET"
  for N in 16 32 128 256 512; do
    sips -z $N $N src/lageuhr.png --out "$SET/icon_${N}x${N}.png" >/dev/null
    sips -z $((N*2)) $((N*2)) src/lageuhr.png --out "$SET/icon_${N}x${N}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/Lageuhr.icns"

  cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Lageuhr</string>
  <key>CFBundleDisplayName</key><string>Lageuhr</string>
  <key>CFBundleIdentifier</key><string>local.lageuhr</string>
  <key>CFBundleExecutable</key><string>Lageuhr</string>
  <key>CFBundleIconFile</key><string>Lageuhr</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
</dict>
</plist>
EOF
  codesign --force --deep -s - "$APP"
  (cd dist/mac && ditto -c -k --keepParent Lageuhr.app Lageuhr-mac.zip)
  rm -rf "$BAU"
  echo "macOS:   $APP und dist/mac/Lageuhr-mac.zip"
fi

rm -f src/lageuhr.png.tmp
