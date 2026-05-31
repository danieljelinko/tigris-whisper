#!/usr/bin/env bash
set -euo pipefail

# One-stop installer for tigris-whisper.
# Detects the OS and backend, installs all system dependencies, then sets up
# the whisper.cpp server and downloads the default model.
#
# Usage:
#   ./install.sh                  # auto-detect
#   WHISPER_BACKEND=docker_cuda ./install.sh   # force Docker path (Linux only)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"
WHISPER_BACKEND="${WHISPER_BACKEND:-}"
CONFIG_FILE="$SCRIPT_DIR/tigris-whisper.env"
USER_WHISPER_MLX_MODEL="${WHISPER_MLX_MODEL:-}"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    set -a; source "$CONFIG_FILE"; set +a
fi
[ -n "$USER_WHISPER_MLX_MODEL" ] && export WHISPER_MLX_MODEL="$USER_WHISPER_MLX_MODEL"

# ─── Detect backend ───────────────────────────────────────────────────────────
if [ -z "$WHISPER_BACKEND" ]; then
    if [ "$OS" = "Darwin" ]; then
        WHISPER_BACKEND="mlx"
    elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        WHISPER_BACKEND="docker_cuda"
    else
        WHISPER_BACKEND="whispercpp_cpu"
    fi
fi

echo "=== tigris-whisper installer ==="
echo "OS: $OS | Backend: $WHISPER_BACKEND"
echo ""

# ─── macOS ────────────────────────────────────────────────────────────────────
if [ "$OS" = "Darwin" ]; then
    echo "── macOS dependencies ──"

    # The default mlx-whisper backend needs NO Xcode CLT and NO Homebrew at
    # install or run time. Pixi provides a standalone Python environment without
    # touching macOS developer-tool stubs such as python3 or install_name_tool.
    # (Xcode CLT / Homebrew are only needed for the optional whisper.cpp fallback
    # via scripts/101_install_whispercpp.sh, which checks for them itself.)

    # pixi
    if ! command -v pixi >/dev/null 2>&1; then
        echo "Installing pixi…"
        curl -fsSL https://pixi.sh/install.sh | sh
        # shellcheck source=/dev/null
        [ -f "$HOME/.pixi/env" ] && source "$HOME/.pixi/env" || \
            export PATH="$HOME/.pixi/bin:$PATH"
    else
        echo "✓ pixi: $(pixi --version)"
    fi
    PIXI="$(command -v pixi 2>/dev/null || printf '%s/.pixi/bin/pixi' "$HOME")"

    # Python deps — mlx-whisper installs as prebuilt wheels (no compiler).
    # The Whisper model itself downloads lazily from HuggingFace on first run.
    echo ""
    echo "── Python dependencies (incl. mlx-whisper) ──"
    "$PIXI" install

    echo ""
    echo "── Mac app wrapper ──"
    bash "$SCRIPT_DIR/scripts/create_mac_app.sh"

    echo ""
    echo "✓ macOS installation complete."
    echo "  Backend: mlx-whisper (Apple-Silicon native)."
    echo "  Model: ${WHISPER_MLX_MODEL:-mlx-community/whisper-large-v3-turbo-q4}"
    echo "  Language scope: multilingual Whisper model."
    echo "  Language list: https://github.com/openai/whisper/blob/main/whisper/tokenizer.py"
    echo "  Model warmup: bootstrap runs ./scripts/test_mac_setup.sh next."
    echo "  First warmup downloads the selected model with Hugging Face progress bars."
    echo "  Tip: to use whisper.cpp instead, run scripts/101_install_whispercpp.sh and"
    echo "       launch with WHISPER_BACKEND=whispercpp_metal ./run.sh"
    echo ""
    echo "IMPORTANT — for normal use, launch the app and grant permissions to it:"
    echo "  1. Microphone:    System Settings → Privacy & Security → Microphone → enable tigris-whisper"
    echo "  2. Accessibility: System Settings → Privacy & Security → Accessibility → enable tigris-whisper"
    echo "     (If you run ./run.sh manually instead, grant permissions to your terminal app.)"
    echo ""
    echo "Normal launch:     open ~/Applications/tigris-whisper.app"
    echo "Reveal in Finder:  open -R ~/Applications/tigris-whisper.app"
    echo "Manual/dev launch: ./run.sh"
    echo "App controls:      ./scripts/control_mac_app.sh status|stop|restart|logs"
    echo "Change model:      ./scripts/change_mlx_model.sh"
    echo "Verify/warm model: ./scripts/test_mac_setup.sh"
    echo "Uninstall:     ./uninstall.sh"

# ─── Linux ────────────────────────────────────────────────────────────────────
elif [ "$OS" = "Linux" ]; then
    echo "── Linux dependencies ──"

    if command -v apt-get >/dev/null 2>&1; then
        PKG_INSTALL="sudo apt-get install -y"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_INSTALL="sudo dnf install -y"
    else
        echo "Warning: unknown package manager; install deps manually if needed."
        PKG_INSTALL=""
    fi

    if [ -n "$PKG_INSTALL" ]; then
        echo "Installing system packages (sox, libnotify, xdotool/wtype, curl)…"
        $PKG_INSTALL sox libnotify-bin curl

        # Display-server tools
        if [ -n "${WAYLAND_DISPLAY:-}" ]; then
            $PKG_INSTALL wtype wl-clipboard 2>/dev/null || \
                echo "Warning: wtype/wl-clipboard not found in repos; install manually for Wayland paste."
        else
            $PKG_INSTALL xdotool x11-xserver-utils xclip 2>/dev/null || true
        fi
    fi

    # uv
    if ! command -v uv >/dev/null 2>&1; then
        echo "Installing uv…"
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
    else
        echo "✓ uv already installed"
    fi

    echo ""
    echo "── Python dependencies ──"
    uv sync

    # Backend-specific
    if [ "$WHISPER_BACKEND" = "docker_cuda" ]; then
        echo ""
        echo "── Docker CUDA backend ──"
        command -v docker >/dev/null || {
            echo "Docker not found. Install Docker and the NVIDIA Container Toolkit, then re-run."
            echo "  See: scripts/100_install_nvidia_container_toolkit.sh"
            exit 1
        }
        echo "✓ Docker present. Build or pull the whisper-assistant image before running."
        echo "  See README.md → Installation → step 0."
    else
        echo ""
        echo "── whisper.cpp (CPU) ──"
        $PKG_INSTALL cmake build-essential 2>/dev/null || \
            { echo "Warning: could not install cmake/build-essential via package manager."; }
        bash "$SCRIPT_DIR/scripts/101_install_whispercpp.sh"
    fi

    echo ""
    echo "✓ Linux installation complete."
    echo "Run:  ./run.sh"
    echo "Uninstall: ./uninstall.sh"

else
    echo "Error: unsupported OS '$OS'. Supported: Darwin, Linux."
    exit 1
fi
