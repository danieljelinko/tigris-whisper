#!/usr/bin/env python3
"""HTTP wrapper exposing a Hugging Face transformers ASR model as an OpenAI-shape
transcription endpoint, for Linux + NVIDIA GPU.

    POST /v1/audio/transcriptions   (multipart: file=<wav>)  → {"text": ...}

Serves the transformers-native ASR families behind the `transformers_cuda`
backend — Cohere Transcribe (`CohereLabs/cohere-transcribe-03-2026`) and Meta
Omnilingual (`facebook/omniASR-*`). transformers + torch are heavy and GPU-bound,
so the import is deferred into `get_pipe`; this module imports (and its HTTP
contract is testable) on any platform with the boundary mocked.

Run (Linux):  uv run --with transformers --with torch --with soundfile --with librosa \
                  --with accelerate python src/transformers_asr_server.py
Env:
    WHISPER_TRANSFORMERS_MODEL   HF repo id (default: Cohere Transcribe)
    WHISPER_TRANSFORMERS_DEVICE  torch device: cuda (default) or cpu
    WHISPER_TRANSFORMERS_HOST    bind host (default 127.0.0.1)
    WHISPER_TRANSFORMERS_PORT    bind port (default 4444)
    WHISPER_LANG                 language hint passed by the daemon (best-effort)
"""
import os, tempfile, pathlib
from typing import Any
from flask import Flask, request, jsonify

os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
MODEL = os.getenv("WHISPER_TRANSFORMERS_MODEL", "CohereLabs/cohere-transcribe-03-2026")
DEVICE = os.getenv("WHISPER_TRANSFORMERS_DEVICE", "cuda")

_pipe = None


def get_pipe():
    "Build and cache an ASR pipeline. Imports transformers/torch lazily (GPU-bound)."
    global _pipe
    if _pipe is None:
        from transformers import pipeline                   # noqa: PLC0415 — deferred: heavy/GPU
        device = 0 if DEVICE.startswith("cuda") else -1     # transformers pipeline device index
        _pipe = pipeline("automatic-speech-recognition", model=MODEL, device=device)
    return _pipe


def transcribe_audio(path: str, language: str | None = None) -> str:
    "Transcribe the WAV at `path` with the configured transformers ASR model."
    kwargs: dict[str, Any] = {}
    if language: kwargs["generate_kwargs"] = {"language": language}
    out = get_pipe()(path, **kwargs)
    return (out.get("text", "") if isinstance(out, dict) else str(out)).strip()


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
            lang = request.form.get("language") or None
            text = transcribe_audio(tmp_path, language=lang)
        finally:
            os.unlink(tmp_path)
        return jsonify(text=text)

    return app


if __name__ == "__main__":
    host = os.getenv("WHISPER_TRANSFORMERS_HOST", "127.0.0.1")
    port = int(os.getenv("WHISPER_TRANSFORMERS_PORT", "4444"))
    print(f"transformers ASR server on http://{host}:{port} (model: {MODEL}, device: {DEVICE})")
    get_pipe()                                               # pre-load before serving
    create_app().run(host=host, port=port, threaded=True)
