#!/usr/bin/env bash
# Smoke-test the run.sh --print-backend dispatch logic on this Linux machine.
# Fakes nvidia-smi presence/absence via a tmp dir prepended to PATH.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# ─── Helpers ──────────────────────────────────────────────────────────────────

FAKE_DIR="$(mktemp -d)"
# Isolate from a developer's local tigris-whisper.env (run.sh sources it, and a
# WHISPER_BACKEND there would shadow the detection cases). Move it aside for the
# test and restore it on exit.
CONFIG_FILE="$SCRIPT_DIR/tigris-whisper.env"
_CONFIG_BAK=""
if [ -f "$CONFIG_FILE" ]; then _CONFIG_BAK="$FAKE_DIR/tigris-whisper.env.bak"; mv "$CONFIG_FILE" "$_CONFIG_BAK"; fi
restore_config() { [ -n "$_CONFIG_BAK" ] && [ -f "$_CONFIG_BAK" ] && mv "$_CONFIG_BAK" "$CONFIG_FILE" || true; }
trap 'restore_config; rm -rf "$FAKE_DIR"' EXIT

fake_nvidia() {                     # put a working fake nvidia-smi on PATH
    printf '#!/usr/bin/env bash\necho "GPU 0: Fake GPU"\n' > "$FAKE_DIR/nvidia-smi"
    chmod +x "$FAKE_DIR/nvidia-smi"
    export PATH="$FAKE_DIR:$PATH"
}

no_nvidia() {                       # shadow nvidia-smi with a failing stub (real one may exist)
    printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE_DIR/nvidia-smi"
    chmod +x "$FAKE_DIR/nvidia-smi"
    export PATH="$FAKE_DIR:$PATH"
}

run_backend() {
    local os="$1" gpu_env="$2"
    if [ "$gpu_env" = "gpu" ]; then fake_nvidia; else no_nvidia; fi
    # Pass --system directly via WHISPER_BACKEND override when we need Darwin
    # (we can't change uname); for Linux we rely on real uname + faked nvidia-smi.
    if [ "$os" = "Darwin" ]; then
        WHISPER_BACKEND="whispercpp_metal" bash "$SCRIPT_DIR/run.sh" --print-backend
    else
        unset WHISPER_BACKEND 2>/dev/null || true
        bash "$SCRIPT_DIR/run.sh" --print-backend
    fi
}

# ─── Test cases ───────────────────────────────────────────────────────────────

echo "=== run.sh dispatch tests ==="

# Linux + GPU → docker_cuda
no_nvidia  # reset first
fake_nvidia
result=$(bash "$SCRIPT_DIR/run.sh" --print-backend 2>/dev/null)
[ "$result" = "docker_cuda" ] && ok "Linux+GPU → docker_cuda" || fail "Linux+GPU → docker_cuda (got: $result)"

# Linux no GPU → faster_whisper (the current default; whisper.cpp CPU is opt-in via override)
no_nvidia
result=$(bash "$SCRIPT_DIR/run.sh" --print-backend 2>/dev/null)
[ "$result" = "faster_whisper" ] && ok "Linux no-GPU → faster_whisper" || fail "Linux no-GPU → faster_whisper (got: $result)"

# WHISPER_BACKEND override wins
no_nvidia
result=$(WHISPER_BACKEND=whispercpp_cpu bash "$SCRIPT_DIR/run.sh" --print-backend 2>/dev/null)
[ "$result" = "whispercpp_cpu" ] && ok "override WHISPER_BACKEND=whispercpp_cpu" || fail "override WHISPER_BACKEND=whispercpp_cpu (got: $result)"

# Metal override (simulates Mac whisper.cpp fallback from Linux)
result=$(WHISPER_BACKEND=whispercpp_metal bash "$SCRIPT_DIR/run.sh" --print-backend 2>/dev/null)
[ "$result" = "whispercpp_metal" ] && ok "override WHISPER_BACKEND=whispercpp_metal" || fail "override WHISPER_BACKEND=whispercpp_metal (got: $result)"

# mlx override (the Mac default; simulates it from Linux)
result=$(WHISPER_BACKEND=mlx bash "$SCRIPT_DIR/run.sh" --print-backend 2>/dev/null)
[ "$result" = "mlx" ] && ok "override WHISPER_BACKEND=mlx" || fail "override WHISPER_BACKEND=mlx (got: $result)"

# Invalid override → non-zero exit
WHISPER_BACKEND=bogus bash "$SCRIPT_DIR/run.sh" --print-backend 2>/dev/null && \
    fail "invalid override should fail" || ok "invalid override exits non-zero"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
