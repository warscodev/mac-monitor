#!/bin/zsh
# 사용법:
#   ./build.sh          → build/MonitorSwitch.app 생성
#   ./build.sh install  → 빌드 후 ~/Applications 에 설치하고 실행
set -euo pipefail
cd "$(dirname "$0")"

APP=build/MonitorSwitch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -framework AppKit -framework Carbon -framework ServiceManagement \
  -o "$APP/Contents/MacOS/MonitorSwitch" \
  Sources/*.swift

cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "빌드 완료: $APP"

if [[ "${1:-}" == "install" ]]; then
  DEST="$HOME/Applications/MonitorSwitch.app"
  mkdir -p "$HOME/Applications"
  pkill -x MonitorSwitch 2>/dev/null && sleep 1 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "설치 및 실행: $DEST"
fi
