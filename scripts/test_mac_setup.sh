#!/usr/bin/env bash
# Smoke test for the macOS tigris-whisper setup — backend-aware.
# Honours the backend the user selected at install (mlx-whisper for Whisper
# profiles, mlx_audio for Nemotron/Cohere), reusing the same backend libs that
# run.sh uses so the warm-up + server bring-up are never duplicated here.
# Run this after ./install.sh to verify every piece works before you try the
# daemon for the first time.
#
# What it checks:
#   1. Apple Silicon chip (M-series) + macOS version
#   2. Pixi installed and Python deps synced
#   3. Flask + daemon dependency imports
#   4. Model warmup/download with Hugging Face progress (selected backend)
#   5. End-to-end: start the selected backend's server, POST a real WAV → text
#   6. run.sh dispatch resolves to the selected backend
#   7. macOS permission reminder (advisory)
#
# Usage:
#   ./scripts/test_mac_setup.sh
#
# Env:
#   TIGRIS_SKIP_TRANSCRIPTION_TEST=1  skip the real audio transcription check
#   TIGRIS_TRANSCRIPTION_TIMEOUT=120  seconds to wait for the sample response

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_DIR"   # backend libs reference $SCRIPT_DIR as the repo root
FIXTURE="$REPO_DIR/tests/fixtures/sample_speech.wav"
PORT=14444   # non-standard port so we don't collide with a running daemon
PIXI="$(command -v pixi 2>/dev/null || printf '%s/.pixi/bin/pixi' "$HOME")"
CONFIG_FILE="$REPO_DIR/tigris-whisper.env"
# Preserve any user-set env overrides over the saved config file.
USER_WHISPER_BACKEND="${WHISPER_BACKEND:-}"
USER_WHISPER_MLX_MODEL="${WHISPER_MLX_MODEL:-}"
USER_WHISPER_MLX_AUDIO_MODEL="${WHISPER_MLX_AUDIO_MODEL:-}"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    set -a; source "$CONFIG_FILE"; set +a
fi
[ -n "$USER_WHISPER_BACKEND" ] && export WHISPER_BACKEND="$USER_WHISPER_BACKEND"
[ -n "$USER_WHISPER_MLX_MODEL" ] && export WHISPER_MLX_MODEL="$USER_WHISPER_MLX_MODEL"
[ -n "$USER_WHISPER_MLX_AUDIO_MODEL" ] && export WHISPER_MLX_AUDIO_MODEL="$USER_WHISPER_MLX_AUDIO_MODEL"

# Resolve the selected backend + its model (default: Whisper on mlx).
BACKEND="${WHISPER_BACKEND:-mlx}"
if [ "$BACKEND" = "mlx_audio" ]; then
    MODEL="${WHISPER_MLX_AUDIO_MODEL:-mlx-community/nemotron-3.5-asr-streaming-0.6b}"
    SERVER_DESC="mlx-audio (Nemotron/Cohere family)"
else
    BACKEND="mlx"
    MODEL="${WHISPER_MLX_MODEL:-mlx-community/whisper-large-v3-turbo-q4}"
    SERVER_DESC="mlx-whisper"
fi
TRANSCRIPTION_TIMEOUT="${TIGRIS_TRANSCRIPTION_TIMEOUT:-120}"

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
echo "=== tigris-whisper Mac smoke test ($SERVER_DESC) ==="
echo "Repo: $REPO_DIR"
echo "Backend: $BACKEND"
echo "Model: $MODEL"
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

# ─── 4. Model warmup/download (backend-aware) ────────────────────────────────
hr; echo "4. Model download / cache warmup"
echo "   Selected backend: $BACKEND"
echo "   Selected model: $MODEL"
echo "   First run downloads from Hugging Face and can take several minutes."
echo "   Progress bars appear below when files are downloading."
if HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}" WHISPER_BACKEND="$BACKEND" \
    WHISPER_MLX_MODEL="${WHISPER_MLX_MODEL:-}" WHISPER_MLX_AUDIO_MODEL="${WHISPER_MLX_AUDIO_MODEL:-}" \
    "$PIXI" run python scripts/download_mlx_model.py "$MODEL"; then
    ok "Model cache ready"
else
    fail "Model download/cache warmup failed"
fi

# ─── 5. End-to-end: launch the selected backend's server → transcribe fixture ─
hr; echo "5. End-to-end transcription ($SERVER_DESC server + real audio)"
echo "   This sends a tiny bundled WAV file to the local server."
echo "   It verifies the selected backend can do a real transcription on this Mac."
echo "   It can take 30–120 seconds on first run while the model initializes."
echo "   Skip with: TIGRIS_SKIP_TRANSCRIPTION_TEST=1 ./scripts/test_mac_setup.sh"

if [ "${TIGRIS_SKIP_TRANSCRIPTION_TEST:-0}" = "1" ]; then
    warn "Skipping real transcription because TIGRIS_SKIP_TRANSCRIPTION_TEST=1"
elif [ ! -f "$FIXTURE" ]; then
    warn "Skipping (fixture not found: $FIXTURE)"
else
    # Reuse the exact backend lib run.sh uses — no duplicated bring-up. The lib
    # pre-downloads the model in the foreground, starts the server on $PORT, waits
    # for readiness, and installs its own EXIT trap to stop it.
    if [ "$BACKEND" = "mlx_audio" ]; then
        export WHISPER_MLX_AUDIO_PORT="$PORT" WHISPER_MLX_AUDIO_MODEL="$MODEL"
        LOG="${WHISPERCPP_DIR:-$HOME/.cache/whisper.cpp}/mlx_audio_server.log"
        # shellcheck source=lib/backend_mlx_audio.sh
        source "$REPO_DIR/scripts/lib/backend_mlx_audio.sh"
        ensure_selected_backend() { ensure_mlx_audio_backend; }
    else
        export WHISPER_MLX_PORT="$PORT" WHISPER_MLX_MODEL="$MODEL"
        LOG="${WHISPERCPP_DIR:-$HOME/.cache/whisper.cpp}/mlx_server.log"
        # shellcheck source=lib/backend_mlx.sh
        source "$REPO_DIR/scripts/lib/backend_mlx.sh"
        ensure_selected_backend() { ensure_mlx_backend; }
    fi

    if ! ensure_selected_backend; then
        fail "$SERVER_DESC server did not become ready on :$PORT"
    else
        ok "$SERVER_DESC server ready on :$PORT"
        RESPONSE_FILE="$(mktemp)"
        CURL_LOG="$(mktemp)"
        echo "   Sending sample audio for transcription..."
        echo "   Waiting up to ${TRANSCRIPTION_TIMEOUT}s for first response."
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
            if [ "$ELAPSED" -ge "$TRANSCRIPTION_TIMEOUT" ]; then
                kill "$CURL_PID" 2>/dev/null || true
                wait "$CURL_PID" 2>/dev/null || true
                fail "Sample transcription timed out after ${TRANSCRIPTION_TIMEOUT}s. Server log:"
                tail -20 "$LOG"
                RESPONSE=""
                break
            fi
            printf "   ... %4ss elapsed | real transcription still running | %s\n" "$ELAPSED" "$CACHE"
            sleep 5
        done

        if [ "${RESPONSE+x}" ]; then
            :
        elif wait "$CURL_PID"; then
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

# ─── 6. Dispatch ──────────────────────────────────────────────────────────────
hr; echo "6. run.sh dispatch"
DISPATCH_BACKEND="$(WHISPER_BACKEND="$BACKEND" bash run.sh --print-backend 2>/dev/null || echo error)"
[ "$DISPATCH_BACKEND" = "$BACKEND" ] && ok "run.sh --print-backend → $BACKEND" || \
    fail "run.sh --print-backend → '$DISPATCH_BACKEND' (expected $BACKEND)"

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
