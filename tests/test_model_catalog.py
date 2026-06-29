"""Tests for the model catalog — the seam that lets a model choice drive backend
selection. A user-facing model key resolves to (backend, runtime model id, env
var) for the current host; the picker writes WHISPER_BACKEND + that env var and
run.sh brings the right backend up unchanged.
"""
import pytest

import model_catalog as mc
from model_catalog import resolve, platform_of, list_for, ModelNotViableError
from backend_select import UnsupportedPlatformError, BACKENDS


def test_platform_of_is_darwin_for_macos():
    # Given a macOS host
    # When we resolve the platform key
    # Then it is darwin (GPU flag irrelevant on Mac)
    assert platform_of("Darwin", has_nvidia_gpu=False) == "darwin"


def test_platform_of_distinguishes_linux_by_gpu():
    # Given Linux hosts with and without a usable NVIDIA GPU
    # When we resolve the platform key
    # Then GPU presence splits linux_cuda from linux_cpu
    assert platform_of("Linux", has_nvidia_gpu=True) == "linux_cuda"
    assert platform_of("Linux", has_nvidia_gpu=False) == "linux_cpu"


def test_platform_of_raises_on_unsupported_os():
    # Given an OS with no defined platform key
    # When we resolve the platform
    # Then it raises the shared platform error rather than guessing
    with pytest.raises(UnsupportedPlatformError):
        platform_of("Windows", has_nvidia_gpu=False)


def test_resolve_nemotron_on_mac_uses_mlx_audio_backend():
    # Given the Nemotron model on a Mac
    # When we resolve it
    placement = resolve("nemotron-3.5-0.6b", "Darwin", has_nvidia_gpu=False)

    # Then it routes to the mlx_audio backend with the mlx-community repo + its env var
    assert placement.backend == "mlx_audio"
    assert placement.model == "mlx-community/nemotron-3.5-asr-streaming-0.6b"
    assert placement.env_var == "WHISPER_MLX_AUDIO_MODEL"


def test_resolve_nemotron_on_linux_cpu_raises_not_viable():
    # Given Nemotron has no CPU-only backend
    # When we resolve it on a Linux box with no GPU
    # Then it raises rather than offering an unrunnable combination
    with pytest.raises(ModelNotViableError):
        resolve("nemotron-3.5-0.6b", "Linux", has_nvidia_gpu=False)


def test_resolve_keeps_whisper_balanced_on_mlx_for_mac():
    # Given the existing balanced Whisper profile on a Mac
    # When we resolve it
    placement = resolve("balanced", "Darwin", has_nvidia_gpu=False)

    # Then nothing regresses: it still maps to mlx-whisper turbo-q4 + WHISPER_MLX_MODEL
    assert placement.backend == "mlx"
    assert placement.model == "mlx-community/whisper-large-v3-turbo-q4"
    assert placement.env_var == "WHISPER_MLX_MODEL"


def test_resolve_cohere_on_mac_uses_verified_mlx_8bit_repo():
    # Given Cohere Transcribe on a Mac (the placeholder id 'cohere-transcribe-03-2026'
    # did not resolve on the Hub; the published MLX build is the -mlx-8bit repo)
    placement = resolve("cohere-transcribe-2b", "Darwin", has_nvidia_gpu=False)

    # Then it routes to mlx_audio with the Hub-verified MLX repo id
    assert placement.backend == "mlx_audio"
    assert placement.model == "mlx-community/cohere-transcribe-03-2026-mlx-8bit"
    assert placement.env_var == "WHISPER_MLX_AUDIO_MODEL"


def test_resolve_omnilingual_on_linux_gpu_uses_dedicated_backend_not_transformers():
    # Given Omnilingual is fairseq2-based (transformers.pipeline can't load it)
    # When resolved on a Linux+GPU host
    placement = resolve("omnilingual-llm-300m", "Linux", has_nvidia_gpu=True)

    # Then it routes to the dedicated `omnilingual` backend with a library model_card id
    assert placement.backend == "omnilingual"
    assert placement.model == "omniASR_LLM_300M_v2"
    assert placement.env_var == "WHISPER_OMNILINGUAL_MODEL"


def test_resolve_omnilingual_on_mac_raises_not_viable_without_mlx_build():
    # Given Meta Omnilingual has no MLX-converted repo on the Hub (the mlx-community
    # omniASR-* placeholder ids 404), so it has no viable Mac backend yet
    # When we resolve it on a Mac
    # Then it raises rather than offering an unrunnable download
    with pytest.raises(ModelNotViableError):
        resolve("omnilingual-llm-300m", "Darwin", has_nvidia_gpu=False)


def test_resolve_cohere_on_linux_cpu_uses_crispasr_gguf():
    # Given Cohere on a CPU-only Linux box
    # When we resolve it
    placement = resolve("cohere-transcribe-2b", "Linux", has_nvidia_gpu=False)

    # Then it routes to the CrispASR GGUF CPU path
    assert placement.backend == "crispasr"
    assert "GGUF" in placement.model
    assert placement.env_var == "WHISPER_CRISPASR_MODEL"


def test_resolve_unknown_model_raises():
    # Given a model key that is not in the catalog
    # When we resolve it
    # Then it raises a clear lookup error
    with pytest.raises(KeyError):
        resolve("not-a-real-model", "Darwin", has_nvidia_gpu=False)


def test_every_placement_env_var_matches_its_backend():
    # Given the whole catalog
    # When we cross-check each placement's env var against the backend→env map
    # Then they agree everywhere (guards against data-entry drift)
    for key, info in mc.MODELS.items():
        for plat, placement in info.placements.items():
            if placement is None: continue
            assert placement.env_var == mc.BACKEND_ENV_VARS[placement.backend], \
                f"{key}/{plat}: env var {placement.env_var} != backend {placement.backend}"


def test_list_for_only_offers_models_whose_backend_is_implemented():
    # Given a Mac where only the Whisper mlx + new mlx_audio backends are implemented
    # When we list selectable models
    keys = list_for("Darwin", has_nvidia_gpu=False, known_backends={"mlx", "mlx_audio"})

    # Then the new mlx_audio models AND the existing Whisper profiles are offered
    assert "nemotron-3.5-0.6b" in keys
    assert "balanced" in keys


def test_list_for_excludes_models_needing_an_unimplemented_backend():
    # Given a CPU Linux box where only faster_whisper is implemented
    # When we list selectable models
    keys = list_for("Linux", has_nvidia_gpu=False, known_backends={"faster_whisper"})

    # Then Cohere (needs crispasr, not yet implemented) is not offered, but Whisper is
    assert "balanced" in keys
    assert "cohere-transcribe-2b" not in keys


def test_catalog_backends_are_all_declared_in_backend_select():
    # Given every backend referenced by the catalog
    # When we check them against backend_select's known set
    # Then there are no typos / undeclared backends
    referenced = {p.backend for info in mc.MODELS.values()
                  for p in info.placements.values() if p is not None}
    assert referenced <= BACKENDS, f"catalog references unknown backends: {referenced - BACKENDS}"
