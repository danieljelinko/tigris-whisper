"""Integration test: the CrispASR server honors the same HTTP contract the daemon
relies on (`POST /v1/audio/transcriptions` → JSON with a `text` field).

Skipped unless the crispasr binary is installed (see `install_crispasr.sh`). This
is the Linux-CPU path for Cohere Transcribe (GGUF). The first run downloads the
~2.5 GB GGUF, so the readiness/model timeouts are generous.
"""
import os, socket, subprocess, time, pathlib
import pytest, requests

HERE    = pathlib.Path(__file__).parent
FIXTURE = HERE / "fixtures" / "sample_speech.wav"
BIN     = pathlib.Path(os.getenv("CRISPASR_BIN",
            pathlib.Path.home() / ".cache/crispasr/bin/crispasr"))
BACKEND = os.getenv("CRISPASR_BACKEND", "cohere")
MODEL   = os.getenv("WHISPER_CRISPASR_MODEL", "auto")


def _binary_runs() -> bool:
    "True only if crispasr is installed AND actually executes (libopenblas present)."
    if not BIN.exists(): return False
    try:
        return subprocess.run([str(BIN), "--version"], capture_output=True).returncode == 0
    except OSError:
        return False


pytestmark = pytest.mark.skipif(
    not _binary_runs(),
    reason=f"crispasr not installed/functional (run install_crispasr.sh; needs libopenblas); BIN={BIN}")


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0)); return s.getsockname()[1]


@pytest.fixture
def crispasr_server():
    "Launch crispasr --server on a free port, wait until it answers, tear it down."
    port = _free_port()
    model = MODEL if pathlib.Path(MODEL).is_file() else "auto"
    proc = subprocess.Popen(
        [str(BIN), "--server", "--backend", BACKEND, "-m", model,
         "--host", "127.0.0.1", "--port", str(port)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = f"http://127.0.0.1:{port}"
    try:
        for _ in range(600):                       # first-run GGUF download on CPU
            if proc.poll() is not None: pytest.fail("crispasr server exited during startup")
            try:
                requests.get(base, timeout=1); break
            except requests.ConnectionError:
                time.sleep(1)
        else:
            pytest.fail("crispasr server did not become ready in time")
        yield base + "/v1/audio/transcriptions"
    finally:
        proc.terminate(); proc.wait()


def test_crispasr_returns_json_with_text_field_for_wav(crispasr_server):
    # Given a running CrispASR server and a real spoken WAV
    with FIXTURE.open("rb") as f:
        # When we POST it the way the daemon does
        r = requests.post(crispasr_server,
                          files={"file": ("speech.wav", f, "audio/wav")}, timeout=180)

    # Then we get a 200 with a JSON body carrying a non-empty `text` string
    r.raise_for_status()
    body = r.json()
    assert "text" in body
    assert isinstance(body["text"], str) and body["text"].strip()
