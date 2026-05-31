#!/usr/bin/env bash
# Smoke test for the macOS tigris-whisper setup (mlx-whisper backend).
# Run this after ./install.sh to verify every piece works before you try the
# daemon for the first time.
#
# What it checks:
#   1. Apple Silicon chip (M-series) + macOS version
#   2. Pixi installed and Python deps synced
#   3. Flask + daemon dependency imports
#   4. Model warmup/download with Hugging Face progress
#   5. End-to-end: start the mlx server, POST a real WAV → text
#   6. run.sh dispatch resolves to mlx
#   7. macOS permission reminder (advisory)
#
# Usage:
#   ./scripts/test_mac_setup.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$REPO_DIR/tests/fixtures/sample_speech.wav"
PORT=14444   # non-standard port so we don't collide with a running daemon
PIXI="$(command -v pixi 2>/dev/null || printf '%s/.pixi/bin/pixi' "$HOME")"
CONFIG_FILE="$REPO_DIR/tigris-whisper.env"
USER_WHISPER_MLX_MODEL="${WHISPER_MLX_MODEL:-}"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    set -a; source "$CONFIG_FILE"; set +a
fi
[ -n "$USER_WHISPER_MLX_MODEL" ] && export WHISPER_MLX_MODEL="$USER_WHISPER_MLX_MODEL"
WHISPER_MLX_MODEL="${WHISPER_MLX_MODEL:-mlx-community/whisper-large-v3-turbo-q4}"

PASS=0; FAIL=0; WARN=0
ok()   { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }
warn() { echo "  ⚠️  WARN: $1"; WARN=$((WARN+1)); }
hr()   { echo ""; echo "──────────────────────────────────────────────"; }
cache_size() {
    local sizes xet_log xet_bytes xet_mb
    sizes="$(du -sh "$HOME/.cache/huggingface" "$HOME/.cache/mlx" 2>/dev/null | \
        awk '{printf "%s=%s ", $2, $1}' | sed "s|$HOME/||g; s/[[:space:]]$//" || true
    )"
    xet_log="$(ls -t "$HOME"/.cache/huggingface/xet/logs/xet_*.log 2>/dev/null | head -1 || true)"
    if [ -n "$xet_log" ]; then
        xet_bytes="$(grep -o 'observed bytes sent so far = [0-9]*' "$xet_log" 2>/dev/null | tail -1 | awk '{print $NF}' || true)"
        if [ -n "$xet_bytes" ]; then
            xet_mb=$((xet_bytes / 1024 / 1024))
            sizes="${sizes:+$sizes }xet_downloaded~${xet_mb}M"
        fi
    fi
    printf "%s" "$sizes"
}

echo ""
echo "=== tigris-whisper Mac smoke test (mlx-whisper) ==="
echo "Repo: $REPO_DIR"
echo "Model: $WHISPER_MLX_MODEL"
echo "Language scope: multilingual Whisper model"
cd "$REPO_DIR"

# ─── 1. Hardware ──────────────────────────────────────────────────────────────
hr; echo "1. Hardware"
CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
if echo "$CHIP" | grep -qi "apple"; then
    ok "Apple Silicon: $CHIP"
else
    fail "Non-Apple-Silicon chip: $CHIP — mlx-whisper requires Apple Silicon"
fi
ok "macOS version: $(sw_vers -productVersion 2>/dev/null || echo unknown)"

# ─── 2. Pixi + Python deps ────────────────────────────────────────────────────
hr; echo "2. Python environment"
if [ -x "$PIXI" ]; then
    ok "pixi: $("$PIXI" --version)"
    "$PIXI" install --quiet 2>/dev/null && ok "pixi install OK" || fail "pixi install failed"
else
    fail "pixi not installed. Run: ./install.sh"
fi

# ─── 3. Imports ───────────────────────────────────────────────────────────────
hr; echo "3. Key imports"
"$PIXI" run python -c "import flask" 2>/dev/null && ok "flask imports" || fail "flask missing"
"$PIXI" run python -c "import pynput, requests, sounddevice" 2>/dev/null && \
    ok "daemon deps import (pynput, requests, sounddevice)" || \
    fail "a daemon dependency failed to import"

# ─── 4. Model warmup/download ────────────────────────────────────────────────
hr; echo "4. Model download / cache warmup"
echo "   Selected model: $WHISPER_MLX_MODEL"
echo "   First run downloads from Hugging Face and can take several minutes."
echo "   Progress bars appear below when files are downloading."
if HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}" WHISPER_MLX_MODEL="$WHISPER_MLX_MODEL" \
    "$PIXI" run python scripts/download_mlx_model.py "$WHISPER_MLX_MODEL"; then
    ok "Model cache ready"
else
    fail "Model download/cache warmup failed"
fi

# ─── 5. End-to-end: launch mlx server → transcribe fixture ───────────────────
hr; echo "5. End-to-end transcription (mlx server + real audio)"
echo "   Model is already cached; this step verifies real transcription."
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT

if [ ! -f "$FIXTURE" ]; then
    warn "Skipping (fixture not found: $FIXTURE)"
else
    LOG="$(mktemp)"
    HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}" WHISPER_MLX_MODEL="$WHISPER_MLX_MODEL" WHISPER_MLX_PORT="$PORT" "$PIXI" run python src/mlx_whisper_server.py >"$LOG" 2>&1 &
    SERVER_PID=$!

    echo -n "   Waiting for server (incl. possible model download)"
    READY=0
    for _ in $(seq 1 600); do          # up to 10 min for first-time model pull
        if curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then READY=1; break; fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
        echo -n "."; sleep 1
    done
    echo ""

    if [ "$READY" = "0" ]; then
        fail "mlx server did not become ready. Log:"; tail -15 "$LOG"
    else
        ok "mlx server ready on :$PORT"
        RESPONSE_FILE="$(mktemp)"
        CURL_LOG="$(mktemp)"
        echo "   Sending sample audio for transcription..."
        echo "   Progress: waiting for first response."
        START_TS="$(date +%s)"
        curl -sf -F "file=@$FIXTURE;type=audio/wav" \
            "http://127.0.0.1:$PORT/v1/audio/transcriptions" \
            >"$RESPONSE_FILE" 2>"$CURL_LOG" &
        CURL_PID=$!

        while kill -0 "$CURL_PID" 2>/dev/null; do
            NOW_TS="$(date +%s)"
            ELAPSED=$((NOW_TS - START_TS))
            CACHE="$(cache_size)"
            [ -n "$CACHE" ] || CACHE="cache size not visible yet"
            printf "   ... %4ss elapsed | server pid %s alive | %s\n" "$ELAPSED" "$SERVER_PID" "$CACHE"
            sleep 5
        done

        if wait "$CURL_PID"; then
            RESPONSE="$(cat "$RESPONSE_FILE")"
        else
            fail "Transcription request failed. curl log:"; cat "$CURL_LOG"
            RESPONSE=""
        fi

        if echo "$RESPONSE" | grep -q '"text"'; then
            TEXT="$(echo "$RESPONSE" | "$PIXI" run python -c \
                'import sys,json; print(json.load(sys.stdin).get("text",""))' 2>/dev/null || echo "")"
            ok "Transcription response received"
            echo "      Transcript: \"$TEXT\""
            echo "$TEXT" | grep -qi -e test -e whisper -e three -e one -e two \
                && ok "Transcript contains expected words" \
                || warn "Transcript missing expected words (accent/quality variation?)"
        else
            fail "No 'text' in response: $RESPONSE"
        fi
    fi
fi

# ─── 5. Dispatch ──────────────────────────────────────────────────────────────
hr; echo "6. run.sh dispatch"
BACKEND="$(bash run.sh --print-backend 2>/dev/null || echo error)"
[ "$BACKEND" = "mlx" ] && ok "run.sh --print-backend → mlx" || \
    fail "run.sh --print-backend → '$BACKEND' (expected mlx)"

# ─── 6. Permissions (advisory) ────────────────────────────────────────────────
hr; echo "7. macOS permissions (verify manually — cannot be tested automatically)"
echo ""
echo "  Grant both before running the daemon, or recording/paste fail silently."
echo "  If launching the app wrapper, enable tigris-whisper:"
echo "    Microphone:    System Settings → Privacy & Security → Microphone → tigris-whisper"
echo "    Accessibility: System Settings → Privacy & Security → Accessibility → tigris-whisper"
echo "  If running ./run.sh manually, enable your terminal app instead."
echo ""
warn "Verify the two permissions above before running ./run.sh"

# ─── Summary ─────────────────────────────────────────────────────────────────
hr; echo ""
echo "Results: $PASS passed  |  $WARN warnings  |  $FAIL failed"
echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "Fix the failures above, then re-run: ./scripts/test_mac_setup.sh"; exit 1
else
    echo "Ready. Normal launch: open ~/Applications/tigris-whisper.app"
    echo "Manual/dev launch from this repo: ./run.sh"
    echo "Hold Ctrl+Option+Space to record; release Ctrl to transcribe and paste."
fi
