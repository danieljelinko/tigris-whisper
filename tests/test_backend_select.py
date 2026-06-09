import pytest
from backend_select import select_backend, UnsupportedPlatformError


def test_select_backend_is_mlx_when_macos():
    # Given a macOS host (GPU flag irrelevant on Mac)
    # When we select a backend
    result = select_backend("Darwin", has_nvidia_gpu=False)

    # Then it defaults to the mlx-whisper backend
    assert result == "mlx"


def test_select_backend_allows_whispercpp_metal_override_on_macos():
    # Given a macOS host but an explicit whisper.cpp override
    # When we select a backend
    result = select_backend("Darwin", has_nvidia_gpu=False, override="whispercpp_metal")

    # Then the override wins (whisper.cpp Metal stays available as a fallback)
    assert result == "whispercpp_metal"


def test_select_backend_is_docker_cuda_when_linux_with_nvidia_gpu():
    # Given a Linux host with a working NVIDIA GPU
    # When we select a backend
    result = select_backend("Linux", has_nvidia_gpu=True)

    # Then it uses the Docker CUDA backend
    assert result == "docker_cuda"


def test_select_backend_is_faster_whisper_when_linux_without_gpu():
    # Given a Linux host with no usable GPU
    # When we select a backend
    result = select_backend("Linux", has_nvidia_gpu=False)

    # Then it uses faster-whisper (the new default Linux CPU backend)
    assert result == "faster_whisper"


def test_select_backend_honors_override_over_detection():
    # Given a Linux+GPU host but an explicit backend override
    # When we select a backend
    result = select_backend("Linux", has_nvidia_gpu=True, override="whispercpp_cpu")

    # Then the override wins
    assert result == "whispercpp_cpu"


def test_select_backend_rejects_unknown_override():
    # Given an invalid override value
    # When we select a backend
    # Then it raises rather than silently dispatching wrong
    with pytest.raises(ValueError):
        select_backend("Linux", has_nvidia_gpu=True, override="bogus")


def test_select_backend_raises_on_unsupported_platform():
    # Given an unsupported OS with no override
    # When we select a backend
    # Then it raises a clear platform error
    with pytest.raises(UnsupportedPlatformError):
        select_backend("Windows", has_nvidia_gpu=False)
