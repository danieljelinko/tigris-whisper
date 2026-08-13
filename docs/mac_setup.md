# Mac Setup — tigris-whisper

This is the complete guide to running tigris-whisper on a Mac
(Apple Silicon — M1, M2, M3, M4). It covers setup from scratch and includes a
smoke test script you can run to verify everything works before touching the
daemon itself.

---

## What you'll end up with

Hold **Ctrl + Option + Space** → speak → release Ctrl → transcribed text is
pasted into whatever app is in front of you. The transcription runs entirely
locally on your Mac using **mlx-whisper** (Apple's MLX framework, GPU-accelerated
on Apple Silicon). No network call, no API key, no data leaving your machine.

---

## 1. One-line install

Open **Terminal** (search Spotlight → "Terminal"), paste this, and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/danieljelinko/tigris-whisper/main/bootstrap.sh | bash
```

That's it. The bootstrap script handles everything in order:

| Step | What happens |
|---|---|
| Install dir | Asks where to install — press Enter for the default `~/Developer/tigris-whisper` |
| Fetch | Uses `git clone` if git exists, otherwise downloads a clean tarball with `curl` — **no Xcode CLT required** |
| Pixi | Installed via its standalone installer (no compiler needed) |
| Python deps | `pixi install` creates a Python 3.12 env and installs prebuilt wheels, **including mlx-whisper**, plus `ffmpeg` for audio loading |
| App wrapper | Creates `~/Applications/tigris-whisper.app` so users can launch a named app instead of Terminal |
| Model choice | Asks which local MLX Whisper model to use and saves it to `tigris-whisper.env` |
| Model warmup | Runs `./scripts/test_mac_setup.sh`, which pre-downloads the model with Hugging Face progress bars, then starts mlx-whisper |

Bootstrap and installer output are tee'd to log files so remote debugging does
not require copy-pasting Terminal output:

```bash
~/Library/Logs/tigris-whisper/bootstrap-latest.log
~/Library/Logs/tigris-whisper/install-latest.log
```

> `~/Developer` is Apple's recognised folder for development projects (Finder shows it with a hammer icon). To install elsewhere without being prompted:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/danieljelinko/tigris-whisper/main/bootstrap.sh | WHISPER_INSTALL_DIR=~/my-dir bash
> ```

**No Xcode Command Line Tools, no Homebrew, no compiling.** The repo comes as a
`curl` tarball (curl is built into macOS) and Pixi provides Python without
touching macOS developer-tool stubs such as `python3` or `install_name_tool`.
The only large download is the **selected Whisper model, fetched automatically
from HuggingFace during the bootstrap smoke test or the first time you
transcribe**. Size depends on the model you choose. This can take several
minutes; the test shows Hugging Face progress bars while files download. After
the model is cached, later runs are much faster.

If the install directory already exists from an older tarball install, bootstrap
moves it aside to `tigris-whisper.backup.<timestamp>` before extracting.
That keeps reinstall tests clean and avoids stale files from previous attempts.

> **Developers:** if you want a real git checkout (to pull/commit, e.g. continuing
> in Claude Code), install git first with `xcode-select --install` — the bootstrap
> then uses `git clone` instead of the tarball.

> **Prefer manual steps?** See the [manual install section](#manual-install) at the bottom.

---

## 2. Launch the app

After install, launch the app wrapper:

```bash
open ~/Applications/tigris-whisper.app
```

You can also open **Finder → Applications** and double-click
**tigris-whisper.app**.

If you do not see it there, that is expected on some Macs: the app is installed
in your user Applications folder (`~/Applications`), while Finder's sidebar
Applications item often opens the system-wide `/Applications` folder. Reveal the
exact app in Finder with:

```bash
open -R ~/Applications/tigris-whisper.app
```

This is the normal user path. The app runs the same local daemon as `./run.sh`,
but gives macOS a named app for Microphone and Accessibility permissions. It
writes logs to:

```bash
~/Library/Logs/tigris-whisper/daemon.log
```

No window opens. A successful launch runs in the background and posts a macOS
notification. If nothing appears, check the log:

```bash
tail -80 ~/Library/Logs/tigris-whisper/daemon.log
```

Control the background app from the install directory:

```bash
./scripts/control_mac_app.sh status
./scripts/control_mac_app.sh stop
./scripts/control_mac_app.sh restart
./scripts/control_mac_app.sh logs
```

`./run.sh` is the manual/developer path from inside the repo. If you use that
instead, grant permissions to your terminal app, not `tigris-whisper`.

## 2.5. Choose a smaller or larger model

Bootstrap asks for this during install and saves the answer in:

```bash
~/Developer/tigris-whisper/tigris-whisper.env
```

Recommended profiles:

All four choices are multilingual Whisper models, not `.en` English-only
models. OpenAI's tokenizer has the official language list:
<https://github.com/openai/whisper/blob/main/whisper/tokenizer.py>.

| Profile | Model | Language scope | Recommendation |
|---|---|---|---|
| Balanced | `mlx-community/whisper-large-v3-turbo-q4` | Multilingual | Default for M1/M2/M3/M4, especially 8 GB Macs |
| Fast | `mlx-community/whisper-small-mlx-q4` | Multilingual | Lower latency for short dictation; more errors |
| Very fast | `mlx-community/whisper-base-mlx-q4` | Multilingual | Fastest practical option; use only if accuracy is acceptable |
| Best accuracy | `mlx-community/whisper-large-v3-turbo` | Multilingual | Prefer on 16 GB+ Macs or for noisy/multilingual/technical speech |

OpenAI notes that Whisper performance varies by language and amount of training
data, so "supported" does not mean equally accurate in every language. For
English-only dictation there are smaller `.en` Whisper variants in the broader
MLX collection, but tigris-whisper does not offer those in bootstrap because the
default goal is multilingual local dictation.

You can override for a single manual run:

```bash
WHISPER_MLX_MODEL=mlx-community/whisper-small-mlx-q4 ./run.sh
```

To change the installed model permanently, use the helper script:

```bash
cd ~/Developer/tigris-whisper
./scripts/change_model.sh
```

It rewrites `tigris-whisper.env`. Pass `--restart` to restart the app after
saving:

```bash
./scripts/change_model.sh fast --restart
```

## 3. Grant macOS permissions

**This step is required.** Without it, the daemon starts but recording and/or
paste will silently fail. Launch the app first so macOS can ask for Microphone
access at startup; this is what makes it appear in Microphone settings. If you
run `./run.sh` manually, grant permissions to your terminal app instead.

### Microphone
> System Settings → Privacy & Security → **Microphone**
> Enable **tigris-whisper** after launching the app

### Input Monitoring (the hotkey)
> System Settings → Privacy & Security → **Input Monitoring**
> Enable **tigris-whisper** (or your terminal app if running `./run.sh`)

This is what lets the daemon **receive** the Ctrl+Option+Space hotkey. Without
it the daemon still starts, but the hotkey is silently dead and your keystrokes
go to whatever app is focused. It is a **separate** permission from Accessibility
(a common macOS gotcha — Accessibility being on does not cover this).

### Accessibility (the automatic paste)
> System Settings → Privacy & Security → **Accessibility**
> Enable **tigris-whisper** (or your terminal app if running `./run.sh`)

This lets the daemon **post** the ⌘V paste into the active app. Without it the
transcript is still copied to the clipboard; you just paste it manually.

When you first run the daemon, macOS may pop up permission dialogs — click
**Allow**/**Open System Settings**. If they don't pop up and the hotkey doesn't
work, check these settings manually. The daemon logs which permission is missing
on startup (`Input Monitoring preflight OK` / `Accessibility preflight OK`).

---

## 4. Verify / Warm Model

```bash
cd ~/Developer/tigris-whisper   # or wherever you chose to install
./scripts/test_mac_setup.sh
```

Bootstrap runs this automatically on macOS unless you set
`TIGRIS_SKIP_SMOKE_TEST=1`. It checks every component and warms the model cache:

| Check | What it verifies |
|---|---|
| Hardware | Apple Silicon chip detected |
| Python | `pixi install` succeeds; Flask and daemon dependencies import |
| **Model warmup** | Pre-downloads the selected model with Hugging Face progress bars |
| **End-to-end** | Starts the mlx server, POSTs a tiny bundled WAV, asserts text comes back |
| Dispatch | `run.sh --print-backend` returns `mlx` |
| Permissions | Prints reminder (cannot test programmatically) |

All checks green? You're ready. The first run downloads the selected model, so
this test may take several minutes the very first time. The real sample
transcription can take 30-120 seconds while MLX initializes/compiles. If you
only want install verification and model warmup, skip that part with:

```bash
TIGRIS_SKIP_TRANSCRIPTION_TEST=1 ./scripts/test_mac_setup.sh
```

---

## 5. Run the daemon

```bash
open ~/Applications/tigris-whisper.app
```

Or run from the repo:

```bash
./run.sh                   # manual/dev mode: auto-detects Mac → mlx-whisper
WHISPER_LANG=fr ./run.sh   # French
WHISPER_LANG=hu ./run.sh   # Hungarian
```

Hold **Ctrl + Option + Space** to start recording.  
Release **Ctrl** to stop and transcribe.  
The text is pasted automatically into the active window.

View logs:
```bash
tail -f ~/whisper_hotkey_mac.log
tail -f ~/Library/Logs/tigris-whisper/daemon.log   # app wrapper log
```

---

## Uninstall

From the install directory:

```bash
cd ~/Developer/tigris-whisper   # or wherever you installed it
./uninstall.sh
```

The uninstaller removes:

| Item | Default |
|---|---|
| `~/Applications/tigris-whisper.app` | removed |
| app logs/state under `~/Library` | removed |
| known mlx-whisper HuggingFace model cache | removed |
| install directory/repo | asks before removing |
| `~/.pixi` | kept, unless you pass `--remove-pixi` |

Fully unattended removal:

```bash
cd ~/Developer/tigris-whisper
./uninstall.sh --yes
```

Keep downloaded models:

```bash
./uninstall.sh --keep-models
```

The script intentionally does not wipe the whole HuggingFace cache or Pixi by
default because those folders may be shared with other local ML projects.

---

## Troubleshooting

### Hotkey doesn't respond
The hotkey needs **Input Monitoring**, not Accessibility. If keystrokes leak into
the focused app (e.g. `^@` shows up in your terminal) and no `Recording started`
line appears in the log, Input Monitoring is missing.
- Check the startup log: it prints `Input Monitoring preflight OK` when granted,
  or a warning naming the missing permission when not.
- Grant **Input Monitoring** (step 3): System Settings → Privacy & Security →
  **Input Monitoring**.
- If you launched with `./run.sh`, enable your terminal app (Terminal, iTerm, or
  VS Code), then fully quit and restart `./run.sh` — macOS only applies the new
  permission to newly launched processes.
- If you launched with `open ~/Applications/tigris-whisper.app`, enable
  **tigris-whisper**, then restart the app.
- Accessibility is a different permission that only affects the automatic paste
  (see "Text is copied but not pasted" below).

### Text is copied but not pasted
- If you launched with `open ~/Applications/tigris-whisper.app`, grant
  Accessibility to **tigris-whisper**.
- If you launched with `./run.sh`, grant Accessibility to your terminal app
  (Terminal, iTerm, or VS Code), not only to `tigris-whisper`.
- The transcript remains in the clipboard, so you can press Cmd+V manually while
  checking the permission.
- Check `~/whisper_hotkey_mac.log`; paste failures now include the underlying
  `osascript` error from macOS.

### Recording starts but no text appears
- Check Microphone permission (step 4).
- Watch `~/whisper_hotkey_mac.log` for errors.
- Verify the server is running: `curl -s http://localhost:4444/v1/audio/transcriptions`
  (should return a 400 or 422, not "connection refused").

### First transcription hangs for a long time
That's the one-time selected model download from Hugging Face. Current setup
pre-downloads the model before the server starts, so you should see progress
bars directly in Terminal during `bootstrap.sh`, `./scripts/test_mac_setup.sh`,
or manual `./run.sh`. Once cached, later runs are much faster.

### Transcription is slow even after the model is cached
- Confirm you're on Apple Silicon (`uname -m` → `arm64`). mlx only accelerates there.
- 8 GB Macs are tight; close memory-hungry apps. Try `small-mlx-q4` or
  `base-mlx-q4` from the model section if the default still feels slow.
- As a fallback you can switch to whisper.cpp: run `./scripts/101_install_whispercpp.sh`
  then `WHISPER_BACKEND=whispercpp_metal ./run.sh`.

### `mlx_whisper` import fails
You're almost certainly not on Apple Silicon, or `pixi install` didn't run. mlx is
Apple-Silicon-only. Re-run `./install.sh` on an M-series Mac.

---

## Manual install

If you prefer to run steps yourself instead of the bootstrap one-liner:

```bash
# 1. Install Xcode Command Line Tools (opens a dialog — click Install). Gives you git.
xcode-select --install

# 2. Install Pixi
curl -fsSL https://pixi.sh/install.sh | sh
source ~/.pixi/env   # or restart Terminal

# 3. Clone and install (Pixi pulls Python and mlx-whisper wheels — no compiler, no brew)
git clone https://github.com/danieljelinko/tigris-whisper.git
cd tigris-whisper
./install.sh
```

Then continue from step 2 (Launch the app) above. No Homebrew required for the
default mlx backend.

---

## For developers continuing in Claude Code (Phase 2)

The repository follows a living-documentation convention. Before writing any
code, read:

- [`01_plan.md`](../01_plan.md) — checklist of what's done and what's next.
  **Phase 2** is the on-device Mac work.
- [`02_progress.md`](../02_progress.md) — current state and what's blocked.
- [`03_decisions.md`](../03_decisions.md) — key architectural decisions and why.
- [`04_learnings.md`](../04_learnings.md) — non-obvious gotchas (read this
  before touching anything).

**Phase 1 was completed on Linux.** Everything in `src/`, `scripts/lib/`, and
`tests/` is verified. Phase 2 is Mac-only work:

1. **Verify the mlx backend** — run `./scripts/test_mac_setup.sh`. The
   model warmup downloads the selected model with visible progress; the
   end-to-end check starts `src/mlx_whisper_server.py` and
   transcribes a real WAV. If it's green, the backend works.
2. **Polish `src/whisper_hotkey_mac_experimental.py`** — the hotkey + recording
   + paste logic. Test the golden path manually: hold Ctrl+Option+Space in a
   text editor, speak, release Ctrl, confirm text is pasted.
3. **Tune the model / RAM** — on 8 GB, try `WHISPER_MLX_MODEL=...q4` variants and
   measure latency + peak RSS. Record the chosen default in `03_decisions.md`.

**Running tests:**
```bash
uv run pytest            # 11 tests — backend_select unit + mlx-server contract
                         # (mlx-server test mocks the mlx boundary, so it runs anywhere)
bash tests/test_run_dispatch.sh   # 6 shell dispatch tests
bash tests/test_install_uninstall.sh  # fake-mac install/uninstall assertions
```

**TDD convention:** write the failing test first, then the minimum code to pass
it (see `CLAUDE.md`). mlx-whisper only runs on Apple Silicon, so the contract
test for `mlx_whisper_server.py` mocks `transcribe_audio` (the hardware boundary)
and exercises the real Flask route. The *actual* mlx transcription is only
verified on-device via `scripts/test_mac_setup.sh`.
