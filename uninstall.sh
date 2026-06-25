#!/usr/bin/env bash
set -euo pipefail

# Uninstall tigris-whisper from this Mac/Linux user account.
# By default this removes generated app/state/log files and the known project
# model cache. Removing the repo/install directory is opt-in unless --yes is
# used from inside the install directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"
CONFIG_FILE="$SCRIPT_DIR/tigris-whisper.env"
USER_WHISPER_MLX_MODEL="${WHISPER_MLX_MODEL:-}"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    set -a; source "$CONFIG_FILE"; set +a
fi
[ -n "$USER_WHISPER_MLX_MODEL" ] && export WHISPER_MLX_MODEL="$USER_WHISPER_MLX_MODEL"

ASSUME_YES=0
REMOVE_MODELS=1
REMOVE_INSTALL_DIR=0
INSTALL_DIR="$SCRIPT_DIR"
REMOVE_PIXI=0

usage() {
    cat <<EOF
Usage: ./uninstall.sh [options]

Options:
  -y, --yes              Do not prompt; remove app/state/logs/models and install dir
      --install-dir DIR  Install directory to remove (default: this repo)
      --remove-install-dir
                          Remove the install directory/repo
      --keep-install-dir Keep the install directory/repo
      --keep-models      Keep downloaded HuggingFace model cache
      --remove-pixi      Also remove ~/.pixi (only use if Pixi was installed only for this app)
  -h, --help             Show this help

Notes:
  - This script removes only this project's known HuggingFace model cache by
    default, not the whole ~/.cache/huggingface directory.
  - macOS permissions may remain visible in System Settings until macOS prunes
    its privacy database; that is normal.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -y|--yes)
            ASSUME_YES=1
            REMOVE_INSTALL_DIR=1
            ;;
        --install-dir)
            [ "$#" -ge 2 ] || { echo "Error: --install-dir needs a path"; exit 1; }
            INSTALL_DIR="$2"
            shift
            ;;
        --remove-install-dir) REMOVE_INSTALL_DIR=1 ;;
        --keep-install-dir) REMOVE_INSTALL_DIR=0 ;;
        --keep-models) REMOVE_MODELS=0 ;;
        --remove-pixi) REMOVE_PIXI=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

confirm() {
    local prompt="$1"
    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    local answer=""
    if [ -r /dev/tty ]; then
        printf "%s [y/N]: " "$prompt" >/dev/tty
        IFS= read -r answer </dev/tty || true
    else
        printf "%s [y/N]: " "$prompt"
        IFS= read -r answer || true
    fi
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

remove_path() {
    local path="$1"
    case "$path" in
        ""|"/"|"$HOME"|"$HOME/"|"$HOME/."|"$HOME/..")
            echo "Refusing to remove unsafe path: $path"
            exit 1
            ;;
    esac
    if [ -e "$path" ] || [ -L "$path" ]; then
        rm -rf "$path"
        echo "Removed: $path"
    else
        echo "Already absent: $path"
    fi
}

kill_pid_file() {
    local pid_file="$1"
    [ -f "$pid_file" ] || return 0
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "Stopping running daemon PID $pid"
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null || true
    fi
}

hf_cache_dir_for_model() {
    local model="$1"
    printf "%s/.cache/huggingface/hub/models--%s\n" "$HOME" "${model//\//--}"
}

echo "=== tigris-whisper uninstall ==="
echo "Install directory: $INSTALL_DIR"
echo ""

if [ "$OS" = "Darwin" ]; then
    APP_DIR="${WHISPER_APP_PARENT:-$HOME/Applications}/${WHISPER_APP_NAME:-tigris-whisper.app}"
    LOG_DIR="$HOME/Library/Logs/tigris-whisper"
    STATE_DIR="$HOME/Library/Application Support/tigris-whisper"
    PID_FILE="$STATE_DIR/daemon.pid"

    kill_pid_file "$PID_FILE"
    remove_path "$APP_DIR"
    remove_path "$LOG_DIR"
    remove_path "$STATE_DIR"
    remove_path "$HOME/.cache/whisper.cpp/mlx_server.log"
    remove_path "$HOME/.cache/whisper.cpp/mlx_audio_server.log"
else
    remove_path "$HOME/.local/share/whisper_hotkey.log"
fi

if [ "$REMOVE_MODELS" -eq 1 ]; then
    DEFAULT_MODEL="mlx-community/whisper-large-v3-turbo-q4"
    MODEL="${WHISPER_MLX_MODEL:-$DEFAULT_MODEL}"
    remove_path "$(hf_cache_dir_for_model "$DEFAULT_MODEL")"
    if [ "$MODEL" != "$DEFAULT_MODEL" ]; then
        remove_path "$(hf_cache_dir_for_model "$MODEL")"
    fi
    remove_path "$(hf_cache_dir_for_model "mlx-community/whisper-small-mlx-q4")"
    remove_path "$(hf_cache_dir_for_model "mlx-community/whisper-base-mlx-q4")"
    remove_path "$(hf_cache_dir_for_model "mlx-community/whisper-large-v3-turbo")"
    # mlx_audio model families (Nemotron / Omnilingual / Cohere), incl. any configured one
    [ -n "${WHISPER_MLX_AUDIO_MODEL:-}" ] && remove_path "$(hf_cache_dir_for_model "$WHISPER_MLX_AUDIO_MODEL")"
    for m in \
        mlx-community/nemotron-3.5-asr-streaming-0.6b \
        mlx-community/omniASR-LLM-300M mlx-community/omniASR-LLM-1B \
        mlx-community/omniASR-LLM-3B mlx-community/omniASR-LLM-7B \
        mlx-community/cohere-transcribe-03-2026-mlx-8bit; do
        remove_path "$(hf_cache_dir_for_model "$m")"
    done
else
    echo "Kept HuggingFace model cache"
fi

if [ "$REMOVE_PIXI" -eq 1 ]; then
    if confirm "Remove ~/.pixi? This may affect other projects"; then
        remove_path "$HOME/.pixi"
    fi
else
    echo "Kept ~/.pixi because Pixi may be shared by other projects"
fi

if [ "$REMOVE_INSTALL_DIR" -eq 1 ] || confirm "Remove install directory '$INSTALL_DIR'"; then
    cd "$HOME"
    remove_path "$INSTALL_DIR"
else
    echo "Kept install directory: $INSTALL_DIR"
fi

echo ""
echo "Uninstall complete."
