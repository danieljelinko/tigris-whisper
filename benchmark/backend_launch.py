"""Context manager that starts a local tigris-whisper backend for benchmarking.

Reuses the existing scripts/lib/backend_*.sh scripts (idempotent: they reuse a
running server if one is already up on the port). Yields the base URL.

Usage:
    with launched_backend("faster_whisper", model="small") as base_url:
        text, latency = transcribe(base_url + "/v1/audio/transcriptions", ...)
"""
import os, subprocess, pathlib, contextlib
from typing import Iterator

REPO = pathlib.Path(__file__).parent.parent

BACKEND_SCRIPTS = {
    "faster_whisper":  REPO / "scripts/lib/backend_faster_whisper.sh",
    "whispercpp_cpu":  REPO / "scripts/lib/backend_whispercpp.sh",
    "whispercpp_metal": REPO / "scripts/lib/backend_whispercpp.sh",
    "docker_cuda":     REPO / "scripts/lib/backend_docker.sh",
    "mlx":             REPO / "scripts/lib/backend_mlx.sh",
    "mlx_audio":       REPO / "scripts/lib/backend_mlx_audio.sh",
    "transformers_cuda": REPO / "scripts/lib/backend_transformers.sh",
    "nemo_cuda":       REPO / "scripts/lib/backend_nemo.sh",
    "crispasr":        REPO / "scripts/lib/backend_crispasr.sh",
}

ENSURE_FN = {
    "faster_whisper":   "ensure_faster_whisper_backend",
    "whispercpp_cpu":   "ensure_whispercpp_backend --cpu",
    "whispercpp_metal": "ensure_whispercpp_backend",
    "docker_cuda":      "ensure_docker_backend",
    "mlx":              "ensure_mlx_backend",
    "mlx_audio":        "ensure_mlx_audio_backend",
    "transformers_cuda": "ensure_transformers_backend",
    "nemo_cuda":        "ensure_nemo_backend",
    "crispasr":         "ensure_crispasr_backend",
}

PORT_VARS = {
    "faster_whisper":  "FASTER_WHISPER_PORT",
    "whispercpp_cpu":  "WHISPERCPP_PORT",
    "whispercpp_metal": "WHISPERCPP_PORT",
    "docker_cuda":     "WHISPER_PORT",
    "mlx":             "WHISPER_MLX_PORT",
    "mlx_audio":       "WHISPER_MLX_AUDIO_PORT",
    "transformers_cuda": "WHISPER_TRANSFORMERS_PORT",
    "nemo_cuda":       "WHISPER_NEMO_PORT",
    "crispasr":        "WHISPER_CRISPASR_PORT",
}

MODEL_VARS = {
    "faster_whisper":  "FASTER_WHISPER_MODEL",
    "whispercpp_cpu":  "WHISPERCPP_MODEL",
    "whispercpp_metal": "WHISPERCPP_MODEL",
    "mlx":             "WHISPER_MLX_MODEL",
    "mlx_audio":       "WHISPER_MLX_AUDIO_MODEL",
    "transformers_cuda": "WHISPER_TRANSFORMERS_MODEL",
    "nemo_cuda":       "WHISPER_NEMO_MODEL",
    "crispasr":        "WHISPER_CRISPASR_MODEL",
    "docker_cuda":     None,
}


@contextlib.contextmanager
def launched_backend(backend_id: str, model: str | None = None,
                     port: int = 4444) -> Iterator[str]:
    "Source the backend shell script, call ensure_*, yield base URL."
    if backend_id not in BACKEND_SCRIPTS:
        raise ValueError(f"unknown backend: {backend_id!r}. "
                         f"Choose from: {list(BACKEND_SCRIPTS)}")
    script = BACKEND_SCRIPTS[backend_id]
    if not script.exists():
        raise FileNotFoundError(f"backend script not found: {script}")

    env = os.environ.copy()
    port_var = PORT_VARS.get(backend_id)
    if port_var:
        env[port_var] = str(port)
    model_var = MODEL_VARS.get(backend_id)
    if model_var and model:
        env[model_var] = model

    fn_call = ENSURE_FN[backend_id]
    # Source the script and call the ensure_ function in one bash invocation.
    # The function handles pre-download, readiness poll, and PID tracking.
    result = subprocess.run(
        ["bash", "-c", f"source {script} && {fn_call}"],
        env=env, cwd=str(REPO),
    )
    if result.returncode != 0:
        raise RuntimeError(f"backend {backend_id!r} failed to start (exit {result.returncode})")

    base_url = f"http://localhost:{port}"
    try:
        yield base_url
    finally:
        # The backend scripts trap EXIT for their own PID cleanup, but we also
        # send a best-effort kill to any server process listening on the port.
        subprocess.run(
            ["bash", "-c",
             f"pkill -f '{backend_id}_server.py' 2>/dev/null || true; "
             f"pkill -f 'whisper-server.*{port}' 2>/dev/null || true"],
            check=False,
        )
