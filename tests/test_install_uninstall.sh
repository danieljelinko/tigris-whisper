#!/usr/bin/env bash
# Tests for installer/uninstaller behavior that can run safely on Linux.
# macOS is simulated with a temporary uname stub; pixi is stubbed so no network
# or dependency installation happens.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_BIN="$TMP/bin"
HOME_DIR="$TMP/home"
APP_PARENT="$TMP/apps"
INSTALL_DIR="$TMP/install"
mkdir -p "$FAKE_BIN" "$HOME_DIR" "$APP_PARENT" "$INSTALL_DIR"

cat > "$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
echo Darwin
EOF
chmod +x "$FAKE_BIN/uname"

cat > "$FAKE_BIN/pixi" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    --version) echo "pixi 0.test" ;;
    install) echo "fake pixi install OK" ;;
    *) echo "fake pixi $*" ;;
esac
EOF
chmod +x "$FAKE_BIN/pixi"

cat > "$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -C) exit 0 ;;
    --version) echo "git version 0.test" ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$FAKE_BIN/git"

cat > "$FAKE_BIN/osacompile" <<'EOF'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
    esac
    shift || true
done
[ -n "$out" ] || { echo "missing -o" >&2; exit 1; }
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
cat > "$out/Contents/MacOS/applet" <<'APPLET'
#!/usr/bin/env bash
# fake osacompile applet delegates to launcher.sh
APPLET
chmod +x "$out/Contents/MacOS/applet"
EOF
chmod +x "$FAKE_BIN/osacompile"

export PATH="$FAKE_BIN:$PATH"
export HOME="$HOME_DIR"
export WHISPER_APP_PARENT="$APP_PARENT"
unset TIGRIS_NO_LOG

echo "=== install/uninstall tests ==="

# ─── install.sh: macOS path creates app wrapper and prints uninstall command ──

install_out="$TMP/install.out"
if bash "$SCRIPT_DIR/install.sh" >"$install_out" 2>&1; then
    ok "install.sh macOS path exits successfully with fake pixi"
else
    cat "$install_out"
    fail "install.sh macOS path exits successfully with fake pixi"
fi

APP_DIR="$APP_PARENT/tigris-whisper.app"
[ -x "$APP_DIR/Contents/MacOS/tigris-whisper" ] && \
    ok "install.sh creates executable app wrapper" || \
    fail "install.sh creates executable app wrapper"

grep -q "com.danieljelinko.tigris-whisper" "$APP_DIR/Contents/Info.plist" && \
    ok "app wrapper plist contains bundle id" || \
    fail "app wrapper plist contains bundle id"

grep -q "Starting in the background" "$APP_DIR/Contents/Resources/launcher.sh" && \
    ok "app wrapper notifies on background start" || \
    fail "app wrapper notifies on background start"

grep -q "RUN_PID_FILE" "$APP_DIR/Contents/Resources/launcher.sh" && \
    ok "app wrapper tracks daemon child process" || \
    fail "app wrapper tracks daemon child process"

grep -q "launcher.sh" "$APP_DIR/Contents/MacOS/tigris-whisper" && \
    ok "app wrapper executable delegates to launcher helper" || \
    fail "app wrapper executable delegates to launcher helper"

grep -q "Uninstall:     ./uninstall.sh" "$install_out" && \
    ok "install.sh prints uninstall command" || \
    fail "install.sh prints uninstall command"

grep -q "Logging installer output to:" "$install_out" && \
    ok "install.sh announces installer log file" || \
    fail "install.sh announces installer log file"

[ -L "$HOME/Library/Logs/tigris-whisper/install-latest.log" ] && \
    ok "install.sh writes latest installer log symlink" || \
    fail "install.sh writes latest installer log symlink"

grep -q "=== tigris-whisper installer ===" "$HOME/Library/Logs/tigris-whisper/install-latest.log" && \
    ok "install.sh log captures installer output" || \
    fail "install.sh log captures installer output"

grep -q "Normal launch:     open ~/Applications/tigris-whisper.app" "$install_out" && \
    ok "install.sh makes app launch the normal path" || \
    fail "install.sh makes app launch the normal path"

grep -q "Reveal in Finder:  open -R ~/Applications/tigris-whisper.app" "$install_out" && \
    ok "install.sh prints Finder reveal command" || \
    fail "install.sh prints Finder reveal command"

grep -q "Model: mlx-community/whisper-large-v3-turbo-q4" "$install_out" && \
    ok "install.sh prints selected/default mlx model" || \
    fail "install.sh prints selected/default mlx model"

grep -q "Language scope: multilingual Whisper model" "$install_out" && \
    ok "install.sh prints model language scope" || \
    fail "install.sh prints model language scope"

grep -q "openai/whisper/blob/main/whisper/tokenizer.py" "$install_out" && \
    ok "install.sh prints language list link" || \
    fail "install.sh prints language list link"

grep -q "Hugging Face progress bars" "$install_out" && \
    ok "install.sh mentions visible model download progress" || \
    fail "install.sh mentions visible model download progress"

grep -q "control_mac_app.sh status|stop|restart|logs" "$install_out" && \
    ok "install.sh prints app control commands" || \
    fail "install.sh prints app control commands"

grep -q "Change model:      ./scripts/change_model.sh" "$install_out" && \
    ok "install.sh prints model switcher command" || \
    fail "install.sh prints model switcher command"

control_out="$TMP/control.out"
if bash "$SCRIPT_DIR/scripts/control_mac_app.sh" help >"$control_out" 2>&1; then
    ok "control_mac_app.sh help exits successfully"
else
    cat "$control_out"
    fail "control_mac_app.sh help exits successfully"
fi

grep -q "status" "$control_out" && grep -q "restart" "$control_out" && \
    ok "control_mac_app.sh documents status/restart" || \
    fail "control_mac_app.sh documents status/restart"

# ─── bootstrap.sh: runs Mac smoke test/model warmup after install ─────────────

BOOTSTRAP_DIR="$TMP/bootstrap-install"
mkdir -p "$BOOTSTRAP_DIR/.git" "$BOOTSTRAP_DIR/scripts"
cat > "$BOOTSTRAP_DIR/install.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub install ran"
EOF
chmod +x "$BOOTSTRAP_DIR/install.sh"
cat > "$BOOTSTRAP_DIR/scripts/test_mac_setup.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub smoke test ran"
touch "$HOME/bootstrap-smoke-test-ran"
EOF
chmod +x "$BOOTSTRAP_DIR/scripts/test_mac_setup.sh"

bootstrap_out="$TMP/bootstrap.out"
if WHISPER_INSTALL_DIR="$BOOTSTRAP_DIR" bash "$SCRIPT_DIR/bootstrap.sh" >"$bootstrap_out" 2>&1; then
    ok "bootstrap.sh fake-mac path exits successfully"
else
    cat "$bootstrap_out"
    fail "bootstrap.sh fake-mac path exits successfully"
fi

grep -q "Running Mac setup test and model warmup" "$bootstrap_out" && \
    ok "bootstrap.sh announces automatic smoke test/model warmup" || \
    fail "bootstrap.sh announces automatic smoke test/model warmup"

grep -q "Logging bootstrap output to:" "$bootstrap_out" && \
    ok "bootstrap.sh announces bootstrap log file" || \
    fail "bootstrap.sh announces bootstrap log file"

[ -L "$HOME/Library/Logs/tigris-whisper/bootstrap-latest.log" ] && \
    ok "bootstrap.sh writes latest bootstrap log symlink" || \
    fail "bootstrap.sh writes latest bootstrap log symlink"

grep -q "Running Mac setup test and model warmup" "$HOME/Library/Logs/tigris-whisper/bootstrap-latest.log" && \
    ok "bootstrap.sh log captures bootstrap output" || \
    fail "bootstrap.sh log captures bootstrap output"

grep -q "Selected model: mlx-community/whisper-large-v3-turbo-q4" "$bootstrap_out" && \
    ok "bootstrap.sh prints selected model" || \
    fail "bootstrap.sh prints selected model"

[ -f "$BOOTSTRAP_DIR/tigris-whisper.env" ] && \
    ok "bootstrap.sh writes model config file" || \
    fail "bootstrap.sh writes model config file"

grep -q "WHISPER_MLX_MODEL=mlx-community/whisper-large-v3-turbo-q4" "$BOOTSTRAP_DIR/tigris-whisper.env" && \
    ok "bootstrap.sh model config contains default model" || \
    fail "bootstrap.sh model config contains default model"

grep -q "can take several minutes" "$bootstrap_out" && \
    ok "bootstrap.sh warns model download can take several minutes" || \
    fail "bootstrap.sh warns model download can take several minutes"

grep -q "Hugging Face progress bars" "$bootstrap_out" && \
    ok "bootstrap.sh says model download has visible progress bars" || \
    fail "bootstrap.sh says model download has visible progress bars"

[ -f "$HOME/bootstrap-smoke-test-ran" ] && \
    ok "bootstrap.sh runs smoke test automatically on macOS" || \
    fail "bootstrap.sh runs smoke test automatically on macOS"

grep -q "WHAT TO DO NEXT" "$bootstrap_out" && \
    ok "bootstrap.sh prints final next-step section" || \
    fail "bootstrap.sh prints final next-step section"

grep -q "1. Launch the application:" "$bootstrap_out" && \
    ok "bootstrap.sh gives numbered app launch step" || \
    fail "bootstrap.sh gives numbered app launch step"

grep -q "open -R ~/Applications/tigris-whisper.app" "$bootstrap_out" && \
    ok "bootstrap.sh includes Finder reveal path" || \
    fail "bootstrap.sh includes Finder reveal path"

grep -q "Finder's sidebar Applications may show /Applications" "$bootstrap_out" && \
    ok "bootstrap.sh explains user Applications folder" || \
    fail "bootstrap.sh explains user Applications folder"

if grep -q "may not appear in Microphone settings until it asks once" "$bootstrap_out"; then
    fail "bootstrap.sh should not say Microphone waits for first hotkey"
else
    ok "bootstrap.sh does not claim Microphone waits for first hotkey"
fi

grep -q "asks for Microphone access at startup" "$bootstrap_out" && \
    ok "bootstrap.sh says app requests Microphone at startup" || \
    fail "bootstrap.sh says app requests Microphone at startup"

grep -q "control_mac_app.sh status|stop|restart|logs" "$bootstrap_out" && \
    ok "bootstrap.sh prints app control commands" || \
    fail "bootstrap.sh prints app control commands"

grep -q "change_model.sh --restart" "$bootstrap_out" && \
    ok "bootstrap.sh prints model switcher command" || \
    fail "bootstrap.sh prints model switcher command"

grep -q "4. Confirm Microphone is enabled:" "$bootstrap_out" && \
    ok "bootstrap.sh gives explicit Microphone permission step" || \
    fail "bootstrap.sh gives explicit Microphone permission step"

# ─── change_model.sh: updates model config without reinstall ─────────────────

MODEL_TEST_DIR="$TMP/model-change"
mkdir -p "$MODEL_TEST_DIR/scripts" "$MODEL_TEST_DIR/src"
# change_model.sh resolves models via the stdlib-only model_catalog. Copy both so
# the switcher runs in isolation.
cp "$SCRIPT_DIR/scripts/change_model.sh" "$MODEL_TEST_DIR/scripts/change_model.sh"
cp "$SCRIPT_DIR/src/model_catalog.py" "$SCRIPT_DIR/src/backend_select.py" "$MODEL_TEST_DIR/src/"

model_out="$TMP/model-change.out"
if bash "$MODEL_TEST_DIR/scripts/change_model.sh" fast >"$model_out" 2>&1; then
    ok "change_model.sh accepts profile argument"
else
    cat "$model_out"
    fail "change_model.sh accepts profile argument"
fi

grep -q "WHISPER_MLX_MODEL=mlx-community/whisper-small-mlx-q4" "$MODEL_TEST_DIR/tigris-whisper.env" && \
    ok "change_model.sh writes profile model" || \
    fail "change_model.sh writes profile model"

if bash "$MODEL_TEST_DIR/scripts/change_model.sh" mlx-community/custom-whisper >"$model_out" 2>&1; then
    ok "change_model.sh accepts custom model id"
else
    cat "$model_out"
    fail "change_model.sh accepts custom model id"
fi

grep -q "WHISPER_MLX_MODEL=mlx-community/custom-whisper" "$MODEL_TEST_DIR/tigris-whisper.env" && \
    ok "change_model.sh writes custom model id" || \
    fail "change_model.sh writes custom model id"

# ─── uninstall.sh: removes generated app/state/logs/model/install dir safely ──

mkdir -p \
    "$HOME/Library/Logs/tigris-whisper" \
    "$HOME/Library/Application Support/tigris-whisper" \
    "$HOME/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo-q4" \
    "$HOME/.cache/whisper.cpp" \
    "$INSTALL_DIR"
touch \
    "$HOME/Library/Logs/tigris-whisper/daemon.log" \
    "$HOME/Library/Application Support/tigris-whisper/daemon.pid" \
    "$HOME/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo-q4/model.safetensors" \
    "$HOME/.cache/whisper.cpp/mlx_server.log" \
    "$INSTALL_DIR/bootstrap.sh"

uninstall_out="$TMP/uninstall.out"
if bash "$SCRIPT_DIR/uninstall.sh" --yes --install-dir "$INSTALL_DIR" >"$uninstall_out" 2>&1; then
    ok "uninstall.sh --yes exits successfully"
else
    cat "$uninstall_out"
    fail "uninstall.sh --yes exits successfully"
fi

[ ! -e "$APP_DIR" ] && \
    ok "uninstall.sh removes app wrapper" || \
    fail "uninstall.sh removes app wrapper"

[ ! -e "$HOME/Library/Logs/tigris-whisper" ] && \
    ok "uninstall.sh removes app logs" || \
    fail "uninstall.sh removes app logs"

[ ! -e "$HOME/Library/Application Support/tigris-whisper" ] && \
    ok "uninstall.sh removes app state" || \
    fail "uninstall.sh removes app state"

[ ! -e "$HOME/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo-q4" ] && \
    ok "uninstall.sh removes known mlx model cache" || \
    fail "uninstall.sh removes known mlx model cache"

[ ! -e "$HOME/.cache/whisper.cpp/mlx_server.log" ] && \
    ok "uninstall.sh removes mlx server log" || \
    fail "uninstall.sh removes mlx server log"

[ ! -e "$INSTALL_DIR" ] && \
    ok "uninstall.sh --yes removes install dir" || \
    fail "uninstall.sh --yes removes install dir"

[ -d "$HOME" ] && \
    ok "uninstall.sh keeps HOME intact" || \
    fail "uninstall.sh keeps HOME intact"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
