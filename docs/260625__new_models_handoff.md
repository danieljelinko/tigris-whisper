# Handoff — finish the new-ASR-models work on **Mac** (catalog ids, installer picker, warm-up)

> Scope: **macOS / Apple Silicon only.** Do NOT touch the Linux GPU/CPU backends
> (transformers_cuda / nemo_cuda / crispasr) — they stay scaffolded-but-hidden.
> Run this **on the Mac**, since MLX only runs on-device.

---

You are picking up a feature already partly shipped in `tigris-whisper`
(`~/Developer/tigris-whisper`). It's a hotkey dictation daemon with a pluggable
backend architecture: every backend serves the same
`POST /v1/audio/transcriptions` + `GET /` (→ `{model}`) HTTP contract on `:4444`,
and the daemon is backend-agnostic.

## What already landed (on `main`, commits `1d9b7eb` + `2e7bfa9`)

- **Model catalog** `src/model_catalog.py` — maps a `model_key` →
  `(backend, model_id, env_var)` per platform. Stdlib-only. CLI seam:
  `resolve` / `list` / `labels`.
- **`mlx_audio` backend** (Mac) — `src/mlx_audio_server.py` (Flask, lazy
  `mlx_audio.stt` import), `scripts/lib/backend_mlx_audio.sh`, `run.sh` case.
  Serves Nemotron 3.5 / Meta Omnilingual / Cohere Transcribe from one library.
- **`scripts/change_model.sh`** is catalog-driven: picking a model writes
  `WHISPER_BACKEND` + the model env var, so switching families is seamless.
- The Mac Whisper path (`mlx` backend, `mlx-whisper`) is unchanged and validated.

**Read first:** `01_plan.md`, `02_progress.md`, `03_decisions.md`, `04_learnings.md`,
and the plan at `~/.claude/plans/could-you-add-these-hidden-harp.md`.

## Non-negotiable constraints

- **Red/green TDD** (`uv run python -m pytest`). Real data over mocks; mock only at
  external boundaries. Mirror `tests/test_mlx_audio_server.py`, `tests/test_model_catalog.py`.
- **`model_catalog.py` stays stdlib-only** — it's invoked via real `python3` even under
  the install test's fake-pixi shim. Don't add heavy imports to it or `backend_select`.
- **Inference imports stay lazy** so server modules import/unit-test on any platform
  with the boundary mocked; real MLX inference is verified **on-device** only.
- **The catalog is the single source of truth** — no duplicate model tables anywhere.
- HTTP contract is invariant; the daemon never changes.
- Style: repo `CLAUDE.md`. Source control: topic branch → `git merge --ff-only` into
  `main` → push; commit trailer
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`; never commit
  `.claude/` or unrelated docs.

## Problems to fix, in order

### 1. Verify & correct the catalog's Hugging Face repo IDs (do this FIRST)
The `mlx-community/*` ids in `src/model_catalog.py` (Nemotron, `omniASR-LLM-300M…7B`,
`cohere-transcribe-03-2026`) came from web research and are **unverified placeholders**
(`04_learnings.md`, 2026-06-25). For each:
- Confirm the repo exists and `mlx-audio` can load + transcribe with it:
  `pixi run python -c "from mlx_audio.stt import load; m=load('<id>'); print(m.generate('<some.wav>').text)"`.
- Fix any wrong id in `src/model_catalog.py` (one place); update the matching assertion
  in `tests/test_model_catalog.py` if a key's id changes.
- Confirm the real `mlx_audio` API shape (`generate(path).text`); adjust
  `src/mlx_audio_server.py:transcribe_audio` if it differs.
- Confirm `mlx-audio` genuinely serves all three families on this device. If a family
  isn't supported, mark its `darwin` placement `None` in the catalog and note why.

### 2. Wire the **Mac** first-run picker to the catalog
`bootstrap.sh` `choose_mac_model()` is **hardcoded Whisper-only**, bypasses the catalog,
and writes only `WHISPER_MLX_MODEL` (never `WHISPER_BACKEND`). So a fresh install always
lands on Whisper; the new models are only reachable post-install.
- Replace the menu with a catalog-driven one using
  `python3 src/model_catalog.py labels --system Darwin --known-backends mlx,mlx_audio`
  (same pattern as `change_model.sh`). On selection, write `WHISPER_BACKEND` + the
  resolved env var + `TIGRIS_MODEL_PROFILE` into `tigris-whisper.env`.
- Keep **Whisper balanced as the default** so nothing regresses, and keep the
  `WHISPER_MLX_MODEL=<id>` env-skip shortcut working.
- (Leave the Linux picker in `install.sh` untouched.)

### 3. Make the Mac warm-up backend-aware  ← the core ask
The first-run model warm-up / pre-download is hardwired to mlx-whisper, so if a user
picks Nemotron/Omnilingual/Cohere at install it warms the **wrong** backend. Fix the
whole warm-up path to honour the selected backend:
- **`scripts/download_mlx_model.py`** — currently pre-downloads an mlx-whisper repo.
  Make it backend-aware: for `mlx` keep the current path; for `mlx_audio` pre-download
  via `from mlx_audio.stt import load; load(<id>)` (visible HF/tqdm progress). Drive it
  off `WHISPER_BACKEND` + the resolved model env var (or resolve via the catalog).
- **`scripts/test_mac_setup.sh`** — the smoke test must start the **selected** backend
  (mlx vs mlx_audio), pre-download its model in the foreground, and run the end-to-end
  `POST /v1/audio/transcriptions` check against whichever server it started. Reuse
  `scripts/lib/backend_mlx_audio.sh` / `backend_mlx.sh` rather than duplicating bring-up.
  Keep `TIGRIS_TRANSCRIPTION_TIMEOUT` / `TIGRIS_SKIP_TRANSCRIPTION_TEST` honoured.
- **`bootstrap.sh`** runs the smoke test automatically after the picker — confirm the
  chosen new-model selection flows through to a real warm-up + transcription, with HF
  progress visible (not hidden behind a stuck request).
- `uninstall.sh` already cleans the new caches — verify the configured
  `WHISPER_MLX_AUDIO_MODEL` is removed too.

## Tests to update (all must stay green)
`tests/test_install_uninstall.sh` runs under a fake `uname` (Darwin) + fake `pixi`, so:
- The picker/warm-up changes must call the catalog via **real `python3`** and copy
  `src/model_catalog.py` + `src/backend_select.py` into any isolated test dir (the
  model-change section already does this).
- Add assertions that the Mac picker can select a new-model key and writes
  `WHISPER_BACKEND=mlx_audio` + `WHISPER_MLX_AUDIO_MODEL=<id>`.
- Add a unit test for the backend-aware `download_mlx_model.py` (mock the download
  boundary; assert it routes `mlx` vs `mlx_audio` correctly) — keep it importable on Linux.

## Green gate + finish
- `uv run python -m pytest` · `bash tests/test_install_uninstall.sh` ·
  `bash tests/test_run_dispatch.sh` — all green.
- **On-device:** fresh bootstrap on the Mac → pick a new model → warm-up downloads it
  with visible progress → `tigris-whisper.app` (or `./run.sh`) → real hotkey→transcribe→paste.
- Update `02_progress.md` (Done row) + `03_decisions.md`/`04_learnings.md` as warranted.
- Topic branch → `git merge --ff-only` into `main` → push.

## Acceptance criteria
- A **fresh Mac install** offers Whisper + Nemotron + Omnilingual + Cohere; picking any
  one writes the right backend, warms/pre-downloads **that** model with visible progress,
  and a real hotkey→transcribe→paste works on-device.
- Whisper installs are unchanged (no regression).
- Every Mac (`darwin`) catalog model id is confirmed to resolve on the Hub.
- All automated tests green. License notes in README intact (Cohere CC-BY-NC = non-commercial).
