#!/usr/bin/env python3
"""Pure backend-selection logic for the whisper-hotkey launcher.

Kept free of subprocess/probing so it is trivially unit-testable: the shell
launcher probes the real `uname` and GPU state and passes them in as args.
"""
import sys
from typing import Literal

Backend = Literal["docker_cuda", "faster_whisper", "whispercpp_cpu", "whispercpp_metal", "mlx"]
BACKENDS: set[str] = {"docker_cuda", "faster_whisper", "whispercpp_cpu", "whispercpp_metal", "mlx"}


class UnsupportedPlatformError(RuntimeError):
    "Raised when the host OS has no defined backend and no override is given."


def select_backend(system: str, has_nvidia_gpu: bool, override: str | None = None) -> Backend:
    "Pick a transcription backend from `system` (`uname -s`) and GPU availability."
    if override:
        if override not in BACKENDS: raise ValueError(f"unknown backend override: {override!r}")
        return override                                    # type: ignore[return-value]
    if system == "Darwin": return "mlx"                    # native Apple-Silicon wheels; whispercpp_metal as override
    if system == "Linux":  return "docker_cuda" if has_nvidia_gpu else "faster_whisper"
    raise UnsupportedPlatformError(f"no backend for platform {system!r} (set WHISPER_BACKEND to override)")


if __name__ == "__main__":                                 # CLI seam for run.sh: prints the chosen backend
    import argparse
    p = argparse.ArgumentParser(description="Print the selected whisper backend id")
    p.add_argument("--system", default="")                 # empty → detect via platform.system()
    p.add_argument("--has-nvidia-gpu", action="store_true")
    p.add_argument("--override", default="")
    a = p.parse_args()
    import platform
    system = a.system or platform.system()
    print(select_backend(system, a.has_nvidia_gpu, a.override or None))
    sys.exit(0)
