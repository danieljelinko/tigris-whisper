#!/usr/bin/env python3
"""Download the selected MLX Whisper model with visible Hugging Face progress."""

from __future__ import annotations

import os
import sys


def _human_size(num_bytes: int | None) -> str:
    if not num_bytes:
        return "unknown size"
    size = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} GB"


def main() -> int:
    model = sys.argv[1] if len(sys.argv) > 1 else os.getenv(
        "WHISPER_MLX_MODEL", "mlx-community/whisper-large-v3-turbo-q4"
    )

    os.environ.setdefault("HF_HUB_DISABLE_XET", "1")

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
        sizes = [
            getattr(sibling, "size", None)
            for sibling in info.siblings
            if getattr(sibling, "rfilename", "") != ".gitattributes"
        ]
        known_sizes = [size for size in sizes if isinstance(size, int)]
        if known_sizes:
            total_size = sum(known_sizes)
    except Exception as exc:
        print(f"Could not read model metadata before download: {exc}", file=sys.stderr)

    print(f"Estimated download size: {_human_size(total_size)}", flush=True)

    local_dir = snapshot_download(repo_id=model)
    print(f"Model ready in Hugging Face cache: {local_dir}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
