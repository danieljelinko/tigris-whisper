#!/usr/bin/env python3
# whisper_hotkey_mac.py
"""
Hold Ctrl + Option + Cmd to start dictation, release *either* Ctrl key to stop.
The captured audio is sent to a Whisper server and the transcription is copied
to the clipboard and pasted (⌘-V) into the front-most application.

Prereqs (Python ≥ 3.10):
    pip install sounddevice numpy pynput requests
    # sounddevice wheels already bundle PortAudio on macOS; no Homebrew needed.
"""

import ctypes, os, pathlib, logging, time, tempfile, queue, wave, subprocess
import requests, numpy as np, sounddevice as sd
from pynput.keyboard import Key, Listener

# ── Settings ──────────────────────────────────────────────────────────────
API          = os.getenv("WHISPER_API",
                         "http://localhost:4444/v1/audio/transcriptions")
RATE         = 16_000           # Hz
CHANNELS     = 1
LOG_FILE     = pathlib.Path.home() / "whisper_hotkey_mac.log"
TMP_WAV      = pathlib.Path(tempfile.gettempdir()) / "whisper_tmp.wav"
CTRL_KEYS    = {Key.ctrl_l, Key.ctrl_r}
ALT_KEYS     = {Key.alt_l, Key.alt_r}
CMD_KEYS     = {Key.cmd_l, Key.cmd_r}
# Modifier-only chord (Ctrl+Option+Cmd), not modifier+Space: on this hardware,
# real hardware key presses combined with any modifier(s) plus Space never
# reach pynput's event tap (tried Ctrl+Option+Space, Ctrl+Shift+Space, and
# Option+Space alone — all silently dropped), while standalone modifier
# key-down/key-up events are always delivered reliably. Using three modifiers
# with no regular key avoids whatever is eating Space entirely.

# ── Logging ───────────────────────────────────────────────────────────────
HOTKEY_DEBUG = os.getenv("WHISPER_HOTKEY_DEBUG") == "1"
logging.basicConfig(
    level=logging.DEBUG if HOTKEY_DEBUG else logging.INFO,
    format="%(asctime)s %(levelname)s: %(message)s",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler()]
)
log = logging.getLogger("whisper_hotkey")

# ── macOS notification helper (osa-script)─────────────────────────────────
def _escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')

def notify(title: str, body: str = "") -> None:
    try:
        osa = f'display notification "{_escape(body)}" with title "{_escape(title)}"'
        subprocess.run(["osascript", "-e", osa], check=True)
    except Exception as e:
        log.debug("Notification failed: %s", e)

def copy_to_clipboard(text: str) -> None:
    subprocess.run(["pbcopy"], input=text, text=True, check=True)

def paste_frontmost() -> None:
    lines = ['tell application "System Events"']
    if target_app:
        lines.extend([
            f'  tell application process "{_escape(target_app)}" to set frontmost to true',
            "  delay 0.15",
        ])
    lines.extend([
        '  keystroke "v" using command down',
        "end tell",
    ])
    result = subprocess.run(["osascript", "-e", "\n".join(lines)], text=True, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout or "osascript paste failed").strip())

def frontmost_app_name() -> str | None:
    osa = 'tell application "System Events" to get name of first application process whose frontmost is true'
    result = subprocess.run(["osascript", "-e", osa], text=True, capture_output=True)
    if result.returncode != 0:
        log.warning("Could not read frontmost app: %s", (result.stderr or result.stdout).strip())
        return None
    return result.stdout.strip() or None

# ── Recorder state ────────────────────────────────────────────────────────
stream       = None                   # active sounddevice.InputStream
queue_frames: "queue.Queue[np.ndarray]" = queue.Queue()
pressed      = set()
target_app   = None

def _audio_cb(indata, frames, t, status):
    queue_frames.put(indata.copy())

def preflight_microphone():
    """Trigger macOS microphone consent at app startup instead of first hotkey."""
    try:
        with sd.InputStream(samplerate=RATE, channels=CHANNELS, dtype="int16"):
            time.sleep(0.1)
        log.info("Microphone preflight OK")
    except Exception as e:
        log.warning("Microphone preflight failed or permission missing: %s", e)
        notify(
            "Microphone permission needed",
            "Open Privacy & Security → Microphone and enable tigris-whisper.",
        )

def accessibility_trusted() -> bool | None:
    """Return whether this process is trusted for macOS Accessibility events."""
    try:
        app_services = ctypes.cdll.LoadLibrary(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        )
        app_services.AXIsProcessTrusted.restype = ctypes.c_bool
        return bool(app_services.AXIsProcessTrusted())
    except Exception as e:
        log.debug("Accessibility trust check failed: %s", e)
        return None

def preflight_accessibility():
    trusted = accessibility_trusted()
    if trusted is True:
        log.info("Accessibility preflight OK")
        return
    if trusted is None:
        log.warning("Could not verify Accessibility permission before starting hotkey listener.")
        return

    msg = (
        "Accessibility permission missing. Automatic paste (⌘V) will not work. "
        "If running ./run.sh, enable your terminal app in System Settings → Privacy & Security → "
        "Accessibility. If launching the app, enable tigris-whisper. Restart after granting permission."
    )
    log.warning(msg)
    notify("Accessibility permission needed", "Enable your terminal app or tigris-whisper, then restart.")

# ── Input Monitoring (macOS 10.15+) ───────────────────────────────────────
# The global hotkey listener is a Quartz event tap; on macOS 10.15+ it only
# RECEIVES key events when this process's host app is granted *Input Monitoring*
# (TCC service kTCCServiceListenEvent). This is a DIFFERENT permission from
# Accessibility: Accessibility governs posting the ⌘V paste, Input Monitoring
# governs receiving the hotkey. Without it the hotkey is silently dead and the
# keystrokes fall through to the foreground app, so check it explicitly — the
# old code only checked Accessibility and reported "OK" while the hotkey did
# nothing.
_HID_REQUEST_LISTEN_EVENT = 1                 # kIOHIDRequestTypeListenEvent
_HID_ACCESS = {0: True, 1: False, 2: None}    # granted / denied / unknown

def _iokit():
    return ctypes.cdll.LoadLibrary(
        "/System/Library/Frameworks/IOKit.framework/IOKit"
    )

def input_monitoring_trusted() -> bool | None:
    """Return True (granted), False (denied), or None (unknown/unavailable)."""
    try:
        iokit = _iokit()
        iokit.IOHIDCheckAccess.restype = ctypes.c_int
        iokit.IOHIDCheckAccess.argtypes = [ctypes.c_uint32]
        return _HID_ACCESS.get(iokit.IOHIDCheckAccess(_HID_REQUEST_LISTEN_EVENT))
    except Exception as e:
        log.debug("Input Monitoring trust check failed: %s", e)
        return None

def request_input_monitoring() -> None:
    """Prompt macOS to add this app to the Input Monitoring list (shows the dialog)."""
    try:
        iokit = _iokit()
        iokit.IOHIDRequestAccess.restype = ctypes.c_bool
        iokit.IOHIDRequestAccess.argtypes = [ctypes.c_uint32]
        iokit.IOHIDRequestAccess(_HID_REQUEST_LISTEN_EVENT)
    except Exception as e:
        log.debug("Input Monitoring request failed: %s", e)

def preflight_input_monitoring():
    trusted = input_monitoring_trusted()
    if trusted is True:
        log.info("Input Monitoring preflight OK")
        return
    if trusted is None:
        log.warning("Could not verify Input Monitoring permission before starting hotkey listener.")
        return

    # Denied: surface the system dialog and tell the user exactly what to enable.
    request_input_monitoring()
    msg = (
        "Input Monitoring permission missing — the Ctrl+Option+Cmd hotkey will NOT fire "
        "(your keystrokes go to the active app instead). This is SEPARATE from Accessibility. "
        "If running ./run.sh, enable your terminal app in System Settings → Privacy & Security → "
        "Input Monitoring. If launching the app, enable tigris-whisper. Restart after granting it."
    )
    log.warning(msg)
    notify("Input Monitoring permission needed",
           "Enable your terminal app or tigris-whisper under Input Monitoring, then restart.")

def start_recording():
    global stream, target_app
    if stream is not None:
        return
    target_app = frontmost_app_name()
    log.info("Paste target app: %s", target_app or "unknown")
    queue_frames.queue.clear()
    stream = sd.InputStream(samplerate=RATE, channels=CHANNELS,
                            dtype="int16", callback=_audio_cb)
    stream.start()
    notify("Listening…")
    log.info("Recording started")

def stop_recording():
    global stream
    if stream is None:
        return
    stream.stop(); stream.close(); stream = None
    log.info("Recording stopped; assembling WAV")

    with wave.open(str(TMP_WAV), "wb") as wf:
        wf.setnchannels(CHANNELS)
        wf.setsampwidth(2)           # int16
        wf.setframerate(RATE)
        while not queue_frames.empty():
            wf.writeframes(queue_frames.get().tobytes())

    notify("Transcribing…")
    try:
        with TMP_WAV.open("rb") as f:
            r = requests.post(API, files={"file": ("speech.wav", f, "audio/wav")})
            r.raise_for_status()
        text = r.json().get("text", "").strip()
        log.info("Transcript: %s", text)
    except Exception as e:
        notify("Transcription error", str(e))
        log.error("Transcription failed: %s", e)
        return

    # clipboard + paste; System Events requires Accessibility permission.
    try:
        copy_to_clipboard(text)
        paste_frontmost()
    except Exception as e:
        log.warning("Paste failed; transcript remains available in logs: %s", e)
        notify("Paste permission needed", "Enable Accessibility for tigris-whisper or your terminal app.")
    notify("Done", text[:200] + ("…" if len(text) > 200 else ""))

# ── Hot-key logic ─────────────────────────────────────────────────────────
def on_press(key):
    pressed.add(key)
    if HOTKEY_DEBUG:
        log.debug("key down: %r  pressed=%r", key, pressed)
    if (stream is None
        and pressed & CTRL_KEYS
        and pressed & ALT_KEYS
        and pressed & CMD_KEYS):
        start_recording()

def on_release(key):
    if HOTKEY_DEBUG:
        log.debug("key up: %r  pressed=%r", key, pressed)
    if key in CTRL_KEYS and stream is not None:
        stop_recording()
    pressed.discard(key)

log.info("Whisper hot-key daemon (macOS) ready. "
         "Hold Ctrl+Option+Cmd to record; release Ctrl to stop.  API=%s", API)
preflight_microphone()
preflight_input_monitoring()   # required to RECEIVE the hotkey
preflight_accessibility()      # required to POST the ⌘V paste

try:
    with Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()
except KeyboardInterrupt:
    log.info("Interrupted, exiting")
