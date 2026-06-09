"""HTTP client for the tigris-whisper transcription endpoint.

All backends expose the same contract:
  POST /v1/audio/transcriptions  multipart file= + form language=  → {"text": ...}
  GET  /                                                            → {"status", "model"}
"""
import time, pathlib
import requests
import soundfile as sf


def transcribe(endpoint: str, audio_path: pathlib.Path | str,
               language: str, *, timeout: int = 180) -> tuple[str, float]:
    "POST audio to endpoint, return (transcript_text, latency_seconds)."
    audio_path = pathlib.Path(audio_path)
    t0 = time.perf_counter()
    with audio_path.open("rb") as fh:
        resp = requests.post(
            endpoint,
            files={"file": (audio_path.name, fh, "audio/wav")},
            data={"language": language},
            timeout=timeout,
        )
    resp.raise_for_status()
    text = resp.json().get("text", "").strip()
    latency = time.perf_counter() - t0
    return text, latency


def probe_model(base_url: str, *, timeout: int = 5) -> str:
    "GET / → model id string, or 'unknown' if the field is absent."
    resp = requests.get(base_url, timeout=timeout)
    resp.raise_for_status()
    return resp.json().get("model", "unknown")


def audio_duration_s(audio_path: pathlib.Path | str) -> float:
    "Return duration of a WAV/audio file in seconds using soundfile."
    info = sf.info(str(audio_path))
    return info.frames / info.samplerate
