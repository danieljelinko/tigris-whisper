#!/usr/bin/env python3
"""Download the selected faster-whisper model with visible Hugging Face progress."""

from __future__ import annotations
import os, sys

MODEL_REPOS: dict[str, str] = {
    "tiny":           "Systran/faster-whisper-tiny",
    "base":           "Systran/faster-whisper-base",
    "small":          "Systran/faster-whisper-small",
    "medium":         "Systran/faster-whisper-medium",
    "large-v3-turbo": "Systran/faster-whisper-large-v3-turbo",
}

SIZES: dict[str, str] = {
    "tiny":           "~75 MB",
    "base":           "~145 MB",
    "small":          "~490 MB",
    "medium":         "~1.5 GB",
    "large-v3-turbo": "~1.6 GB",
}


def main() -> int:
    model = sys.argv[1] if len(sys.argv) > 1 else os.getenv("FASTER_WHISPER_MODEL", "small")
    repo = MODEL_REPOS.get(model, model)
    size_hint = SIZES.get(model, "unknown size")

    try:
        from huggingface_hub import snapshot_download
    except ImportError as exc:
        print(f"Could not import huggingface_hub: {exc}", file=sys.stderr)
        return 1

    print(f"Downloading faster-whisper model: {repo}  ({size_hint})", flush=True)
    print("Hugging Face download progress appears below:", flush=True)

    local_dir = snapshot_download(repo_id=repo)
    print(f"\nModel ready: {local_dir}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
