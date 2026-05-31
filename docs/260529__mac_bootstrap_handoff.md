# Mac Bootstrap Handoff — 2026-05-29

This document hands off the Mac-side work to an agent running on the MacBook Air M1.

---

## What this project is

`tigris-whisper` — hold **Ctrl+Option+Space**, speak, release Ctrl → text
is transcribed locally and pasted into the active window. The repo lives at:
`https://github.com/danieljelinko/tigris-whisper`
Active branch: `main`

The Mac backend is **mlx-whisper** (Apple-Silicon native, installs as Python
wheels in a Pixi environment, no Homebrew, no compiler). Bootstrap asks which
model to use and saves it in `tigris-whisper.env`; the default is
`mlx-community/whisper-large-v3-turbo-q4`. The model downloads from HuggingFace
on first transcription. The bootstrap choices are multilingual Whisper models;
the official language list is
`https://github.com/openai/whisper/blob/main/whisper/tokenizer.py`. The CLI
entry point is `./run.sh`; the user-facing entry point is the generated
`~/Applications/tigris-whisper.app`.

---

## Current situation

The no-Xcode Mac install path is now on `main` and has been verified over SSH on
an M1 Air. The later `tigris-whisper` rename is covered by local
install/uninstall tests until the next clean Mac run:

- bootstrap falls back to a GitHub tarball when only the macOS `/usr/bin/git`
  developer-tool stub is present
- installer uses Pixi and avoids macOS `python3`, Homebrew, and
  `install_name_tool`
- `ffmpeg` is provided by the Pixi environment
- `scripts/test_mac_setup.sh` passes against real audio and real mlx-whisper
- installer creates `~/Applications/tigris-whisper.app`
- bootstrap runs `./scripts/test_mac_setup.sh` automatically on macOS to verify
  setup and warm the model cache
- bootstrap chooses/saves the MLX model before install; `run.sh`, app launch,
  smoke test, and uninstall all read `tigris-whisper.env`
- the app launcher starts the daemon and writes logs to
  `~/Library/Logs/tigris-whisper/daemon.log` (same wrapper behavior was
  SSH-verified before rename; renamed paths are covered by tests)
- no window opens; the app is a background wrapper and posts a macOS
  notification when starting or failing
- `./uninstall.sh` removes the app wrapper, logs/state, known project model
  cache, and optionally the install directory / Pixi

The remaining on-device work is the GUI-only path: launch the app from Finder
or `open`, let macOS request Microphone, grant/verify Microphone +
Accessibility for **tigris-whisper**, then confirm hotkey-to-paste in a real
text field.

To re-test from a clean Mac install, run:

```bash
curl -fsSL https://raw.githubusercontent.com/danieljelinko/tigris-whisper/main/bootstrap.sh | bash
```

Expected output after the directory prompt:
```
git not available — downloading tarball with curl (no Xcode CLT needed)…
✓ Downloaded to /Users/.../Developer/tigris-whisper
Running installer…
```

If you still see a CLT dialog, check:
- Is there a third-party git at a non-`/usr/bin/git` path? (`which git` → if not
  `/usr/bin/git`, the function treats it as real and tries to use it)
- Check the `git_works()` function in `bootstrap.sh` — the path check may need
  adjusting for this machine.

---

## After bootstrap succeeds

### Step 1 — Launch app first

```bash
open ~/Applications/tigris-whisper.app
```

You can also use Finder → Applications → double-click `tigris-whisper.app`.
Launching first matters because the daemon now requests Microphone access at
startup; that request is what makes the app appear under Microphone settings.

### Step 2 — Grant macOS permissions (required)

```
System Settings → Privacy & Security → Microphone    → enable tigris-whisper
System Settings → Privacy & Security → Accessibility → enable tigris-whisper
```

If testing `./run.sh` directly instead of the app, grant both permissions to the
terminal app used to launch it.

### Step 3 — Run the smoke test

```bash
cd ~/Developer/tigris-whisper
./scripts/test_mac_setup.sh
```

This starts the mlx-whisper server, **downloads the selected Whisper model on
first run** — this can take several minutes), POSTs a real WAV, and asserts you get text back.
Checks all pass? The backend works.

### Step 4 — Manual hotkey test

```bash
open ~/Applications/tigris-whisper.app
```

Open any text editor, click in it, then hold **Ctrl+Option+Space**, speak a
sentence, release Ctrl. Text should be pasted. Watch the log:
```bash
tail -f ~/Library/Logs/tigris-whisper/daemon.log
```

---

## Repo orientation

```
run.sh                          manual/dev CLI entry point (auto-detects Mac → mlx)
install.sh                      one-stop installer (called by bootstrap.sh)
bootstrap.sh                    curl-installable; tarball fallback for no-git Macs
src/
  mlx_whisper_server.py         Flask wrapper: POST /v1/audio/transcriptions → mlx
  whisper_hotkey_mac_experimental.py  hotkey + record + paste daemon (Mac)
  backend_select.py             pure dispatch logic (Darwin → "mlx")
scripts/
  create_mac_app.sh             generates ~/Applications/tigris-whisper.app
  lib/backend_mlx.sh            launches the mlx server
  control_mac_app.sh            status/stop/restart/logs for the app wrapper
  test_mac_setup.sh             smoke test (run this first)
  101_install_whispercpp.sh     optional: builds whisper.cpp Metal as fallback
tests/
  test_mlx_server.py            contract test (mocks mlx boundary; runs anywhere)
  test_backend_select.py        unit tests for dispatch logic
  test_run_dispatch.sh          shell dispatch smoke tests
  test_install_uninstall.sh     fake-mac install + temp-HOME uninstall tests
docs/
  mac_setup.md                  full Mac setup guide
01_plan.md                      what's done / what's next
03_decisions.md                 key decisions + rationale
04_learnings.md                 non-obvious gotchas (read before touching things)
```

**Running tests (Linux-safe, all green as of this handoff):**
```bash
uv run pytest -q                    # 11 Python tests
bash tests/test_run_dispatch.sh      # 6 shell assertions
bash tests/test_install_uninstall.sh # 29 shell assertions
```

---

## Phase 2 remaining work (on-device only)

From `01_plan.md`:

- **2.4** App launch triggers/grants permissions; manual hotkey→paste works;
  model/RAM tuned if needed
- **4.4** Launch `tigris-whisper.app` via Finder or `open`, grant permissions
  to that app, confirm manual hotkey→paste

8 GB is tight for non-quantized `large-v3-turbo`; keep the default at
`mlx-community/whisper-large-v3-turbo-q4` for balanced installs. For faster
short dictation, test `mlx-community/whisper-small-mlx-q4` and then
`mlx-community/whisper-base-mlx-q4`; record any later model default change in
`03_decisions.md`.

Phase 3 (Windows, Parakeet, Voxtral) is future work, not committed.

Phase 4.6 is complete: the GitHub repository was renamed first, then the
canonical bootstrap slug, default install directory, app bundle name, bundle id,
logs/state paths, docs, and install/uninstall tests were updated together.

---

## Known constraints (from 04_learnings.md)

- `mlx_whisper` only imports on Apple Silicon — the contract test mocks the boundary
- First transcription downloads the selected model lazily and can take minutes; pre-warm with `test_mac_setup.sh`
- macOS `/usr/bin/git` is a stub — **do not call git without checking the path**
- The daemon uses `pbcopy` + AppleScript paste on macOS to avoid `pyautogui`
- Microphone and Accessibility permission must be granted to **tigris-whisper**
  when launched as the app, or to the terminal app when launched manually
- If copied text does not paste, the likely cause is missing Accessibility for
  the actual launcher identity; the daemon now logs the target app and the
  `osascript` paste error.
