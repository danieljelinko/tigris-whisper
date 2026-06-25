"""Collect host hardware metadata for benchmark report tagging."""
import platform, socket, subprocess, shutil


def _cpu_model() -> str:
    if platform.system() == "Linux":
        try:
            out = subprocess.check_output(["lscpu"], text=True)
            for line in out.splitlines():
                if "Model name" in line:
                    return line.split(":", 1)[1].strip()
        except Exception: pass
    if platform.system() == "Darwin":
        try:
            return subprocess.check_output(
                ["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
        except Exception: pass
    return platform.processor() or "unknown"


def _has_nvidia() -> bool:
    return shutil.which("nvidia-smi") is not None and (
        subprocess.run(["nvidia-smi", "-L"], capture_output=True).returncode == 0)


def collect() -> dict:
    "Return a dict with os, cpu, hostname, python, has_nvidia."
    return {
        "os":        platform.system(),
        "os_ver":    platform.release(),
        "cpu":       _cpu_model(),
        "hostname":  socket.gethostname(),
        "python":    platform.python_version(),
        "has_nvidia": _has_nvidia(),
    }
