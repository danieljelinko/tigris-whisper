#!/usr/bin/env python3
"""HTTP wrapper exposing Meta Omnilingual ASR as an OpenAI-shape transcription
endpoint, for Linux (NVIDIA GPU or CPU).

    POST /v1/audio/transcriptions   (multipart: file=<wav>)  → {"text": ...}

Omnilingual is fairseq2-based — it is NOT a transformers model (its config.json
has no `model_type`, so `transformers.pipeline` can't load it). It runs through
Meta's `omnilingual-asr` package, imported lazily here so this module imports (and
its HTTP contract is testable) on any platform with the boundary mocked.

Run (Linux):  uv run --with omnilingual-asr python src/omnilingual_asr_server.py
Env:
    WHISPER_OMNILINGUAL_MODEL   model_card (default omniASR_LLM_300M_v2; ~5 GB VRAM)
    WHISPER_OMNILINGUAL_LANG    default language as an Omnilingual code (eng_Latn)
    WHISPER_OMNILINGUAL_HOST    bind host (default 127.0.0.1)
    WHISPER_OMNILINGUAL_PORT    bind port (default 4444)
"""
import os, tempfile, pathlib
from typing import Any
from flask import Flask, request, jsonify

os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
MODEL = os.getenv("WHISPER_OMNILINGUAL_MODEL", "omniASR_LLM_300M_v2")
DEFAULT_LANG = os.getenv("WHISPER_OMNILINGUAL_LANG", "eng_Latn")

# ISO 639-1 → Omnilingual {lang}_{script} codes (the families our daemon sends).
_ISO_TO_OMNI: dict[str, str] = {
    "en": "eng_Latn", "fr": "fra_Latn", "hu": "hun_Latn", "de": "deu_Latn",
    "es": "spa_Latn", "it": "ita_Latn", "pt": "por_Latn", "nl": "nld_Latn",
    "pl": "pol_Latn", "ru": "rus_Cyrl", "ar": "arb_Arab", "zh": "cmn_Hans",
    "ja": "jpn_Jpan", "ko": "kor_Hang",
}

_pipeline = None


def omni_lang(language: str | None) -> str:
    "Map an ISO-639-1 code to an Omnilingual code; pass full codes through; default English."
    if not language: return DEFAULT_LANG
    if "_" in language: return language                     # already a full {lang}_{script} code
    return _ISO_TO_OMNI.get(language.lower(), DEFAULT_LANG)


def get_pipeline():
    "Build and cache the Omnilingual inference pipeline. Imports the lib lazily (heavy/GPU)."
    global _pipeline
    if _pipeline is None:
        from omnilingual_asr.models.inference.pipeline import ASRInferencePipeline  # noqa: PLC0415
        _pipeline = ASRInferencePipeline(model_card=MODEL)
    return _pipeline


def transcribe_audio(path: str, language: str | None = None) -> str:
    "Transcribe the WAV at `path` with the configured Omnilingual model."
    code = omni_lang(language)
    out = get_pipeline().transcribe([path], lang=[code])
    hyp = out[0] if isinstance(out, (list, tuple)) else out
    return str(getattr(hyp, "text", hyp)).strip()


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
    host = os.getenv("WHISPER_OMNILINGUAL_HOST", "127.0.0.1")
    port = int(os.getenv("WHISPER_OMNILINGUAL_PORT", "4444"))
    print(f"Omnilingual ASR server on http://{host}:{port} (model: {MODEL})")
    get_pipeline()                                          # pre-load before serving
    create_app().run(host=host, port=port, threaded=True)
