# 02 · Progress

## In flight
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

## Done
| Date | Task | Verified by |
|---|---|---|
| 2026-05-31 | Phase 4.13: post-install model switcher | Added `scripts/change_mlx_model.sh` so users can pick a profile or pass a HF model ID; it updates `tigris-whisper.env` and can restart the Mac app with `--restart` |
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
