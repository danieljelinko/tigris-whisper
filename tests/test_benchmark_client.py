"""Tests for benchmark/transcribe_client.py — mocks only the HTTP boundary."""
import pathlib, time
import pytest

FIXTURE = pathlib.Path(__file__).parent / "fixtures" / "sample_speech.wav"


# ── transcribe ────────────────────────────────────────────────────────────────

def test_transcribe_returns_text_and_latency(monkeypatch):
    # Given a server that returns {"text": "hello world"}
    import requests
    from benchmark.transcribe_client import transcribe

    class FakeResp:
        def raise_for_status(self): pass
        def json(self): return {"text": "hello world"}

    monkeypatch.setattr(requests, "post", lambda *a, **kw: FakeResp())

    # When we transcribe
    text, latency = transcribe("http://x/v1/audio/transcriptions", FIXTURE, "en")

    # Then text is returned and latency is a non-negative float
    assert text == "hello world"
    assert isinstance(latency, float) and latency >= 0.0


def test_transcribe_sends_language_field(monkeypatch):
    # Given a spy on requests.post
    import requests
    from benchmark.transcribe_client import transcribe

    captured = {}

    class FakeResp:
        def raise_for_status(self): pass
        def json(self): return {"text": "bonjour"}

    def fake_post(url, *, files, data, timeout):
        captured["data"] = data
        return FakeResp()

    monkeypatch.setattr(requests, "post", fake_post)

    # When we transcribe with language "fr"
    transcribe("http://x/v1/audio/transcriptions", FIXTURE, "fr")

    # Then the language field is included in the POST data
    assert captured["data"].get("language") == "fr"


def test_transcribe_measures_elapsed_time(monkeypatch):
    # Given a server that sleeps 50 ms
    import requests
    from benchmark.transcribe_client import transcribe

    class SlowResp:
        def raise_for_status(self): pass
        def json(self):
            time.sleep(0.05)
            return {"text": "slow"}

    monkeypatch.setattr(requests, "post", lambda *a, **kw: SlowResp())

    _, latency = transcribe("http://x/v1/audio/transcriptions", FIXTURE, "en")
    assert latency >= 0.04   # at least ~50 ms


# ── probe_model ────────────────────────────────────────────────────────────────

def test_probe_model_returns_model_string(monkeypatch):
    import requests
    from benchmark.transcribe_client import probe_model

    class FakeResp:
        def raise_for_status(self): pass
        def json(self): return {"status": "ok", "model": "small"}

    monkeypatch.setattr(requests, "get", lambda *a, **kw: FakeResp())

    assert probe_model("http://localhost:4444") == "small"


def test_probe_model_returns_unknown_on_missing_field(monkeypatch):
    import requests
    from benchmark.transcribe_client import probe_model

    class FakeResp:
        def raise_for_status(self): pass
        def json(self): return {"status": "ok"}  # no "model" key

    monkeypatch.setattr(requests, "get", lambda *a, **kw: FakeResp())

    assert probe_model("http://localhost:4444") == "unknown"


# ── audio_duration_s ──────────────────────────────────────────────────────────

def test_audio_duration_s_returns_float_for_fixture():
    from benchmark.transcribe_client import audio_duration_s
    # Given the existing test fixture WAV
    dur = audio_duration_s(FIXTURE)
    # Then duration is a positive float (fixture ~4s of speech)
    assert isinstance(dur, float) and dur > 0.5
