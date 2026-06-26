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
import os, re, json, tempfile, pathlib
from typing import Any
from flask import Flask, request, jsonify

os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
MODEL = os.getenv("WHISPER_NEMO_MODEL", "nvidia/nemotron-3.5-asr-streaming-0.6b")
# Nemotron 3.5 is a prompt-conditioned model: it needs a language key per utterance
# (e.g. en, fr, hu). Default is configurable; the daemon's per-request language wins.
DEFAULT_LANG = os.getenv("WHISPER_NEMO_LANG", "en")

_LANG_TAG = re.compile(r"\s*<[a-zA-Z]{2}(?:-[a-zA-Z]{2,})?>\s*$")  # trailing "<en-US>" tag the model emits

_model = None


def get_model():
    "Load the NeMo ASR model and disable the CUDA-graph decoder. Imports NeMo lazily."
    global _model
    if _model is None:
        from nemo.collections.asr.models import ASRModel    # noqa: PLC0415 — deferred: heavy/GPU
        m = ASRModel.from_pretrained(model_name=MODEL)
        try:                                                # CUDA-graph RNNT decoder OOMs / replays None on some GPUs
            from omegaconf import open_dict
            dec = m.cfg.decoding
            with open_dict(dec):
                if dec.get("greedy") is None: dec.greedy = {}
                dec.greedy.use_cuda_graph_decoder = False
            m.change_decoding_strategy(dec)
        except Exception:                                   # non-RNNT models won't have this knob — ignore
            pass
        _model = m
    return _model


def _write_manifest(path: str, language: str) -> str:
    "Write a one-line NeMo manifest carrying the language (prompt models read `lang`)."
    import soundfile as sf                                  # noqa: PLC0415 — only needed for real inference
    info = sf.info(path)
    entry = {"audio_filepath": os.path.abspath(path),
             "duration": info.frames / info.samplerate, "text": "", "lang": language}
    fd, mpath = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "w") as f: f.write(json.dumps(entry) + "\n")
    return mpath


def transcribe_audio(path: str, language: str | None = None) -> str:
    "Transcribe the WAV at `path` with the configured NeMo model."
    lang = language or DEFAULT_LANG
    model = get_model()
    manifest = _write_manifest(path, lang)
    try:
        cfg = model.get_transcribe_config()                 # RNNTPromptTranscribeConfig for Nemotron
        if hasattr(cfg, "manifest_filepath"): cfg.manifest_filepath = manifest
        if hasattr(cfg, "target_lang"):       cfg.target_lang = lang
        if hasattr(cfg, "batch_size"):        cfg.batch_size = 1
        out = model.transcribe(audio=[path], override_config=cfg)
    except (TypeError, AttributeError):
        out = model.transcribe([path])                      # plain NeMo models: no prompt/override config
    finally:
        os.unlink(manifest)
    hyp = out[0] if isinstance(out, (list, tuple)) else out  # list of hypotheses/strings
    text = str(getattr(hyp, "text", hyp))                   # Hypothesis object or plain str
    return _LANG_TAG.sub("", text).strip()                  # drop the trailing "<en-US>" tag


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
