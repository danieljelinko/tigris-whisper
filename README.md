# tigris-whisper Daemon

A lightweight Python daemon that records audio from your microphone on a global hot-key (`Ctrl + Alt + Space`), sends it to a Docker-hosted Whisper transcription server, and places the resulting text in your clipboard (optionally pasting it into the active window).

Inspired by [MartinOpenSky's Whisper Assistant VSCode extension](https://github.com/martin-opensky/whisper-assistant-vscode) (Dockerfile)

---

## Quick install

Paste this into Terminal (macOS or Linux) — it handles everything from scratch:

```bash
curl -fsSL https://raw.githubusercontent.com/danieljelinko/tigris-whisper/main/bootstrap.sh | bash
```

Installs Pixi, downloads the repo to `~/Developer/tigris-whisper` on
macOS, runs the full installer, then runs the Mac smoke test to warm the model
cache. The default macOS path uses mlx-whisper wheels, so it does not require
Xcode CLT, Homebrew, or git. Re-running is safe.

macOS only: bootstrap asks which local Whisper model to use, then the first
smoke test/transcription downloads that model, which can take several minutes.
The setup test pre-downloads the model in the foreground so Hugging Face
progress bars are visible. After install, launch
`~/Applications/tigris-whisper.app` and grant **Microphone** and
**Accessibility** permissions to **tigris-whisper** in System Settings →
Privacy & Security.

To reveal the generated app in Finder:

```bash
open -R ~/Applications/tigris-whisper.app
```

Installer output is also written to:

```bash
~/Library/Logs/tigris-whisper/bootstrap-latest.log
~/Library/Logs/tigris-whisper/install-latest.log
```

Uninstall from the install directory:

```bash
./uninstall.sh
```

This removes the generated app, logs/state, and known downloaded mlx-whisper
model cache; it asks before removing the install directory. Use
`./uninstall.sh --yes` for unattended removal.

For a more detailed walkthrough see [`docs/mac_setup.md`](docs/mac_setup.md).

---

## Benchmark results

Real-world transcription performance across backends and languages — measured by the
[benchmark harness](benchmark/) against human recordings of the same reference text
([EN](benchmark/data/refs/en.txt) · [FR](benchmark/data/refs/fr.txt) · [HU](benchmark/data/refs/hu.txt)).
RTF < 1.0 means faster than real-time. Lower WER is better; higher F1 is better.

<!-- BENCH:START -->
_No benchmark results yet. Run `uv run python benchmark/run_suite.py` to generate them._
<!-- BENCH:END -->

---

## Backends by platform

`run.sh` auto-detects your host and starts the right transcription backend. All backends expose
the same `POST /v1/audio/transcriptions` endpoint on `:4444`, so the Python daemon is unchanged.

| Platform | Default backend | Model | Acceleration |
|---|---|---|---|
| macOS (Apple Silicon) | [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) (installs as wheels) | `mlx-community/whisper-large-v3-turbo-q4` | MLX (Apple GPU) |
| Linux + NVIDIA GPU | Docker `whisper-assistant` | faster-whisper `turbo` | CUDA |
| Linux, no GPU | [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (CTranslate2, Python wheels) | `small` (selectable at install) | CPU int8 |

**macOS** — no Homebrew or compiler needed; the model downloads on first use:
```bash
./install.sh   # installs Pixi + Python wheels incl. mlx-whisper
open ~/Applications/tigris-whisper.app
```
The app is installed in your user Applications folder (`~/Applications`), not
necessarily the system-wide `/Applications` folder shown by Finder's sidebar.
Use `open -R ~/Applications/tigris-whisper.app` to reveal it visually.
The generated app wrapper is the normal user path. It runs the same daemon as
`./run.sh`, but gives macOS a named app for Microphone and Accessibility
permissions. `./run.sh` is the manual/developer path from inside the repo; if
you use it, grant permissions to your terminal app instead.

No app window opens; tigris-whisper runs in the background and writes logs to
`~/Library/Logs/tigris-whisper/daemon.log`.

Control the background app from the install directory:

```bash
./scripts/control_mac_app.sh status
./scripts/control_mac_app.sh stop
./scripts/control_mac_app.sh restart
./scripts/control_mac_app.sh logs
```

Optional whisper.cpp Metal fallback: `./scripts/101_install_whispercpp.sh` then
`WHISPER_BACKEND=whispercpp_metal ./run.sh`.

macOS model choice is saved in `tigris-whisper.env`. The offered models are
multilingual Whisper models, not `.en` English-only models. OpenAI's model card
describes Whisper as multilingual ASR/translation, and the official language
token list is here:
<https://github.com/openai/whisper/blob/main/whisper/tokenizer.py>.

| Profile | Model | Language scope | Use when |
|---|---|---|---|
| Balanced (default) | `mlx-community/whisper-large-v3-turbo-q4` | Multilingual | Best first choice on M-series Macs; good accuracy with lower RAM/download than full turbo |
| Fast | `mlx-community/whisper-small-mlx-q4` | Multilingual | You want lower latency for short dictation and can accept more mistakes |
| Very fast | `mlx-community/whisper-base-mlx-q4` | Multilingual | You prioritize speed over accuracy |
| Best accuracy | `mlx-community/whisper-large-v3-turbo` | Multilingual | 16 GB+ Macs, noisy audio, multilingual use, or technical vocabulary |

Override for one run:

```bash
WHISPER_MLX_MODEL=mlx-community/whisper-small-mlx-q4 ./run.sh
```

When `./run.sh` needs to download a model, it runs the same foreground
pre-download helper first so Terminal users can see Hugging Face progress bars.

Change the installed model later without editing files:

```bash
./scripts/change_model.sh                       # interactive picker (lists models for your host)
./scripts/change_model.sh fast --restart        # Whisper profile shorthand
./scripts/change_model.sh nemotron-3.5-0.6b --restart
```

`change_model.sh` is **catalog-driven**: picking a model also selects the right
backend for your machine (it writes `WHISPER_BACKEND` + the model into
`tigris-whisper.env`), so switching between model families is seamless — the
daemon and hotkey are unchanged. It shows only the models runnable on your host,
so it is the single switcher for every backend.

### Available models & licenses

Beyond Whisper, newer open-weight ASR models can be selected (by the `key` below).
**Licenses differ — read them before relying on a model, especially commercially.**

| Key | Model | Mac (MLX) | Linux+GPU | Linux CPU | Languages | License |
|---|---|---|---|---|---|---|
| `balanced`/`fast`/`very-fast`/`best-accuracy` | OpenAI Whisper | ✅ mlx-whisper | ✅ Docker CUDA | ✅ faster-whisper | 99+ | **MIT** |
| `nemotron-3.5-0.6b` | NVIDIA Nemotron 3.5 ASR 0.6B | ✅ mlx-audio | ⏳ NeMo | — | 40 locales (incl. fr, hu) | **NVIDIA OpenMDW-1.1** |
| `omnilingual-llm-300m…7b` | Meta Omnilingual ASR (300M/1B/3B/7B) | ✅ mlx-audio | ⏳ transformers | ⏳ 300M CTC | 1600+ (incl. **hu**, fr) | **Apache-2.0** |
| `cohere-transcribe-2b` | Cohere Transcribe 2B | ✅ mlx-audio | ⏳ transformers | ⏳ CrispASR GGUF | 14 (no hu) | **CC-BY-NC-4.0** (non-commercial) |

✅ = available now · ⏳ = planned (Linux GPU/CPU phases). The picker only offers
combinations implemented on your host. License notes:

- **Whisper** — MIT, fully permissive (commercial OK).
- **Meta Omnilingual ASR** — Apache-2.0; broadest language coverage, the best
  pick for Hungarian.
- **NVIDIA Nemotron 3.5 ASR** — NVIDIA Open Model License (OpenMDW-1.1); review
  its terms for your use case.
- **Cohere Transcribe** — **CC-BY-NC-4.0: non-commercial only.** Top accuracy and
  the only one with a Linux-CPU path, but do **not** use it in a commercial
  product. No Hungarian support.

When you choose a model, tigris-whisper does not bundle its weights — they
download from Hugging Face on first use under that model's own license.

**Linux no-GPU setup** (faster-whisper is now the default — no build step):
```bash
./install.sh   # installs faster-whisper wheels + prompts for model + pre-downloads it
./run.sh
```

Optional whisper.cpp CPU fallback (requires cmake build):
```bash
./scripts/101_install_whispercpp.sh
WHISPER_BACKEND=whispercpp_cpu ./run.sh
```

**Override / force backend:**
```bash
WHISPER_BACKEND=mlx ./run.sh              # force mlx-whisper (macOS)
WHISPER_BACKEND=faster_whisper ./run.sh   # force faster-whisper CPU
WHISPER_BACKEND=whispercpp_cpu ./run.sh   # force whisper.cpp CPU
WHISPER_BACKEND=docker_cuda ./run.sh      # force Docker CUDA
./run.sh --print-backend                  # print selected backend and exit (no daemon)
```

**Change model after install (all platforms):**
```bash
./scripts/change_model.sh                    # interactive picker
./scripts/change_model.sh fast               # profile shorthand
./scripts/change_model.sh fast --restart     # switch and restart daemon
```

Profiles work on all backends (`balanced`, `fast`, `very-fast`, `best-accuracy`).

---

## Features

* **Global hot-key listener**: Start recording when you press **Ctrl + Alt + Space**, stop when you release **Ctrl**.
* **Multi-language support**: Pass `WHISPER_LANG` to force a language (e.g. `fr`, `hu`); omit it for Whisper's automatic detection.
* **Clipboard integration**: Automatically copies transcript to clipboard and pastes it if possible.
* **Structured logging**: Logs events, errors, and timings to `~/.local/share/whisper_hotkey.log`.

## Prerequisites

* **Operating System**:
  * Ubuntu, Linux Mint (Cinnamon or Xfce), or any X11-based Linux desktop. Wayland is partially supported (clipboard and notifications, but no cursor change).
  * Windows 10 or 11 (experimental)
  * macOS (experimental)

### System & Python Dependencies

```bash
sudo apt install sox xclip xdotool libnotify-bin python3-pip  # linux system deps
pip install pynput pyperclip requests sounddevice soundfile numpy pyautogui win10toast # python deps  

(On Linux/macOS you can omit win10toast; on Windows it gives toast notifications.)
```

*For Wayland users*: replace `xdotool`/`xclip` with `wtype` and `wl-clipboard`.

## Installation

0. **Prepare the Whisper Docker container (CPU or GPU)**

   The daemon talks to the Docker backend shipped in [danieljelinko/whisper-assistant-vscode](https://github.com/danieljelinko/whisper-assistant-vscode). Clone that repo and run the helper scripts it provides:

   ```bash
   git clone https://github.com/danieljelinko/whisper-assistant-vscode
   cd whisper-assistant-vscode
   ./00_install_docker_buildx.sh                     # one-time buildx prerequisites
   # Optional: only if you actually have an NVIDIA GPU on this host
   ./00_install_nvidia_container_toolkit.sh
   ./01_build_whisper_docker_container_linux.sh -t whisper-assistant-local
   ```

   *The `-t` flag picks the Docker image tag; feel free to use separate tags if you maintain CPU and GPU variants.*

   After the image is built you can either launch it manually or let the hotkey daemon script do it for you:

   ```bash
   # Manual start (choose the variant that matches your host)
   docker run -d -p 4444:4444 whisper-assistant-local                # CPU
   docker run -d -p 4444:4444 --gpus all whisper-assistant-local     # GPU
   ```

   On macOS you can keep using the published image:

   ```bash
   docker run -d -p 4444:4444 --name whisper-assistant martinopensky/whisper-assistant:latest
   ```

1. **Clone or download** this repository to `~/.local/bin`:

   ```bash
   mkdir -p ~/.local/bin && git clone https://github.com/danieljelinko/tigris-whisper.git ~/.local/bin/tigris-whisper
   cd ~/.local/bin/tigris-whisper
   chmod +x whisper_hotkey_linux.py
   ```

2. **Configure environment** (if needed):

   * If docker port changed set `WHISPER_API` to your transcription endpoint. Default is `http://localhost:4444/v1/audio/transcriptions`.

3. **Run**

   ```bash
   ./run.sh                        # auto-detects platform and backend
   WHISPER_LANG=fr ./run.sh        # French
   WHISPER_LANG=hu ./run.sh        # Hungarian
   WHISPER_LANG=de ./run.sh        # any Whisper-supported language code
   USE_GPU=0 ./run.sh              # force CPU Docker container (Linux only)
   ```

   Legacy per-language scripts still work as thin wrappers:
   ```bash
   ./02_run_whisper_hotkey_daemon_fr.sh   # sets WHISPER_LANG=fr then calls run.sh
   ./03_run_whisper_hotkey_daemon_hu.sh   # sets WHISPER_LANG=hu then calls run.sh
   ```

   When a backend is already running you can skip the launch scripts:
   ```bash
   uv run whisper_hotkey_linux.py
   WHISPER_LANG=fr uv run whisper_hotkey_linux.py
   ```

   Sample log output:

   ```bash
   2025-06-21 00:58:02,490 INFO: Daemon up (Wayland=False, lang=auto). Hold Ctrl + Alt + Space to record; release Ctrl to stop.
   2025-06-21 00:58:05,108 INFO: Recording started (PID 74070)

   Input File     : 'default' (alsa)
   Channels       : 2
   Sample Rate    : 48000
   Precision      : 16-bit
   Sample Encoding: 16-bit Signed Integer PCM

   In:0.00% 00:00:02.90 [00:00:00.00] Out:43.6k [      |      ]        Clip:0
   Aborted.
   2025-06-21 00:58:08,051 INFO: Recording stopped, 87146 B
   2025-06-21 00:58:09,227 INFO: API call 1.05s
   2025-06-21 00:58:09,239 INFO: Transcript copied: Hello world!
   2025-06-21 00:58:09,241 INFO: Pasted with xdotool
   ```

## Usage

* **Start recording**: Press `Ctrl + Alt + Space` and hold **`Ctrl`** until you finish speaking.
* **Stop recording**: Release **Ctrl**. Recording stops.
* **Paste**: If a text field is focused, the daemon attempts to paste automatically, but you can also paste manually from the clipboard.
* **Logs**: View real-time logs:

  ```bash
  tail -f ~/.local/share/whisper_hotkey.log
  ```

## Troubleshooting

* **No notifications**:

  * Ensure `libnotify-bin` is installed and your desktop daemon is running.

* **Cursor not changing**: Only supported on X11 (`xsetroot`). Wayland sessions will skip this step.

* **Hot-key not responding**: Verify no other application is capturing `Ctrl + Alt + Space`. Run the script in a terminal to see any logged errors.

## Credits

* **Dockerfile & API**: [MartinOpenSky](https://github.com/martin-opensky) (whisper-assistant-vscode)
* **Scripts**: Dani Helinko, o4-mini & Claude Sonnet
