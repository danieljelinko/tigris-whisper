#!/usr/bin/env bash
# Create a lightweight macOS .app wrapper for the existing daemon.
# No Xcode, Swift, or code signing required.

set -euo pipefail

OS="$(uname -s)"
[ "$OS" = "Darwin" ] || { echo "Error: create_mac_app.sh is macOS-only"; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PARENT="${WHISPER_APP_PARENT:-$HOME/Applications}"
APP_NAME="${WHISPER_APP_NAME:-tigris-whisper.app}"
APP_DIR="$APP_PARENT/$APP_NAME"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
EXECUTABLE="tigris-whisper"
BUNDLE_ID="${WHISPER_APP_BUNDLE_ID:-com.danieljelinko.tigris-whisper}"

mkdir -p "$MACOS" "$RESOURCES"
printf "%s\n" "$REPO_DIR" > "$RESOURCES/repo_path"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>tigris-whisper</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>tigris-whisper</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>tigris-whisper records audio while you hold the hotkey so it can transcribe your speech locally.</string>
</dict>
</plist>
PLIST

cat > "$MACOS/$EXECUTABLE" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_PATH_FILE="$APP_ROOT/Resources/repo_path"
REPO_DIR="$(cat "$REPO_PATH_FILE")"
LOG_DIR="$HOME/Library/Logs/tigris-whisper"
STATE_DIR="$HOME/Library/Application Support/tigris-whisper"
LOG_FILE="$LOG_DIR/daemon.log"
PID_FILE="$STATE_DIR/daemon.pid"
RUN_PID_FILE="$STATE_DIR/run.pid"

mkdir -p "$LOG_DIR" "$STATE_DIR"

notify() {
    local message="$1"
    osascript -e "display notification \"$message\" with title \"tigris-whisper\"" >/dev/null 2>&1 || true
}

if [ -f "$PID_FILE" ]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        notify "Already running in the background."
        exit 0
    fi
fi

echo "$$" > "$PID_FILE"
RUN_PID=""
cleanup() {
    if [ -n "${RUN_PID:-}" ] && kill -0 "$RUN_PID" 2>/dev/null; then
        kill "$RUN_PID" 2>/dev/null || true
        wait "$RUN_PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE" "$RUN_PID_FILE"
}
trap cleanup EXIT TERM INT

export PATH="$HOME/.pixi/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

notify "Starting in the background. Hold Ctrl+Option+Space to record."
STATUS=0
{
    echo "===== $(date) starting tigris-whisper ====="
    echo "Repo: $REPO_DIR"
    cd "$REPO_DIR"
    set +e
    ./run.sh &
    RUN_PID=$!
    echo "$RUN_PID" > "$RUN_PID_FILE"
    wait "$RUN_PID"
    STATUS=$?
    set -e
    echo "===== $(date) tigris-whisper exited with status $STATUS ====="
} >> "$LOG_FILE" 2>&1

if [ "$STATUS" -ne 0 ]; then
    notify "Could not start. See ~/Library/Logs/tigris-whisper/daemon.log"
else
    notify "Stopped."
fi
exit "$STATUS"
LAUNCHER

chmod +x "$MACOS/$EXECUTABLE"

echo "✓ Created $APP_DIR"
echo "  Logs: $HOME/Library/Logs/tigris-whisper/daemon.log"
echo "  To reveal it in Finder, run:"
echo "    open -R \"$APP_DIR\""
echo "  To launch it from Terminal, run:"
echo "    open \"$APP_DIR\""
