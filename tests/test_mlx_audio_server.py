"""Contract test for the mlx-audio HTTP wrapper (Nemotron / Omnilingual / Cohere
on Apple Silicon).

mlx-audio only runs on Apple Silicon, so on Linux/CI we mock transcription at its
boundary (`transcribe_audio`) and verify the wrapper honours the same HTTP
contract the daemon relies on: `POST /v1/audio/transcriptions` (multipart file) →
JSON `{"text": ...}`, and `GET /` → `{"model": ...}`.
"""
import io
import pytest

import mlx_audio_server as srv


@pytest.fixture
def client(monkeypatch):
    "Flask test client with the mlx-audio boundary stubbed out."
    monkeypatch.setattr(srv, "transcribe_audio", lambda path: "hello from mlx-audio")
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
    assert resp.get_json()["text"] == "hello from mlx-audio"


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
