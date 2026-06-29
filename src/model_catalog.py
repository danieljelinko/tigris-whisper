#!/usr/bin/env python3
"""Catalog mapping user-facing model keys → (backend, runtime model id, env var)
per platform.

This is the seam that lets a *model* choice drive *backend* selection: the picker
resolves a key for the current host, writes both `WHISPER_BACKEND` and the
backend's model env var into `tigris-whisper.env`, and `run.sh` brings the right
backend up unchanged. The daemon and its HTTP contract never change.

Platforms (derived from `uname -s` + GPU availability, same inputs as
`backend_select`):
    `darwin`      Apple Silicon (mlx wheels; no NVIDIA GPU)
    `linux_cuda`  Linux with a working NVIDIA GPU
    `linux_cpu`   Linux without a usable GPU

A model not viable on a platform maps to `None` there. `list_for` additionally
hides any model whose backend is not yet implemented on this install, so the
picker only ever offers combinations that actually run.
"""
import sys
from typing import Any, Literal, NamedTuple

from backend_select import UnsupportedPlatformError, BACKENDS

Platform = Literal["darwin", "linux_cuda", "linux_cpu"]

BACKEND_ENV_VARS: dict[str, str] = {       # which env var each backend reads its model from
    "mlx":              "WHISPER_MLX_MODEL",
    "mlx_audio":        "WHISPER_MLX_AUDIO_MODEL",
    "faster_whisper":   "FASTER_WHISPER_MODEL",
    "docker_cuda":      "",                # model baked into the image; nothing to write
    "transformers_cuda": "WHISPER_TRANSFORMERS_MODEL",
    "transformers_cpu": "WHISPER_TRANSFORMERS_MODEL",
    "nemo_cuda":        "WHISPER_NEMO_MODEL",
    "crispasr":         "WHISPER_CRISPASR_MODEL",
    "omnilingual":      "WHISPER_OMNILINGUAL_MODEL",
}


class Placement(NamedTuple):
    backend: str            # backend id (see backend_select.BACKENDS)
    model: str              # runtime model id for that backend (HF repo, size, GGUF repo…)
    env_var: str            # env var the backend server reads for its model


class ModelInfo(NamedTuple):
    label: str                                  # human label for the picker
    license: str                                # SPDX-ish license id, surfaced in README/picker
    languages: str                              # short coverage note (for the picker)
    placements: dict[str, Placement | None]     # platform key → placement (None = not viable)


class ModelNotViableError(RuntimeError):
    "Raised when a catalogued model has no backend on the current platform."


def _p(backend: str, model: str) -> Placement:
    "Build a Placement, deriving the env var from the backend (single source of truth)."
    return Placement(backend, model, BACKEND_ENV_VARS[backend])


# ─── The catalog ──────────────────────────────────────────────────────────────
# Whisper keeps its four profile keys so the existing UX does not regress; each
# resolves to the platform-appropriate Whisper backend. New families are keyed by
# model/size. `None` marks a platform where that model has no viable backend.

MODELS: dict[str, ModelInfo] = {
    # ── Whisper (existing; unchanged behaviour) ──────────────────────────────
    "balanced": ModelInfo(
        "Whisper large-v3-turbo (balanced)", "MIT", "multilingual (99+)",
        {"darwin":     _p("mlx", "mlx-community/whisper-large-v3-turbo-q4"),
         "linux_cuda": _p("docker_cuda", "turbo"),
         "linux_cpu":  _p("faster_whisper", "small")}),
    "fast": ModelInfo(
        "Whisper small (fast)", "MIT", "multilingual (99+)",
        {"darwin":     _p("mlx", "mlx-community/whisper-small-mlx-q4"),
         "linux_cuda": _p("docker_cuda", "turbo"),
         "linux_cpu":  _p("faster_whisper", "base")}),
    "very-fast": ModelInfo(
        "Whisper base (very fast)", "MIT", "multilingual (99+)",
        {"darwin":     _p("mlx", "mlx-community/whisper-base-mlx-q4"),
         "linux_cuda": _p("docker_cuda", "turbo"),
         "linux_cpu":  _p("faster_whisper", "tiny")}),
    "best-accuracy": ModelInfo(
        "Whisper large-v3-turbo (best accuracy)", "MIT", "multilingual (99+)",
        {"darwin":     _p("mlx", "mlx-community/whisper-large-v3-turbo"),
         "linux_cuda": _p("docker_cuda", "turbo"),
         "linux_cpu":  _p("faster_whisper", "large-v3-turbo")}),

    # ── NVIDIA Nemotron 3.5 ASR (Jun 2026) ───────────────────────────────────
    "nemotron-3.5-0.6b": ModelInfo(
        "NVIDIA Nemotron 3.5 ASR 0.6B", "NVIDIA-OpenMDW-1.1", "40 locales (incl. fr, hu)",
        {"darwin":     _p("mlx_audio", "mlx-community/nemotron-3.5-asr-streaming-0.6b"),
         "linux_cuda": _p("nemo_cuda", "nvidia/nemotron-3.5-asr-streaming-0.6b"),
         "linux_cpu":  None}),

    # ── Meta Omnilingual ASR (Nov 2025, Apache-2.0) ──────────────────────────
    # Served by the dedicated `omnilingual` backend (Meta's fairseq2-based
    # omnilingual-asr package) — NOT transformers: omniASR has no `model_type` in
    # config.json, so `transformers.pipeline` can't load it. Model ids are the
    # library's model_card strings (omniASR_{LLM,CTC}_<size>[_v2]), not HF repos.
    # `darwin` is None: no MLX build exists. VRAM (approx): 300M ~5 GB, 1B ~6 GB,
    # 3B ~10 GB, 7B ~17 GB — only 300M/1B fit an 8 GB GPU.
    "omnilingual-llm-300m": ModelInfo(
        "Meta Omnilingual ASR LLM 300M (~5 GB VRAM)", "Apache-2.0", "1600+ langs (incl. hu, fr)",
        {"darwin":     None,
         "linux_cuda": _p("omnilingual", "omniASR_LLM_300M_v2"),
         "linux_cpu":  _p("omnilingual", "omniASR_CTC_300M")}),   # CTC is lighter for CPU
    "omnilingual-llm-1b": ModelInfo(
        "Meta Omnilingual ASR LLM 1B (~6 GB VRAM)", "Apache-2.0", "1600+ langs (incl. hu, fr)",
        {"darwin":     None,
         "linux_cuda": _p("omnilingual", "omniASR_LLM_1B_v2"),
         "linux_cpu":  None}),
    "omnilingual-llm-3b": ModelInfo(
        "Meta Omnilingual ASR LLM 3B (~10 GB VRAM)", "Apache-2.0", "1600+ langs (incl. hu, fr)",
        {"darwin":     None,
         "linux_cuda": _p("omnilingual", "omniASR_LLM_3B_v2"),
         "linux_cpu":  None}),
    "omnilingual-llm-7b": ModelInfo(
        "Meta Omnilingual ASR LLM 7B (~17 GB VRAM)", "Apache-2.0", "1600+ langs (incl. hu, fr)",
        {"darwin":     None,
         "linux_cuda": _p("omnilingual", "omniASR_LLM_7B_v2"),
         "linux_cpu":  None}),

    # ── Cohere Transcribe (Mar 2026) ─────────────────────────────────────────
    # darwin id verified on the Hub 2026-06-25: the published MLX build is the
    # `-mlx-8bit` repo; the bare `cohere-transcribe-03-2026` id does not resolve.
    "cohere-transcribe-2b": ModelInfo(
        "Cohere Transcribe 2B", "CC-BY-NC-4.0", "14 langs (no hu)",
        {"darwin":     _p("mlx_audio", "mlx-community/cohere-transcribe-03-2026-mlx-8bit"),
         "linux_cuda": _p("transformers_cuda", "CohereLabs/cohere-transcribe-03-2026"),
         "linux_cpu":  _p("crispasr", "cstr/cohere-transcribe-03-2026-GGUF")}),
}


def platform_of(system: str, has_nvidia_gpu: bool) -> Platform:
    "Map `uname -s` + GPU availability to a catalog platform key."
    if system == "Darwin": return "darwin"
    if system == "Linux":  return "linux_cuda" if has_nvidia_gpu else "linux_cpu"
    raise UnsupportedPlatformError(f"no catalog platform for {system!r}")


def resolve(model_key: str, system: str, has_nvidia_gpu: bool) -> Placement:
    "Resolve a model key to its (backend, model id, env var) on the current host."
    info = MODELS[model_key]                                # KeyError on unknown key — intentional
    plat = platform_of(system, has_nvidia_gpu)
    placement = info.placements.get(plat)
    if placement is None:
        raise ModelNotViableError(f"model {model_key!r} has no backend on {plat}")
    return placement


def list_for(system: str, has_nvidia_gpu: bool, *,
             known_backends: set[str] | None = None) -> list[str]:
    "Model keys runnable on this host: viable on the platform and backend implemented."
    known = BACKENDS if known_backends is None else known_backends
    plat = platform_of(system, has_nvidia_gpu)
    return [key for key, info in MODELS.items()
            if (p := info.placements.get(plat)) is not None and p.backend in known]


if __name__ == "__main__":                                 # CLI seam for bash (mirrors backend_select.py)
    import argparse, platform
    ap = argparse.ArgumentParser(description="Resolve/list tigris-whisper models per platform")
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("resolve", help="print 'backend<TAB>env_var<TAB>model' for a model key")
    r.add_argument("model_key")
    r.add_argument("--system", default="")
    r.add_argument("--has-nvidia-gpu", action="store_true")

    for name in ("list", "labels"):                        # list = keys; labels = key<TAB>label<TAB>license<TAB>languages
        s = sub.add_parser(name, help=f"print runnable models ({'keys' if name == 'list' else 'with metadata'})")
        s.add_argument("--system", default="")
        s.add_argument("--has-nvidia-gpu", action="store_true")
        s.add_argument("--known-backends", default="")      # comma-separated; default = all declared

    a = ap.parse_args()
    system = a.system or platform.system()
    if a.cmd == "resolve":
        p = resolve(a.model_key, system, a.has_nvidia_gpu)
        print(f"{p.backend}\t{p.env_var}\t{p.model}")
    else:
        known = set(filter(None, a.known_backends.split(","))) or None
        for key in list_for(system, a.has_nvidia_gpu, known_backends=known):
            if a.cmd == "list": print(key)
            else:
                i = MODELS[key]
                print(f"{key}\t{i.label}\t{i.license}\t{i.languages}")
    sys.exit(0)
