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

setup_log() {
    [ "${TIGRIS_NO_LOG:-0}" = "1" ] && return 0
    local log_dir log_file
    if [ "$OS" = "Darwin" ]; then
        log_dir="$HOME/Library/Logs/tigris-whisper"
    else
        log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/tigris-whisper"
    fi
    mkdir -p "$log_dir"
    log_file="$log_dir/install-$(date +%Y%m%d-%H%M%S).log"
    ln -sf "$log_file" "$log_dir/install-latest.log"
    exec > >(tee -a "$log_file") 2>&1
    echo "Logging installer output to: $log_file"
    echo "Latest installer log: $log_dir/install-latest.log"
    echo ""
}
setup_log

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
        WHISPER_BACKEND="faster_whisper"
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
    echo "Install log:       ~/Library/Logs/tigris-whisper/install-latest.log"
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
        echo "Installing system packages (sox, libnotify, xdotool/wtype, curl, python3-dev)…"
        $PKG_INSTALL sox libnotify-bin curl python3-dev

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

    elif [ "$WHISPER_BACKEND" = "faster_whisper" ]; then
        echo ""
        echo "── faster-whisper (CPU) ──"

        # Model selection
        local_fw_model="${FASTER_WHISPER_MODEL:-}"
        if [ -z "$local_fw_model" ] && [ -r /dev/tty ]; then
            echo "Choose the Whisper model for transcription:"
            echo "  All choices are multilingual Whisper models."
            echo "  Language list: https://github.com/openai/whisper/blob/main/whisper/tokenizer.py"
            echo ""
            echo "  1. Balanced (default): small          — ~490 MB, good accuracy"
            echo "  2. Fast:               base            — ~145 MB, lower latency"
            echo "  3. Very fast:          tiny            — ~75 MB, fastest"
            echo "  4. Best accuracy:      large-v3-turbo  — ~1.6 GB, slower on CPU"
            printf "Model choice [1]: "
            read -r _fw_reply < /dev/tty || _fw_reply=""
            case "${_fw_reply:-1}" in
                1) local_fw_model="small" ;;
                2) local_fw_model="base" ;;
                3) local_fw_model="tiny" ;;
                4) local_fw_model="large-v3-turbo" ;;
                *) local_fw_model="small" ;;
            esac
        fi
        local_fw_model="${local_fw_model:-small}"
        export FASTER_WHISPER_MODEL="$local_fw_model"

        # Write config (preserve any existing Mac keys)
        _fw_tmp="$(mktemp)"
        if [ -f "$CONFIG_FILE" ]; then
            grep -v '^export FASTER_WHISPER_MODEL=' "$CONFIG_FILE" > "$_fw_tmp" || true
        fi
        printf 'export FASTER_WHISPER_MODEL=%q\n' "$local_fw_model" >> "$_fw_tmp"
        mv "$_fw_tmp" "$CONFIG_FILE"

        echo ""
        echo "Selected model: $FASTER_WHISPER_MODEL"
        echo "Saved model config: $CONFIG_FILE"

        # Pre-download
        echo ""
        echo "Pre-downloading faster-whisper model '${FASTER_WHISPER_MODEL}'…"
        echo "(First download can take a few minutes; progress shown below.)"
        uv run python "$SCRIPT_DIR/scripts/download_faster_whisper_model.py"

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
    echo "Change model: ./scripts/change_faster_whisper_model.sh"
    echo "Uninstall: ./uninstall.sh"

else
    echo "Error: unsupported OS '$OS'. Supported: Darwin, Linux."
    exit 1
fi
