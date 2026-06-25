#!/usr/bin/env python3
"""HTTP wrapper exposing an NVIDIA NeMo ASR model as an OpenAI-shape transcription
endpoint, for Linux + NVIDIA GPU.

    POST /v1/audio/transcriptions   (multipart: file=<wav>)  → {"text": ...}

Serves NeMo-native ASR behind the `nemo_cuda` backend — primarily NVIDIA Nemotron
3.5 ASR (`nvidia/nemotron-3.5-asr-streaming-0.6b`). NeMo + torch are heavy and
GPU-bound, so the import is deferred into `get_model`; this module imports (and
its HTTP contract is testable) on any platform with the boundary mocked.

Run (Linux):  uv run --with "nemo_toolkit[asr]" python src/nemo_asr_server.py
Env:
    WHISPER_NEMO_MODEL   NeMo model id or .nemo path (default: Nemotron 3.5 0.6B)
    WHISPER_NEMO_HOST    bind host (default 127.0.0.1)
    WHISPER_NEMO_PORT    bind port (default 4444)
    WHISPER_LANG         language hint passed by the daemon (best-effort)
"""
import os, tempfile, pathlib
from typing import Any
from flask import Flask, request, jsonify

os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
MODEL = os.getenv("WHISPER_NEMO_MODEL", "nvidia/nemotron-3.5-asr-streaming-0.6b")

_model = None


def get_model():
    "Load and cache the NeMo ASR model. Imports NeMo lazily (heavy/GPU-bound)."
    global _model
    if _model is None:
        from nemo.collections.asr.models import ASRModel    # noqa: PLC0415 — deferred: heavy/GPU
        _model = ASRModel.from_pretrained(model_name=MODEL)
    return _model


def transcribe_audio(path: str, language: str | None = None) -> str:
    "Transcribe the WAV at `path` with the configured NeMo model."
    out = get_model().transcribe([path])
    hyp = out[0] if isinstance(out, (list, tuple)) else out  # NeMo returns a list of hypotheses/strings
    text = getattr(hyp, "text", hyp)                         # Hypothesis object or plain str
    return str(text).strip()


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
    host = os.getenv("WHISPER_NEMO_HOST", "127.0.0.1")
    port = int(os.getenv("WHISPER_NEMO_PORT", "4444"))
    print(f"NeMo ASR server on http://{host}:{port} (model: {MODEL})")
    get_model()                                             # pre-load before serving
    create_app().run(host=host, port=port, threaded=True)
