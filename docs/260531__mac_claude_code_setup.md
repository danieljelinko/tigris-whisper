# Set up Claude Code on the Mac (so an agent can debug on-device)

**Goal:** install Claude Code directly on the M1 Air, point it at the
`tigris-whisper` repo, and let it run installs / tests / app launches and read
logs in the local session — no more flaky SSH from the Linux box.

Do these steps **on the Mac itself** (Terminal on the Mac screen). Each block is
copy-paste ready.

---

## 1. Install Claude Code (no Xcode / Homebrew needed)

The native installer is a self-contained binary — it does **not** require Node,
Homebrew, or Xcode Command Line Tools (good, since this Mac has none of them).

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Then make sure it's on your PATH for this shell:

```bash
export PATH="$HOME/.local/bin:$PATH"
claude --version
```

If `claude` is not found, open a **new** Terminal window (the installer adds the
PATH line to your shell profile) and run `claude --version` again.

> Alternative if the above ever fails: `npm install -g @anthropic-ai/claude-code`
> — but that needs Node 18+, which isn't installed here, so prefer the curl
> installer.

---

## 2. Sign in

```bash
claude
```

On first run it opens a browser to authenticate with your Anthropic account.
Complete the login, then come back to the Terminal. (Use the **same** account /
plan you use on the Linux box.)

You can type `/exit` to quit once you've confirmed it launches.

---

## 3. Open the project

```bash
cd ~/Developer/tigris-whisper
claude
```

That starts Claude Code with the repo as its working directory. It will read the
living docs (`01_plan.md` … `04_learnings.md`) and `CLAUDE.md` automatically.

---

## 4. First message to give the agent

Paste this as the first prompt so it picks up exactly where we are:

```
Read 01_plan.md through 04_learnings.md. We are on Phase 4.4: the install is
clean (verified) but the app has not been launched successfully with permissions
yet. A stale daemon from May 30 may still be holding port 4444. Check running
processes, free port 4444 if needed, then walk me through launching
~/Applications/tigris-whisper.app, granting Microphone + Accessibility, and
testing the Ctrl+Option+Space hotkey -> paste. Read
~/Library/Logs/tigris-whisper/daemon.log after each launch.
```

---

## 5. What the agent CAN and CANNOT do on the Mac

**Can do (in the local session):**
- Run `./install.sh`, `./run.sh`, `./scripts/test_mac_setup.sh`, the control script.
- Launch the app: `open ~/Applications/tigris-whisper.app`.
- Read every log live: `~/Library/Logs/tigris-whisper/*.log`.
- Stop/restart/inspect processes, free port 4444.

**Cannot do (these are yours, on screen):**
- Click the **Microphone "Allow"** popup when it appears.
- Toggle **tigris-whisper** on in
  System Settings → Privacy & Security → **Microphone** and **Accessibility**.
- The actual hold-hotkey-and-speak gesture for the real paste test.

macOS deliberately blocks programs from granting their own TCC permissions, so
those clicks have to be done by you — but the agent can tell you exactly when and
verify the result from the logs immediately after.

---

## 6. Handy commands the agent (or you) will use

```bash
# Status / lifecycle
cd ~/Developer/tigris-whisper
./scripts/control_mac_app.sh status      # is it running?
./scripts/control_mac_app.sh stop        # stop background app
./scripts/control_mac_app.sh restart
./scripts/control_mac_app.sh logs        # tail daemon.log

# Launch the app (normal user path)
open ~/Applications/tigris-whisper.app
open -R ~/Applications/tigris-whisper.app   # reveal in Finder

# Logs
tail -100 ~/Library/Logs/tigris-whisper/daemon.log
tail -100 ~/Library/Logs/tigris-whisper/install-latest.log

# Check the transcription server port
lsof -nP -iTCP:4444
```

---

## 7. Current state (as of 2026-05-31, from the Linux box over SSH)

- Install is **clean**: latest bootstrap → install → smoke test = **11 passed,
  0 failed**; real sample transcription succeeded
  (`"Testing whisper transcription. 12345"`).
- Selected model: `mlx-community/whisper-base-mlx-q4` (cached, fast).
- **Open blocker:** the freshly-installed app had not been launched yet; a stale
  daemon from May 30 was still holding port 4444 and lacked Accessibility. First
  job on-device: kill any stale daemon, launch the new app, grant the two
  permissions, test the hotkey.
