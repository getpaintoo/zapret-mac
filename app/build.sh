#!/bin/bash
# Собирает Zapret.app (Apple Silicon и Intel) без Xcode — хватает Command Line Tools.
# Внутрь кладутся zapret-mac.sh и strategies.conf: приложение ставит их в /opt/zapret-mac.
#
#   bash app/build.sh            → app/build/Zapret.app и app/build/Zapret.zip (для релиза)
#   bash app/build.sh install    → ещё и скопировать в /Applications и открыть
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=${here%/*}
ver=$(sed -n 's/^ZM_VERSION="\(.*\)"$/\1/p' "$root/zapret-mac.sh")
build="$here/build"
app="$build/Zapret.app"

cd "$here"
echo "Собираю Zapret $ver…"
for arch in arm64 x86_64; do
  swift build -c release --arch "$arch" 2>&1 | grep -vE '^\[[0-9]+/[0-9]+\]' || true
  [ -x ".build/$arch-apple-macosx/release/Zapret" ] || { echo "Сборка для $arch не удалась" >&2; exit 1; }
done

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/Zapret .build/x86_64-apple-macosx/release/Zapret \
     -output "$app/Contents/MacOS/Zapret"
install -m 755 "$root/zapret-mac.sh" "$app/Contents/Resources/zapret-mac.sh"
install -m 644 "$root/strategies.conf" "$app/Contents/Resources/strategies.conf"

rm -rf "$build/AppIcon.iconset"
swift "$here/icon.swift" "$build/AppIcon.iconset"
iconutil -c icns "$build/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Zapret</string>
  <key>CFBundleDisplayName</key><string>Zapret</string>
  <key>CFBundleIdentifier</key><string>com.zapret-mac.app</string>
  <key>CFBundleExecutable</key><string>Zapret</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$ver</string>
  <key>CFBundleVersion</key><string>${ver//./}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>zapret-mac · MIT</string>
</dict>
</plist>
EOF
plutil -lint "$app/Contents/Info.plist" >/dev/null

# подпись без сертификата: macOS требует хоть какую-то, а обновление сверяет её целостность
codesign --force --deep --sign - "$app"
codesign --verify --deep "$app"

rm -f "$build/Zapret.zip"
(cd "$build" && ditto -c -k --keepParent Zapret.app Zapret.zip)
echo "Готово: $app"
echo "        $build/Zapret.zip ($(du -h "$build/Zapret.zip" | cut -f1))"

if [ "${1:-}" = install ]; then
  pkill -x Zapret 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Zapret.app
  ditto "$app" /Applications/Zapret.app
  open /Applications/Zapret.app
  echo "Установлено в /Applications и запущено"
fi
