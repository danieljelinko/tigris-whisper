"""Contract test for the HF-transformers ASR HTTP wrapper (Cohere Transcribe /
Meta Omnilingual on Linux+NVIDIA GPU).

transformers + torch are heavy and GPU-bound, so we mock transcription at its
boundary (`transcribe_audio`) and verify the wrapper honours the daemon's HTTP
contract: `POST /v1/audio/transcriptions` (multipart file) → JSON `{"text": ...}`,
and `GET /` → `{"model": ...}`.
"""
import io
import pytest

import transformers_asr_server as srv


@pytest.fixture
def client(monkeypatch):
    "Flask test client with the transformers boundary stubbed out."
    monkeypatch.setattr(srv, "transcribe_audio", lambda path, language=None: "hello from transformers")
    app = srv.create_app()
    app.config.update(TESTING=True)
    return app.test_client()


def test_transcribe_returns_json_text_for_uploaded_wav(client):
    # Given a multipart upload shaped exactly like the daemon sends
    data = {"file": (io.BytesIO(b"RIFFfake-wav-bytes"), "speech.wav", "audio/wav")}

    # When posted to the OpenAI-shape endpoint
    resp = client.post("/v1/audio/transcriptions", data=data,
                       content_type="multipart/form-data")

    # Then we get 200 with the transcript in a `text` field
    assert resp.status_code == 200
    assert resp.get_json()["text"] == "hello from transformers"


def test_transcribe_returns_400_when_no_file(client):
    # Given a request with no file part
    # When posted
    resp = client.post("/v1/audio/transcriptions", data={},
                       content_type="multipart/form-data")

    # Then the wrapper rejects it clearly rather than 500-ing
    assert resp.status_code == 400


def test_health_reports_the_configured_model(client):
    # Given the readiness probe run.sh polls
    # When we GET /
    resp = client.get("/")

    # Then it returns the model id so the harness can identify the backend
    assert resp.status_code == 200
    assert resp.get_json()["model"] == srv.MODEL
