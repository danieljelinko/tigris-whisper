#!/usr/bin/env python3
"""Interactive helper for recording benchmark audio.

Walks `benchmark/data/<category>/<length>/<lang>.txt`, finds reference texts
that don't yet have a matching `.wav`, and records them one by one: the text
stays printed on screen (no live VU meter to scroll it away), and pressing
Ctrl-C stops the recording, saves the `.wav`, and moves on to the next text.

Usage:
  uv run python benchmark/record_audio.py
  uv run python benchmark/record_audio.py --device hw:1,0   # pick an ALSA mic
"""
import argparse, pathlib, signal, subprocess, sys

REPO = pathlib.Path(__file__).parent.parent
DATA_DIR = pathlib.Path(__file__).parent / "data"


def find_pending(data_dir: pathlib.Path) -> list[pathlib.Path]:
    "Reference texts under `data_dir` that don't have a matching .wav yet."
    return sorted(p for p in data_dir.glob("*/*/*.txt") if not p.with_suffix(".wav").exists())


def record(out_path: pathlib.Path, *, rate: int = 16000, device: str | None = None) -> None:
    "Record via `sox rec` until Ctrl-C; sox finalizes the WAV header on SIGINT."
    cmd = ["rec", "-q"]
    if device: cmd += ["-t", "alsa", device]
    cmd += ["-r", str(rate), "-c", "1", str(out_path)]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:    proc.wait()
    except KeyboardInterrupt: proc.wait()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data-dir", type=pathlib.Path, default=DATA_DIR)
    parser.add_argument("--device", help="ALSA capture device (e.g. hw:1,0); default device if omitted")
    args = parser.parse_args()

    pending = find_pending(args.data_dir)
    if not pending:
        print("Nothing to record — every reference text already has a .wav.")
        return

    print(f"{len(pending)} recording(s) pending.\n")
    for i, txt_path in enumerate(pending, 1):
        category, length, lang = txt_path.parts[-3], txt_path.parts[-2], txt_path.stem
        wav_path = txt_path.with_suffix(".wav")
        text = txt_path.read_text().strip()

        print("\033c", end="")  # clear screen so the text stays put while recording
        print(f"[{i}/{len(pending)}] {category} / {length} / {lang} -> {wav_path.relative_to(REPO)}\n")
        print(text)
        print("\nPress Enter to start recording, then read the text aloud and press Ctrl-C when done.")
        input()

        print("\n● Recording... (Ctrl-C to stop and save)")
        record(wav_path, device=args.device)
        print(f"Saved {wav_path.relative_to(REPO)}")

    print("\nAll recordings done.")


if __name__ == "__main__":
    main()
