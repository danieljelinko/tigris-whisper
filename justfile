# tigris-whisper — hotkey Whisper daemon. `run.sh` auto-detects platform + backend.
# Every user-facing action is a recipe here. Run `just` for the list.

# List recipes.
default:
    @just --list

# Start the daemon (auto-detects platform + backend). Foreground; Ctrl+C to stop.
# Usage: `just run` · `WHISPER_LANG=fr just run` · `just run --print-backend`
run *args:
    ./run.sh {{args}}

# Install system deps + backend + default model for this host.
# Usage: `just install` · `WHISPER_BACKEND=docker_cuda just install`
install *args:
    ./install.sh {{args}}

# Remove generated app/state/logs/model cache for this host.
# Usage: `just uninstall` · `just uninstall -y`
uninstall *args:
    ./uninstall.sh {{args}}

# Switch the ASR model (catalog-driven; also picks the right backend for this host).
# Usage: `just model` (interactive) · `just model fast --restart` · `just model nemotron-3.5-0.6b --restart`
model *args:
    ./scripts/change_model.sh {{args}}

# macOS only — control the background app wrapper (~/Applications/tigris-whisper.app).
status:
    ./scripts/control_mac_app.sh status

start:
    ./scripts/control_mac_app.sh start

stop:
    ./scripts/control_mac_app.sh stop

restart:
    ./scripts/control_mac_app.sh restart

logs:
    ./scripts/control_mac_app.sh logs

# macOS only — verify the install end-to-end (model warmup + a real transcription).
smoke-test:
    ./scripts/test_mac_setup.sh

# Optional whisper.cpp Metal/CPU fallback backend.
install-whispercpp:
    ./scripts/101_install_whispercpp.sh

# Optional CrispASR backend (serves Cohere Transcribe on Linux CPU).
install-crispasr:
    ./scripts/install_crispasr.sh

# Run the test suite.
test *args:
    uv run pytest {{args}}

# Run the benchmark suite across backends/languages.
# Usage: `just benchmark --backends faster_whisper,whispercpp_cpu --detailed --update-readme`
benchmark *args:
    uv run python benchmark/run_suite.py {{args}}
