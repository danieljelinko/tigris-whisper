# 01 · Plan — Multi-platform Whisper backends

**Objective.** One self-dispatching launcher `run.sh` that runs the *same* hotkey→transcribe→paste
feature on Linux (NVIDIA & no-GPU) and Mac (M1), by swapping the transcription backend behind the
existing `WHISPER_API` HTTP contract. The daemon is already backend-agnostic, so no client rewrite.

**User-facing objective.** Install, launch, permission grants, smoke tests, and
uninstall should feel like a normal local Mac utility: a named app, clear logs,
clear cache ownership, and a documented cleanup path for generated files and
downloaded models.

**Dispatch.**
```
Darwin              → mlx-whisper (wheels)           (Mac-only verify; whispercpp_metal = fallback)
Linux + NVIDIA GPU  → Docker + --gpus all            (existing, regression-tested here)
Linux, no GPU       → whisper.cpp server, CPU build  (primary dev target here)
```

**TDD note.** whisper.cpp is the shared Linux artifact (CPU here, Metal fallback on Mac). The Mac
*default* is now mlx-whisper (chosen to avoid Homebrew/Xcode-CLT/binary distribution — see
`03_decisions.md`), which cannot run on Linux; its HTTP wrapper is tested here with the mlx call
mocked, and the real inference is verified on-device.

## Phase 0 — L4 scaffold
- [x] Create 01_plan / 02_progress / 03_decisions / 04_learnings

## Phase 1 — Testable on this Linux+GPU box (red/green TDD)
- [x] 1.1 `backend_select.py` + `test_backend_select.py` (Darwin→metal, Linux+GPU→docker, Linux−GPU→cpu, env override)
- [x] 1.2 `101_install_whispercpp.sh` (Linux CPU build + model dl) + `lib/backend_whispercpp.sh` + `test_whispercpp_contract.py` (real sample WAV)
- [x] 1.3 extract Docker bring-up → `lib/backend_docker.sh`; regress GPU path
- [x] 1.4 `run.sh` dispatcher + `--print-backend` dry-run + `test_run_dispatch.sh`
- [x] 1.5 old `00/01/02/03_*.sh` → thin wrappers calling `run.sh`
- [x] 1.6 README "Backends by platform"

## Phase 2 — mlx-whisper Mac backend
- [x] 2.0 `mlx_whisper_server.py` (Flask, lazy mlx import) + `test_mlx_server.py` (mocked boundary)
- [x] 2.1 `lib/backend_mlx.sh` + `run.sh` mlx case; `backend_select` Darwin→`mlx`
- [x] 2.2 installer/bootstrap drop Homebrew on Mac (Pixi wheels/env only); `scripts/test_mac_setup.sh` for mlx
- [x] 2.3 **on-device (the Air):** run `scripts/test_mac_setup.sh` → model downloads + transcribes
- [ ] 2.4 **on-device:** launch app, confirm startup Mic prompt + Accessibility, confirm hotkey→paste with selected model on 8 GB
- [x] 2.5 tarball-based bootstrap (curl fallback when git absent) → zero Xcode CLT for end users

## Phase 3 — faster-whisper Linux CPU backend
Replaces whisper.cpp CPU as the default Linux no-GPU backend. Same `/v1/audio/transcriptions`
contract; no client change. whisper.cpp stays available via `WHISPER_BACKEND=whispercpp_cpu`.
- [x] 3.1 `src/faster_whisper_server.py` (Flask, lazy import) + `scripts/lib/backend_faster_whisper.sh`
- [x] 3.2 `backend_select.py` routes Linux no-GPU → `faster_whisper`
- [x] 3.3 `pyproject.toml` adds `faster-whisper; sys_platform == 'linux'`
- [x] 3.4 `install.sh` model picker for Linux (small/base/tiny/large-v3-turbo); pre-downloads model; saves to `tigris-whisper.env`
- [x] 3.5 `scripts/change_faster_whisper_model.sh` — post-install model switcher
- [ ] 3.6 Linux end-to-end test: bootstrap → model download → `./run.sh` → hotkey→paste

## Phase 3b — Optional future backends / platforms (not committed; see 03_decisions)
All slot into the same pluggable pattern: serve OpenAI-shape `/v1/audio/transcriptions` on :4444, no
client change. All GPU options below are **Linux+NVIDIA only** — none help the Mac.
- [ ] 3b.1 Windows support: `backend_select` "Windows" case + either WSL2 (run.sh as-is, Docker+CUDA works) or native `run.ps1`; win client paste = `ctrl+v`, notify via `win10toast`
- [ ] 3b.2 NVIDIA Parakeet-TDT-0.6B v3 backend (NeMo FastAPI wrapper) — fastest on this box, fits 8 GB VRAM easily
- [ ] 3b.3 Voxtral-Mini-4B backend via vLLM (OpenAI-compatible) — **needs a 4-bit quantized (AWQ/GPTQ) build to fit this box's 8 GB VRAM**; bf16 wants ≥16 GB

## Phase 4 — Mac app wrapper / user-facing install
- [x] 4.1 Generate `tigris-whisper.app` during Mac install, without Xcode/CLT
- [x] 4.2 App launch runs the existing `run.sh` with logs and duplicate-run guard
- [x] 4.3 Permissions attach to `tigris-whisper.app` where macOS allows it; docs explain Mic + Accessibility
- [ ] 4.4 On-device: launch `tigris-whisper.app` from Finder or `open`, trigger/grant permissions, confirm manual hotkey→paste
- [x] 4.5 Add tested uninstall path for app wrapper, logs/state, install dir, and downloaded model cache
- [x] 4.6 Rename user-facing product/repo to `tigris-whisper` after GitHub repo rename is coordinated
- [x] 4.7 Bootstrap automatically runs Mac smoke test/model warmup and makes app launch the normal user path
- [x] 4.8 Mac daemon requests Microphone permission at app startup so it appears in Privacy settings
- [x] 4.9 Add status/stop/restart/log controls for the background Mac app
- [x] 4.10 Add bootstrap-time MLX model selection and persist it for app/run/test/uninstall
- [x] 4.11 Improve Mac paste focus handling and paste-failure diagnostics
- [x] 4.12 Pre-download selected MLX model with visible Hugging Face progress bars
- [x] 4.13 Add helper script to change selected MLX model after install
- [x] 4.14 Tee bootstrap/install output to log files for SSH debugging
- [ ] 4.15 Future polish: menu bar controller, launch-at-login toggle, icon, signing/notarization/DMG
