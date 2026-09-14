#!/bin/zsh
# Build a double-clickable ResolumeScheduler.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="ResolumeScheduler"
APP_DIR="$ROOT/dist/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "→ Compilazione release…"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -x "$BIN" ]]; then
  echo "Binary non trovato: $BIN" >&2
  exit 1
fi

echo "→ Creazione bundle ${APP_NAME}.app…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>it</string>
	<key>CFBundleExecutable</key>
	<string>ResolumeScheduler</string>
	<key>CFBundleIdentifier</key>
	<string>com.local.ResolumeScheduler</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Resolume Scheduler</string>
	<key>CFBundleDisplayName</key>
	<string>Resolume Scheduler</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Serve l’input audio per decodificare il timecode LTC.</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

cp "$BIN" "$MACOS/${APP_NAME}"
chmod +x "$MACOS/${APP_NAME}"

# Ad-hoc sign so Gatekeeper allows local open (still may need right-click → Apri la prima volta)
codesign --force --deep --sign - "$APP_DIR"

echo "→ Verifica…"
codesign --verify --verbose=2 "$APP_DIR"
file "$MACOS/${APP_NAME}"

# Copia comoda sul Desktop
DESKTOP="$HOME/Desktop/${APP_NAME}.app"
rm -rf "$DESKTOP"
cp -R "$APP_DIR" "$DESKTOP"

echo ""
echo "Pronto:"
echo "  $APP_DIR"
echo "  $DESKTOP"
echo ""
echo "Apri con doppio click, oppure: open \"$DESKTOP\""
