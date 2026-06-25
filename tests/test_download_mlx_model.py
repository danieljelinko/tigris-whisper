"""Tests for the backend-aware model warm-up helper. A Mac user who picked
Nemotron/Cohere (the mlx_audio backend) must warm *that* model via mlx-audio's
own loader, not the mlx-whisper snapshot path. Routing is unit-tested on Linux by
mocking the two warm-up boundaries; the real downloads are exercised on-device.
"""
import download_mlx_model as dl


def test_resolve_target_defaults_to_mlx_whisper_when_no_backend_set():
    # Given no backend or model in the environment
    backend, model = dl.resolve_target(["prog"], {})

    # Then it falls back to the mlx-whisper balanced default
    assert backend == "mlx"
    assert model == "mlx-community/whisper-large-v3-turbo-q4"


def test_resolve_target_routes_mlx_audio_to_its_own_env_model():
    # Given the mlx_audio backend with its model env var set
    env = {"WHISPER_BACKEND": "mlx_audio",
           "WHISPER_MLX_AUDIO_MODEL": "mlx-community/cohere-transcribe-03-2026-mlx-8bit"}

    # When we resolve the warm-up target
    backend, model = dl.resolve_target(["prog"], env)

    # Then it reads the mlx_audio model, not the mlx-whisper one
    assert backend == "mlx_audio"
    assert model == "mlx-community/cohere-transcribe-03-2026-mlx-8bit"


def test_resolve_target_argv_model_overrides_env():
    # Given a model passed explicitly on argv
    backend, model = dl.resolve_target(["prog", "mlx-community/whisper-small-mlx-q4"],
                                       {"WHISPER_BACKEND": "mlx"})

    # Then the argv model wins over the env default
    assert model == "mlx-community/whisper-small-mlx-q4"


def test_main_routes_mlx_backend_to_the_snapshot_warmer(monkeypatch):
    # Given the mlx backend selected
    calls = {}
    monkeypatch.setattr(dl, "warm_mlx",       lambda m: (calls.__setitem__("mlx", m), 0)[1])
    monkeypatch.setattr(dl, "warm_mlx_audio", lambda m: (calls.__setitem__("mlx_audio", m), 0)[1])

    # When we run the warm-up
    rc = dl.main(["prog"], {"WHISPER_BACKEND": "mlx", "WHISPER_MLX_MODEL": "repo/x"})

    # Then only the mlx-whisper warmer runs, with the mlx model
    assert rc == 0
    assert calls == {"mlx": "repo/x"}


def test_main_routes_mlx_audio_backend_to_the_mlx_audio_warmer(monkeypatch):
    # Given the mlx_audio backend selected
    calls = {}
    monkeypatch.setattr(dl, "warm_mlx",       lambda m: (calls.__setitem__("mlx", m), 0)[1])
    monkeypatch.setattr(dl, "warm_mlx_audio", lambda m: (calls.__setitem__("mlx_audio", m), 0)[1])

    # When we run the warm-up
    rc = dl.main(["prog"], {"WHISPER_BACKEND": "mlx_audio", "WHISPER_MLX_AUDIO_MODEL": "repo/y"})

    # Then only the mlx-audio warmer runs, with the mlx_audio model
    assert rc == 0
    assert calls == {"mlx_audio": "repo/y"}
