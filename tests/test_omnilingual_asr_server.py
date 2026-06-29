"""Contract test for the Meta Omnilingual ASR HTTP wrapper (Linux + GPU/CPU).

Omnilingual is fairseq2-based (Meta's `omnilingual-asr` package), not a
transformers model — so it needs its own backend. The package + fairseq2 are
heavy and GPU-bound, so we mock transcription at its boundary (`transcribe_audio`)
and verify the wrapper honours the daemon's HTTP contract.

Also covers the ISO-639-1 → Omnilingual language-code mapping, which is pure logic.
"""
import io
import pytest

import omnilingual_asr_server as srv


@pytest.fixture
def client(monkeypatch):
    "Flask test client with the omnilingual boundary stubbed out."
    monkeypatch.setattr(srv, "transcribe_audio", lambda path, language=None: "hello from omnilingual")
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
    assert resp.get_json()["text"] == "hello from omnilingual"


def test_transcribe_returns_400_when_no_file(client):
    # Given a request with no file part
    resp = client.post("/v1/audio/transcriptions", data={},
                       content_type="multipart/form-data")

    # Then the wrapper rejects it clearly rather than 500-ing
    assert resp.status_code == 400


def test_health_reports_the_configured_model(client):
    # Given the readiness probe run.sh polls
    resp = client.get("/")

    # Then it returns the model id so the harness can identify the backend
    assert resp.status_code == 200
    assert resp.get_json()["model"] == srv.MODEL


def test_omni_lang_maps_iso_639_1_to_script_tagged_code():
    # Given short ISO codes the daemon sends
    # When mapped to Omnilingual's {lang}_{script} format
    # Then known languages get their script tag, Hungarian included
    assert srv.omni_lang("en") == "eng_Latn"
    assert srv.omni_lang("fr") == "fra_Latn"
    assert srv.omni_lang("hu") == "hun_Latn"


def test_omni_lang_passes_through_full_codes_and_defaults():
    # Given an already-qualified code or nothing
    # When mapped
    # Then a full code is preserved and the default is English
    assert srv.omni_lang("deu_Latn") == "deu_Latn"   # already qualified → unchanged
    assert srv.omni_lang(None) == "eng_Latn"          # default
    assert srv.omni_lang("") == "eng_Latn"
