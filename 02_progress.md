# 02 · Progress

## In flight
- New-models Phase 2 (Linux+NVIDIA GPU): **Nemotron `nemo_cuda` VERIFIED end-to-end on feynman's RTX 5070** — real transcript `'Testing Whisper Transcription One Two Three Four Five.'`. **Cohere/Omnilingual `transformers_cuda` remain wired but unverified** (the `transformers.pipeline` loader may need `trust_remote_code`/a non-pipeline path for fairseq2-based Omnilingual — confirm on first real run).
- New-models Mac picker/warm-up **landed & green on Linux** (pytest 65, install/uninstall 59, dispatch 6). Built on a Linux box, so **two on-device steps remain on the Air**: (1) step-1 `mlx_audio.stt.load(id).generate(wav).text` for Nemotron + Cohere (Hub-existence verified, load/transcribe not); (2) fresh bootstrap → pick a new model → warm-up downloads with visible progress → real hotkey→transcribe→paste. Omnilingual is intentionally not offered on Mac (no MLX build on the Hub yet).
- Phase 3.6: Linux end-to-end test — bootstrap → faster-whisper model download → `./run.sh` → hotkey→paste on Feynman (Linux, no GPU).
- Phase 4.4: manual GUI test — launch **tigris-whisper.app** from Finder or
  `open`, confirm the startup Microphone prompt appears, grant Accessibility,
  confirm hotkey→paste in a real text field.

## Next
- On the Air: reinstall/regenerate app → choose a model → launch it so macOS
  requests Microphone at startup → grant/verify Mic + Accessibility for
  **tigris-whisper** → manual hotkey→paste check.
- If testing with `./run.sh`, grant Accessibility to the terminal app. Clipboard
  copy working but paste failing means the remaining failure is the synthetic
  Cmd+V path, not transcription.
- If the Mac log says `This process is not trusted`, the current launcher still
  lacks Accessibility permission and the global hotkey cannot work until restart
  after granting it.

## Blocked
- Manual permission/hotkey validation still requires the Mac UI session. SSH can
  verify install and smoke tests, but not the TCC prompts/user gesture path.

## Next
- Phase 3 real CPU verify: run `./scripts/install_crispasr.sh` (fetches the prebuilt `crispasr-linux-x86_64` binary) → `change_model.sh cohere-transcribe-2b` → first launch pulls the ~2.5 GB Cohere GGUF → transcribe sample. Needs approval (external binary, like NeMo).
- Phase 2 follow-up: verify Cohere/Omnilingual `transformers_cuda` on the GPU; patch `get_pipe()` if `trust_remote_code`/a non-pipeline loader is needed.

## Done
| Date | Task | Verified by |
| 2026-06-26 | New-models Phase 3 (Linux CPU) plumbing: `crispasr` backend serves Cohere Transcribe GGUF via CrispASR's native OpenAI server (`crispasr --server --backend cohere`), mirroring the whisper.cpp native-server pattern — `scripts/lib/backend_crispasr.sh` + `scripts/install_crispasr.sh` (fetches the prebuilt `crispasr-linux-<arch>` release binary; `CRISPASR_VARIANT` for avx512/cuda) + `run.sh` case + skipped integration test. Added to `IMPLEMENTED_BACKENDS` + benchmark `backend_launch.py`. Picker now lists Cohere on a linux_cpu host. | `uv run pytest` 71 passed/1 skipped; `WHISPER_BACKEND=crispasr run.sh --print-backend`; release asset `crispasr-linux-x86_64.tar.gz` confirmed to exist. **Real binary+GGUF run pending.** |
| 2026-06-26 | Nemotron `nemo_cuda` works end-to-end on real GPU. Three NeMo gotchas fixed: (1) needs NeMo **git main** for `EncDecRNNTBPEModelWithPrompt` → `backend_nemo.sh` installs `nemo_toolkit[asr] @ git+…@main` (overridable via `WHISPER_NEMO_PKG`); (2) prompt model needs language **per-utterance via a manifest `lang` field** (not bare paths) → `transcribe_audio` writes a temp manifest + `override_config`; (3) CUDA-graph RNNT decoder OOMs/`replay()`-on-None → disabled in `get_model`. Also strips the trailing `<en-US>` tag. | feynman RTX 5070: `transcribe_audio('…/sample_speech.wav','en')` → `'Testing Whisper Transcription One Two Three Four Five.'`; `uv run pytest` 71/71 |
| 2026-06-25 | New-models Phase 2 (Linux+NVIDIA GPU) plumbing: `transformers_cuda` (`src/transformers_asr_server.py`, Cohere/Omnilingual via HF `transformers.pipeline`) + `nemo_cuda` (`src/nemo_asr_server.py`, Nemotron via NeMo `ASRModel`) — Flask, lazy GPU imports, mocked-boundary tests. `scripts/lib/backend_{transformers,nemo}.sh` launch via `uv run --with` (heavy deps on demand, lockfile untouched); `run.sh` cases; added to `change_model.sh` `IMPLEMENTED_BACKENDS` + benchmark `backend_launch.py`. Picker now lists Nemotron/Omnilingual/Cohere on feynman. | `uv run pytest` 71/71; `run.sh --print-backend` for both new overrides; catalog `labels` lists all new models on linux_cuda. **Real GPU load/transcribe pending.** |
| 2026-06-25 | Mac catalog picker + backend-aware warm-up: `bootstrap.sh choose_mac_model` now catalog-driven (writes `WHISPER_BACKEND`+model env+`TIGRIS_MODEL_PROFILE`; Whisper balanced default; `WHISPER_MLX_MODEL`/`WHISPER_MODEL_KEY` skip seams; skips macOS CLT-stub python3). `download_mlx_model.py` backend-aware (mlx→snapshot, mlx_audio→`load`); `backend_mlx_audio.sh` + `test_mac_setup.sh` route through it / reuse `backend_mlx*.sh`. Step-1 catalog ids Hub-verified: Cohere→`-mlx-8bit`, Omnilingual `darwin`→`None` (no MLX build), Nemotron kept. **On-device load/transcribe + hotkey→paste still pending on the Air.** | `uv run pytest` 65/65; `test_install_uninstall.sh` 59/0; `test_run_dispatch.sh` 6/0; catalog ids checked vs live HF Hub |
| 2026-06-25 | New-models Phase 1 (Mac MLX): model catalog (`src/model_catalog.py`) maps model-key→(backend,model,env) per platform; new `mlx_audio` backend (`src/mlx_audio_server.py` + `scripts/lib/backend_mlx_audio.sh` + run.sh case) serves Nemotron 3.5 / Omnilingual / Cohere via mlx-audio; `change_model.sh` now catalog-driven so picking a model flips `WHISPER_BACKEND` seamlessly; registered in benchmark `backend_launch.py`; `pixi.toml` adds mlx-audio; uninstall cleans new caches. Fixed pre-existing `change_model`/dispatch test breakage. | `uv run pytest` 58/58; `test_install_uninstall.sh` 52/0; `test_run_dispatch.sh` 6/0 |
| 2026-06-25 | Floor `numba >=0.60` in pixi.toml — fixes `pixi install` backtracking to numba 0.53.1 (unbuildable sdist on py3.12) on Evi's Mac. Pushed to main. | Cross-platform resolve on Linux (`uv pip compile --python-platform aarch64-apple-darwin --python-version 3.12` → numba 0.65.1 + numpy 2.4.6, both wheel-backed). **Pending on-device confirm: Evi re-runs bootstrap.** |
| 2026-06-08 | Benchmark harness — `benchmark/` dir, eval/client/hardware/backend_launch/run_benchmark/run_suite/readme_snippet; TDD tests (26 green); EN/FR/HU reference texts; manifest.toml; README BENCH markers; add-benchmark-language skill | `uv run python -m pytest` 26/26 |
|---|---|---|
| 2026-06-07 | Phase 3.1–3.5: faster-whisper Linux CPU backend | `src/faster_whisper_server.py`, `scripts/lib/backend_faster_whisper.sh`, `scripts/change_faster_whisper_model.sh`; `backend_select` routes Linux no-GPU → `faster_whisper`; install.sh adds model picker + pre-download |
| 2026-06-07 | Fix Linux bootstrap: git at /usr/bin/git now correctly used on Linux (was rejected as macOS stub) | bootstrap.sh `git_works()` now only skips /usr/bin/git on Darwin |
| 2026-06-07 | Fix Linux install: `python3-dev` added to apt deps (evdev build needs Python.h) | install.sh |
| 2026-06-07 | Fix Linux messages: removed `test_mac_setup.sh` hint from `101_install_whispercpp.sh`; fixed hotkey in bootstrap Linux WHAT TO DO NEXT | 101_install_whispercpp.sh, bootstrap.sh |
|---|---|---|
| 2026-05-31 | Phase 4.14: installer logs for remote debugging | `bootstrap.sh` and `install.sh` now tee all output to timestamped logs plus `bootstrap-latest.log` / `install-latest.log` under `~/Library/Logs/tigris-whisper` on macOS |
| 2026-05-31 | Fixed AppleScript app generation order | Install log showed `osacompile ... errOSASystemError (-1750)` because the target `.app` directory existed before `osacompile`; `create_mac_app.sh` now lets `osacompile` create the bundle first |
| 2026-05-31 | Phase 4.13: post-install model switcher | Added `scripts/change_mlx_model.sh` so users can pick a profile or pass a HF model ID; it updates `tigris-whisper.env` and can restart the Mac app with `--restart` |
| 2026-05-31 | Mac app LaunchServices error -600 fix | `scripts/create_mac_app.sh` now generates a native AppleScript applet with `osacompile` and stores our shell launcher as `Contents/Resources/launcher.sh`; fake-mac tests assert the helper exists |
| 2026-05-31 | Mac smoke test bounded sample transcription | `scripts/test_mac_setup.sh` now explains that it sends a bundled WAV for a real end-to-end check, times it out with `TIGRIS_TRANSCRIPTION_TIMEOUT` default 120s, and supports `TIGRIS_SKIP_TRANSCRIPTION_TEST=1` |
| 2026-05-31 | Phase 4.12: visible model download progress | Added `scripts/download_mlx_model.py`; `run.sh` MLX backend and `scripts/test_mac_setup.sh` pre-download the selected model in the foreground so Hugging Face/tqdm progress bars are visible |
| 2026-05-31 | Mac Accessibility preflight | Daemon now checks `AXIsProcessTrusted()` at startup and logs/notifies clear instructions before pynput's lower-level "process is not trusted" warning; `run.sh` now prints the Mac hotkey as Ctrl+Option+Space |
| 2026-05-31 | Phase 4.10–4.11: model selection + paste diagnostics | Bootstrap writes `tigris-whisper.env`; `run.sh`, smoke test, install, uninstall read it; Mac paste now restores the original frontmost app through System Events and logs/notifies on `osascript` errors; installer/docs say offered models are multilingual and link to OpenAI's language list |
| 2026-05-30 | Phase 4.9: background app lifecycle controls | Added `scripts/control_mac_app.sh status|start|stop|restart|logs`; app wrapper tracks child daemon PID; install/bootstrap print control commands; `tests/test_install_uninstall.sh` → 29 passed |
| 2026-05-30 | Phase 4.8: startup Microphone permission request | Mac daemon now opens a short input stream at startup to trigger/list `tigris-whisper` in Microphone settings; Python compile and test suite green |
| 2026-05-30 | Phase 4.7: bootstrap runs smoke test/model warmup automatically | `tests/test_install_uninstall.sh` covers fake-mac bootstrap invoking smoke test, warning that model download can take several minutes, final numbered `WHAT TO DO NEXT`, Finder launch, and background-start notification |
| 2026-05-30 | Phase 4.6: renamed user-facing product/repo to `tigris-whisper` | GitHub repo renamed first; source now uses `danieljelinko/tigris-whisper`, `~/Developer/tigris-whisper`, `tigris-whisper.app`, `com.danieljelinko.tigris-whisper`; `tests/test_install_uninstall.sh` covers renamed app/install paths |
| 2026-05-30 | Phase 4.5: uninstall script added with tests | `tests/test_install_uninstall.sh` covers fake-mac install wrapper creation and temp-HOME uninstall of app/logs/state/model cache/install dir |
| 2026-05-30 | Phase 4.1–4.3: generated app wrapper | SSH to M1 Air verified the app-wrapper launch path before rename; current `tigris-whisper.app` bundle name, id, logs, and state paths are covered by `tests/test_install_uninstall.sh` |
| 2026-05-30 | Clean Mac tarball install + mlx q4 smoke test green | SSH to M1 Air: clean install from GitHub `main`; `scripts/test_mac_setup.sh` → 10 passed / 0 failed; transcript fixture recognized |
| 2026-05-30 | Mac install path switched to Pixi + ffmpeg | SSH clean install: Pixi env created without Xcode CLT/Homebrew; `ffmpeg` available; mlx-whisper transcribes |
| 2026-05-29 | Switch Mac default to mlx-whisper | 11 pytest + 6 dispatch green on Linux; mlx server contract tested with mocked boundary; real inference deferred to the Air |
| 2026-05-29 | Phase 1 complete (1.2–1.6) | 8 pytest + 5 bash dispatch tests green; whisper.cpp server transcribes real WAV via contract test |
| 2026-05-29 | Phase 1.1: `backend_select.py` + 6 unit tests | `uv run pytest test_backend_select.py` → 6 passed; CLI seam verified for all platforms |
| 2026-05-29 | Phase 0: L4 living-docs scaffold created | files present at repo root |
| 2026-05-29 | Branch `feat/multi-platform-backends` created off main | `git branch --show-current` |
