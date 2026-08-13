#!/usr/bin/env bash
# bootstrap.sh — download and install tigris-whisper from scratch.
#
# One-liner install (copy and paste into Terminal):
#
#   curl -fsSL https://raw.githubusercontent.com/danieljelinko/tigris-whisper/main/bootstrap.sh | bash
#
# What this script does:
#   1. Asks where to install (default: ~/Developer/tigris-whisper on Mac)
#   2. Fetches the repo — git clone if git exists, else a curl tarball (no Xcode CLT!)
#   3. Runs ./install.sh (installs Pixi + Python wheels incl. mlx-whisper on macOS)
#
# Notably, the default macOS path needs NO Xcode Command Line Tools and NO
# Homebrew: the tarball comes via curl (built in), Pixi provides Python, and
# mlx-whisper installs as prebuilt wheels. The only large download is the Whisper
# model itself, which mlx fetches on first transcription. Size depends on the
# selected model.
#
# Env overrides:
#   WHISPER_INSTALL_DIR=~/my-dir   skip the directory prompt
#   WHISPER_REF=some-branch        which git ref to fetch
#   WHISPER_MLX_MODEL=repo/id      skip the macOS model prompt
#   TIGRIS_SKIP_SMOKE_TEST=1       skip automatic Mac smoke test/model warmup
#   TIGRIS_SKIP_TRANSCRIPTION_TEST=1 skip the real sample transcription check
#
# Re-running is safe — each step is skipped if already done.
# Supported OS: macOS (Apple Silicon), Linux (Ubuntu/Debian/Fedora).

set -euo pipefail

REPO_SLUG="danieljelinko/tigris-whisper"
REPO_URL="https://github.com/${REPO_SLUG}.git"
REPO_REF="${WHISPER_REF:-main}"
OS="$(uname -s)"

setup_log() {
    [ "${TIGRIS_NO_LOG:-0}" = "1" ] && return 0
    local log_dir log_file
    if [ "$OS" = "Darwin" ]; then
        log_dir="$HOME/Library/Logs/tigris-whisper"
    else
        log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/tigris-whisper"
    fi
    mkdir -p "$log_dir"
    log_file="$log_dir/bootstrap-$(date +%Y%m%d-%H%M%S).log"
    ln -sf "$log_file" "$log_dir/bootstrap-latest.log"
    exec > >(tee -a "$log_file") 2>&1
    echo "Logging bootstrap output to: $log_file"
    echo "Latest bootstrap log: $log_dir/bootstrap-latest.log"
    echo ""
}
setup_log

# On macOS the Apple-recognised folder for dev projects is ~/Developer (Finder
# gives it a hammer icon). On Linux, ~ keeps it simple. Either is a fine default.
if [ "$OS" = "Darwin" ]; then DEFAULT_DIR="$HOME/Developer/tigris-whisper"
else                          DEFAULT_DIR="$HOME/tigris-whisper"; fi

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║             Tigris Whisper bootstrap             ║"
echo "║  Hold a key → speak → release → text is pasted   ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ─── Choose install directory ─────────────────────────────────────────────────
# WHISPER_INSTALL_DIR env var skips the prompt. When piped via `curl | bash`,
# stdin is the script, so read the answer from /dev/tty.
if [ -n "${WHISPER_INSTALL_DIR:-}" ]; then
    INSTALL_DIR="$WHISPER_INSTALL_DIR"
elif [ -r /dev/tty ]; then
    printf "Where should it install? [%s]: " "$DEFAULT_DIR"
    read -r REPLY < /dev/tty || REPLY=""
    INSTALL_DIR="${REPLY:-$DEFAULT_DIR}"
else
    INSTALL_DIR="$DEFAULT_DIR"   # non-interactive (no terminal): use default
fi

# Expand a leading ~ (read does not expand it).
case "$INSTALL_DIR" in
    "~")    INSTALL_DIR="$HOME" ;;
    "~/"*)  INSTALL_DIR="$HOME/${INSTALL_DIR#\~/}" ;;
esac

echo ""
echo "Install directory: $INSTALL_DIR"
echo ""

# ─── Fetch the repo (git if available, else tarball — no Xcode CLT) ───────────
git_works() {
    # macOS ships /usr/bin/git as a stub: command -v finds it, xcode-select -p
    # can return 0 with a placeholder path, but running the stub triggers the
    # Xcode CLT install dialog. The only reliable check is the binary path itself —
    # the stub is always exactly /usr/bin/git; a real git (CLT or Homebrew) is
    # at /Library/Developer/CommandLineTools/usr/bin/git or /opt/homebrew/bin/git.
    local gp
    gp="$(command -v git 2>/dev/null || true)"
    [ -n "$gp" ] || return 1              # no git binary at all
    # /usr/bin/git on macOS is a stub that triggers the Xcode CLT install dialog;
    # on Linux it is the real binary, so only skip it on Darwin.
    [ "$OS" = "Darwin" ] && [ "$gp" = "/usr/bin/git" ] && return 1
    git --version >/dev/null 2>&1         # real git: verify it actually works
}

fetch_repo() {
    if [ -d "$INSTALL_DIR/.git" ]; then
        echo "✓ git checkout already at $INSTALL_DIR — pulling latest…"
        git -C "$INSTALL_DIR" pull --ff-only && return 0
    fi

    # Existing non-git directory (e.g. a previous tarball install) — ask to replace.
    if [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        echo "An existing install was found at: $INSTALL_DIR"
        local _reply=""
        if [ -r /dev/tty ]; then
            printf "Remove it and reinstall the latest version? [y/N]: "
            read -r _reply < /dev/tty || _reply=""
        fi
        case "$(printf '%s' "$_reply" | tr '[:upper:]' '[:lower:]')" in
            y|yes)
                local backup_dir="${INSTALL_DIR}.backup.$(date +%Y%m%d%H%M%S)"
                echo "Moving existing install aside → $backup_dir"
                mv "$INSTALL_DIR" "$backup_dir"
                ;;
            *)
                echo "Keeping existing install. Re-run bootstrap and choose a different directory,"
                echo "or cd into $INSTALL_DIR and run: git pull && ./install.sh"
                exit 0
                ;;
        esac
    fi

    if git_works; then
        echo "Cloning with git (ref: $REPO_REF)…"
        git clone --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR"
    else
        # No working git (macOS stub or missing binary) → tarball via curl.
        echo "git not available — downloading tarball with curl (no Xcode CLT needed)…"
        local url="https://github.com/${REPO_SLUG}/archive/refs/heads/${REPO_REF}.tar.gz"
        mkdir -p "$INSTALL_DIR"
        # --strip-components=1 drops the GitHub-added top-level dir name.
        curl -fsSL "$url" | tar -xz --strip-components=1 -C "$INSTALL_DIR"
        echo "✓ Downloaded to $INSTALL_DIR"
        echo "  (No git history — to update later, re-run this bootstrap. For development,"
        echo "   install git via 'xcode-select --install' and re-clone.)"
    fi
}
fetch_repo

# ─── Choose macOS model ───────────────────────────────────────────────────────
# Catalog-driven: a model choice can imply a *different backend* than Whisper
# (Nemotron/Cohere run on mlx_audio, not mlx-whisper), so the picker resolves the
# chosen key through src/model_catalog.py and writes WHISPER_BACKEND + the
# backend's model env var + TIGRIS_MODEL_PROFILE. run.sh re-derives the backend on
# launch. Same single source of truth used by scripts/change_model.sh.

# Find a python3 that won't trigger the macOS Xcode-CLT stub dialog. /usr/bin/python3
# on a CLT-less Mac is a stub (like /usr/bin/git); running it pops the install dialog,
# which the tarball path exists to avoid. Skip it; the catalog is stdlib-only.
resolve_picker_python() {
    local p pp
    for p in python3 python; do
        pp="$(command -v "$p" 2>/dev/null || true)"
        [ -n "$pp" ] || continue
        [ "$OS" = "Darwin" ] && [ "$pp" = "/usr/bin/python3" ] && continue
        printf '%s' "$pp"; return 0
    done
    return 1
}

choose_mac_model() {
    [ "$OS" = "Darwin" ] || return 0

    local catalog_py="$INSTALL_DIR/src/model_catalog.py"
    local known="mlx,mlx_audio"
    local PY profile backend env_var model key reply
    PY="$(resolve_picker_python || true)"

    # Can we run the catalog here? (python available + catalog present + it answers)
    local use_catalog=0
    if [ -n "$PY" ] && [ -f "$catalog_py" ] && \
       "$PY" "$catalog_py" list --system Darwin --known-backends "$known" >/dev/null 2>&1; then
        use_catalog=1
    fi

    if [ -n "${WHISPER_MLX_MODEL:-}" ]; then
        # Env-skip shortcut: a raw mlx-whisper repo id forces the mlx backend.
        profile="custom-env"; backend="mlx"; env_var="WHISPER_MLX_MODEL"; model="$WHISPER_MLX_MODEL"
    elif [ "$use_catalog" = "1" ]; then
        # Determine the chosen catalog key: env seam, then interactive menu, then default.
        if [ -n "${WHISPER_MODEL_KEY:-}" ]; then
            key="$WHISPER_MODEL_KEY"
        elif [ -r /dev/tty ]; then
            echo "Choose the local transcription model for this Mac:"
            echo "  Whisper profiles are multilingual; new families list their own license/langs."
            echo "  Whisper language list: https://github.com/openai/whisper/blob/main/whisper/tokenizer.py"
            echo ""
            local keys=() i=0 k label lic langs
            while IFS=$'\t' read -r k label lic langs; do
                keys+=("$k"); i=$((i + 1))
                printf '  %2d. %-38s %-16s %s\n' "$i" "$label" "[$lic]" "$langs"
            done < <("$PY" "$catalog_py" labels --system Darwin --known-backends "$known")
            echo ""
            printf "Model choice [1]: "
            read -r reply < /dev/tty || reply=""
            reply="${reply:-1}"
            key="${keys[$((reply - 1))]:-${keys[0]}}"
        else
            key="balanced"   # non-interactive: safe Whisper default, no regression
        fi
        # Resolve key → backend, env var, model (single source of truth).
        local resolved
        resolved="$("$PY" "$catalog_py" resolve "$key" --system Darwin)"
        backend="$(printf '%s' "$resolved" | cut -f1)"
        env_var="$(printf '%s' "$resolved" | cut -f2)"
        model="$(printf '%s' "$resolved" | cut -f3)"
        profile="$key"
    else
        # No usable python3 yet (e.g. CLT-less Mac pre-install): static Whisper default.
        profile="balanced"; backend="mlx"; env_var="WHISPER_MLX_MODEL"
        model="mlx-community/whisper-large-v3-turbo-q4"
    fi

    {
        echo "# Generated by bootstrap.sh. Re-pick later with: ./scripts/change_model.sh"
        printf 'export TIGRIS_MODEL_PROFILE=%q\n' "$profile"
        printf 'export WHISPER_BACKEND=%q\n' "$backend"
        printf 'export %s=%q\n' "$env_var" "$model"
    } > "$INSTALL_DIR/tigris-whisper.env"
    export TIGRIS_MODEL_PROFILE="$profile"
    export WHISPER_BACKEND="$backend"
    export "$env_var=$model"

    echo ""
    echo "Selected model: $model"
    echo "Backend: $backend"
    echo "Saved model config: $INSTALL_DIR/tigris-whisper.env"
}
choose_mac_model

# ─── Run installer ────────────────────────────────────────────────────────────
echo ""
echo "Running installer…"
echo ""
cd "$INSTALL_DIR"
if [ ! -f install.sh ]; then
    echo "Error: install.sh is missing from $INSTALL_DIR."
    echo "Fetched ref: $REPO_REF"
    echo "This usually means bootstrap downloaded the wrong branch or an old install directory is in the way."
    echo "Try:"
    echo "  WHISPER_REF=main bash bootstrap.sh"
    exit 1
fi
bash install.sh

# ─── Warm up / smoke test ─────────────────────────────────────────────────────
if [ "$OS" = "Darwin" ] && [ "${TIGRIS_SKIP_SMOKE_TEST:-0}" != "1" ]; then
    echo ""
    echo "Running Mac setup test and model warmup…"
    echo "This warms the model cache, starts the local mlx-whisper server,"
    echo "and transcribes a tiny bundled sample audio file as a real end-to-end check."
    echo "Selected model: ${WHISPER_MLX_MODEL:-mlx-community/whisper-large-v3-turbo-q4}"
    echo "If this is the first run, the selected Whisper model downloads now."
    echo "That can take several minutes; Hugging Face progress bars will print while it works."
    echo "The sample transcription can take 30–120s on first run while MLX initializes."
    echo "To skip the real transcription check: TIGRIS_SKIP_TRANSCRIPTION_TEST=1"
    echo ""
    bash ./scripts/test_mac_setup.sh
elif [ "$OS" = "Darwin" ]; then
    echo ""
    echo "Skipping Mac smoke test/model warmup because TIGRIS_SKIP_SMOKE_TEST=1."
    echo "Run it later with: cd $INSTALL_DIR && ./scripts/test_mac_setup.sh"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
if [ "$OS" = "Darwin" ]; then
    echo "**********************************************************************"
    echo "WHAT TO DO NEXT"
    echo "**********************************************************************"
    echo ""
    echo "1. Launch the application:"
    echo "   open ~/Applications/tigris-whisper.app"
    echo ""
    echo "   To find it visually in Finder:"
    echo "   open -R ~/Applications/tigris-whisper.app"
    echo "   This reveals the app in your user Applications folder."
    echo "   Note: Finder's sidebar Applications may show /Applications instead,"
    echo "   so tigris-whisper may not appear there."
    echo ""
    echo "2. If macOS asks for Microphone access, click Allow."
    echo "   The app asks for Microphone access at startup so it appears in settings."
    echo ""
    echo "3. Open macOS permissions:"
    echo "   System Settings → Privacy & Security"
    echo ""
    echo "4. Confirm Microphone is enabled:"
    echo "   Privacy & Security → Microphone → enable tigris-whisper"
    echo ""
    echo "5. Enable Input Monitoring (REQUIRED for the hotkey to fire):"
    echo "   Privacy & Security → Input Monitoring → enable tigris-whisper"
    echo ""
    echo "6. Enable Accessibility (for the automatic paste):"
    echo "   Privacy & Security → Accessibility → enable tigris-whisper"
    echo ""
    echo "7. Use it:"
    echo "   Hold  Ctrl + Option + Cmd  to record"
    echo "   Release Ctrl to transcribe and paste into the active app"
    echo ""
    echo "Notes:"
    echo "   • The app is the normal user path and runs the daemon in the background."
    echo "   • Model config: $INSTALL_DIR/tigris-whisper.env"
    echo "   • Install logs: ~/Library/Logs/tigris-whisper/bootstrap-latest.log"
    echo "                   ~/Library/Logs/tigris-whisper/install-latest.log"
    echo "   • To change model later: cd $INSTALL_DIR && ./scripts/change_model.sh --restart"
    echo "   • To check/stop/restart/logs: cd $INSTALL_DIR && ./scripts/control_mac_app.sh status|stop|restart|logs"
    echo "   • Manual/developer mode is: cd $INSTALL_DIR && ./run.sh"
    echo "   • If you use manual mode, grant permissions to your terminal app instead."
    echo "   • To uninstall later: cd $INSTALL_DIR && ./uninstall.sh"
    echo ""
    echo "**********************************************************************"
else
    echo "**********************************************************************"
    echo "WHAT TO DO NEXT"
    echo "**********************************************************************"
    echo ""
    echo "1. Start the daemon:"
    echo "   cd $INSTALL_DIR && ./run.sh"
    echo ""
    echo "2. Use it:"
    echo "   Hold  Ctrl + Alt + Space  to record"
    echo "   Release Ctrl to transcribe and paste into the active app"
    echo ""
    echo "3. To uninstall later:"
    echo "   cd $INSTALL_DIR && ./uninstall.sh"
    echo ""
    echo "**********************************************************************"
fi
