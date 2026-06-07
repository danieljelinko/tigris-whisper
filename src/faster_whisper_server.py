#!/usr/bin/env python3
"""Minimal HTTP wrapper exposing faster-whisper as an OpenAI-shape transcription
endpoint, so the existing daemon can use it unchanged on Linux (CPU).

    POST /v1/audio/transcriptions   (multipart: file=<wav>)  → {"text": ...}

Run:  uv run src/faster_whisper_server.py
Env:
    FASTER_WHISPER_MODEL   model size id (default: small)
    FASTER_WHISPER_HOST    bind host (default 127.0.0.1)
    FASTER_WHISPER_PORT    bind port (default 4444)
    WHISPER_LANG           language hint passed by the daemon (default: auto)
"""
import os, tempfile, pathlib
from typing import Any
from flask import Flask, request, jsonify

MODEL = os.getenv("FASTER_WHISPER_MODEL", "small")

_model = None


def get_model():
    global _model
    if _model is None:
        from faster_whisper import WhisperModel            # noqa: PLC0415 — deferred for testability
        _model = WhisperModel(MODEL, device="cpu", compute_type="int8")
    return _model


def transcribe_audio(path: str, language: str | None = None) -> str:
    segments, _ = get_model().transcribe(path, language=language or None, beam_size=5)
    return "".join(seg.text for seg in segments).strip()


def create_app() -> Flask:
    app = Flask(__name__)

    @app.get("/")
    def health() -> Any:                                   # readiness probe for run.sh wait loop
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
    host = os.getenv("FASTER_WHISPER_HOST", "127.0.0.1")
    port = int(os.getenv("FASTER_WHISPER_PORT", "4444"))
    print(f"faster-whisper server on http://{host}:{port} (model: {MODEL})")
    get_model()                                            # pre-load before serving
    create_app().run(host=host, port=port, threaded=True)
