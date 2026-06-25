#!/usr/bin/env python3
"""Pre-download the selected transcription model with visible Hugging Face progress.

Backend-aware: the warm-up path depends on which backend was selected at install,
so a Mac user who picked Nemotron/Cohere (the `mlx_audio` backend) warms *that*
model the way its server loads it, instead of an mlx-whisper snapshot.

    WHISPER_BACKEND=mlx        → snapshot_download of the mlx-whisper HF repo
    WHISPER_BACKEND=mlx_audio  → mlx_audio.stt.load(<id>) (exactly what the server does)

The model id is `argv[1]` if given, else the backend's model env var, else a
sensible default. mlx-audio is imported lazily (Apple-Silicon only) so this module
imports and unit-tests on any platform with the warm boundary mocked.
"""

from __future__ import annotations

import os
import sys

# backend → (model env var it reads, default model id)
BACKEND_MODEL_ENV: dict[str, tuple[str, str]] = {
    "mlx":       ("WHISPER_MLX_MODEL",       "mlx-community/whisper-large-v3-turbo-q4"),
    "mlx_audio": ("WHISPER_MLX_AUDIO_MODEL", "mlx-community/nemotron-3.5-asr-streaming-0.6b"),
}


def resolve_target(argv: list[str], env: dict[str, str]) -> tuple[str, str]:
    "Pick (backend, model) from WHISPER_BACKEND + the matching model env var / argv override."
    backend = env.get("WHISPER_BACKEND") or "mlx"
    if backend not in BACKEND_MODEL_ENV: backend = "mlx"   # unknown/Linux backend → file pull
    env_var, default = BACKEND_MODEL_ENV[backend]
    argv_model = argv[1] if len(argv) > 1 and argv[1] else ""
    model = argv_model or env.get(env_var) or default
    return backend, model


def _human_size(num_bytes: int | None) -> str:
    if not num_bytes:
        return "unknown size"
    size = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} GB"


def warm_mlx(model: str) -> int:
    "Download every file of an mlx-whisper HF repo with visible progress."
    try:
        from huggingface_hub import HfApi, snapshot_download
    except Exception as exc:
        print(f"Could not import huggingface_hub: {exc}", file=sys.stderr)
        return 1

    print(f"Preparing MLX Whisper model: {model}", flush=True)
    print("If the model is not cached, Hugging Face download progress appears below.", flush=True)

    total_size: int | None = None
    try:
        info = HfApi().model_info(model, files_metadata=True)
        sizes = [getattr(s, "size", None) for s in info.siblings
                 if getattr(s, "rfilename", "") != ".gitattributes"]
        known = [size for size in sizes if isinstance(size, int)]
        if known: total_size = sum(known)
    except Exception as exc:
        print(f"Could not read model metadata before download: {exc}", file=sys.stderr)

    print(f"Estimated download size: {_human_size(total_size)}", flush=True)
    local_dir = snapshot_download(repo_id=model)
    print(f"Model ready in Hugging Face cache: {local_dir}", flush=True)
    return 0


def warm_mlx_audio(model: str) -> int:
    "Warm the mlx-audio model exactly as the server loads it (Apple-Silicon only)."
    print(f"Preparing mlx-audio model: {model}", flush=True)
    print("If the model is not cached, Hugging Face download progress appears below.", flush=True)
    try:
        from mlx_audio.stt import load                      # deferred: Apple-Silicon only
    except Exception as exc:
        print(f"Could not import mlx_audio (Apple Silicon only): {exc}", file=sys.stderr)
        return 1
    load(model)
    print("mlx-audio model ready (loaded by the same call the server uses).", flush=True)
    return 0


def main(argv: list[str], env: dict[str, str] | None = None) -> int:
    env = os.environ if env is None else env
    env.setdefault("HF_HUB_DISABLE_XET", "1")
    backend, model = resolve_target(argv, env)
    if backend == "mlx_audio": return warm_mlx_audio(model)
    return warm_mlx(model)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
