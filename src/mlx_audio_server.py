#!/usr/bin/env python3
"""Minimal HTTP wrapper exposing mlx-audio STT as an OpenAI-shape transcription
endpoint, so the existing daemon can use it unchanged on Apple Silicon.

    POST /v1/audio/transcriptions   (multipart: file=<wav>)  → {"text": ...}

mlx-audio serves several model families from one library — Nemotron 3.5 ASR,
Meta Omnilingual ASR, Cohere Transcribe, Parakeet, Whisper — selected purely by
the model id. It only runs on Apple Silicon, so the actual `mlx_audio` import is
deferred into `transcribe_audio` (and the loaded model cached) so this module
imports (and its HTTP contract is testable) on any platform with the boundary
mocked.

Run on a Mac:  uv run src/mlx_audio_server.py
Env:
    WHISPER_MLX_AUDIO_MODEL   HuggingFace repo for the mlx-audio model (required in practice)
    WHISPER_MLX_AUDIO_HOST    bind host (default 127.0.0.1)
    WHISPER_MLX_AUDIO_PORT    bind port (default 4444)
"""
import os, tempfile, pathlib
from typing import Any
from flask import Flask, request, jsonify

os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
MODEL = os.getenv("WHISPER_MLX_AUDIO_MODEL", "mlx-community/nemotron-3.5-asr-streaming-0.6b")

_model = None


def _resolve_model_path(model: str) -> str:
    "Some HF repos (e.g. Cohere Transcribe MLX builds) nest weights under a quant subfolder instead of the repo root; mlx-audio's loader only looks at the root."
    if os.path.exists(model):
        return model
    from huggingface_hub import snapshot_download          # noqa: PLC0415 — deferred: Apple-Silicon only
    local_dir = snapshot_download(model)
    if os.path.exists(os.path.join(local_dir, "config.json")):
        return local_dir
    subdirs = [d for d in os.listdir(local_dir) if os.path.exists(os.path.join(local_dir, d, "config.json"))]
    return os.path.join(local_dir, subdirs[0]) if len(subdirs) == 1 else local_dir


def get_model():
    "Load and cache the mlx-audio STT model. Imports mlx-audio lazily (Mac-only)."
    global _model
    if _model is None:
        from mlx_audio.stt.utils import load_model           # noqa: PLC0415 — deferred: Apple-Silicon only
        _model = load_model(_resolve_model_path(MODEL))
    return _model


def transcribe_audio(path: str) -> str:
    "Transcribe the WAV at `path` with the configured mlx-audio model."
    return get_model().generate(path).text.strip()


def create_app() -> Flask:
    "Build the Flask app. Factory form so tests can stub `transcribe_audio`."
    app = Flask(__name__)

    @app.get("/")
    def health() -> Any:                                     # readiness probe for run.sh wait loop
        return jsonify(status="ok", model=MODEL)

    @app.post("/v1/audio/transcriptions")
    def transcribe() -> Any:
        if "file" not in request.files:
            return jsonify(error="missing 'file' part"), 400
        upload = request.files["file"]
        suffix = pathlib.Path(upload.filename or "audio.wav").suffix or ".wav"
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
            upload.save(tmp.name)
            tmp_path = tmp.name
        try:
            text = transcribe_audio(tmp_path)
        finally:
            os.unlink(tmp_path)
        return jsonify(text=text)

    return app


if __name__ == "__main__":
    host = os.getenv("WHISPER_MLX_AUDIO_HOST", "127.0.0.1")
    port = int(os.getenv("WHISPER_MLX_AUDIO_PORT", "4444"))
    print(f"mlx-audio server on http://{host}:{port} (model: {MODEL})")
    get_model()                                              # pre-load before serving
    create_app().run(host=host, port=port, threaded=True)
