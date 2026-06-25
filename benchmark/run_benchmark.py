#!/usr/bin/env python3
"""Base benchmark CLI: transcribe one audio file, score against reference, write report.

Usage examples:
  # Target a running server
  uv run python benchmark/run_benchmark.py \\
      --audio benchmark/data/audio/en.wav \\
      --reference benchmark/data/refs/en.txt \\
      --language en \\
      --endpoint http://localhost:4444/v1/audio/transcriptions

  # Auto-launch faster_whisper locally
  uv run python benchmark/run_benchmark.py \\
      --audio tests/fixtures/sample_speech.wav \\
      --reference /dev/stdin \\           # or a text file
      --language en \\
      --auto-launch faster_whisper \\
      --detailed
"""
import argparse, json, pathlib, sys
from datetime import datetime

REPO = pathlib.Path(__file__).parent.parent
sys.path.insert(0, str(REPO))

from benchmark.eval             import score, word_diff
from benchmark.transcribe_client import transcribe, probe_model, audio_duration_s
from benchmark.hardware          import collect as hw_collect


def _word_diff_md(reference: str, hypothesis: str, result) -> str:
    "Render word-diff as a Markdown annotated diff block."
    chunks = word_diff(result)
    lines = ["## Word-level diff", "", "| # | Op | Reference | Hypothesis |",
             "|---|---|---|---|"]
    i = 1
    for c in chunks:
        ref_str = " ".join(c["ref"]) or "—"
        hyp_str = " ".join(c["hyp"]) or "—"
        op = c["op"]
        marker = {"equal": "✓", "substitute": "⚠", "delete": "✗", "insert": "+"}.get(op, op)
        lines.append(f"| {i} | {marker} {op} | {ref_str} | {hyp_str} |")
        i += 1
    lines += ["", f"**Reference:** {reference}", "", f"**Hypothesis:** {hypothesis}"]
    return "\n".join(lines)


def run(args: argparse.Namespace) -> dict:
    audio    = pathlib.Path(args.audio)
    ref_text = pathlib.Path(args.reference).read_text(encoding="utf-8").strip()
    lang     = args.language
    out_dir  = pathlib.Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    # ── resolve endpoint (auto-launch or explicit) ────────────────────────────
    ctx = None
    if args.auto_launch:
        from benchmark.backend_launch import launched_backend
        ctx = launched_backend(args.auto_launch, model=args.model or None)
        base_url = ctx.__enter__()
        endpoint = base_url + "/v1/audio/transcriptions"
    else:
        endpoint = args.endpoint
        base_url = endpoint.rsplit("/v1", 1)[0]

    try:
        # ── probe model ───────────────────────────────────────────────────────
        try:   model_id = probe_model(base_url)
        except Exception: model_id = args.model or "unknown"

        # ── transcribe ────────────────────────────────────────────────────────
        print(f"Transcribing {audio.name} ({lang}) via {endpoint} …", flush=True)
        text, latency = transcribe(endpoint, audio, lang)
        dur = audio_duration_s(audio)
        rtf = latency / dur if dur else 0.0

        # ── score ─────────────────────────────────────────────────────────────
        result = score(ref_text, text, fold_accents=args.fold_accents)

        # ── hardware ──────────────────────────────────────────────────────────
        hw = hw_collect()

        record = {
            "timestamp": datetime.now().strftime("%Y-%m-%dT%H:%M"),
            "backend":   args.auto_launch or "external",
            "model":     model_id,
            "language":  lang,
            "audio":     str(audio),
            "hardware":  hw,
            "audio_dur_s": round(dur, 3),
            "latency_s":   round(latency, 3),
            "rtf":         round(rtf, 3),
            "H": result.H, "S": result.S, "D": result.D, "I": result.I,
            "wer":       round(result.wer, 4),
            "precision": round(result.precision, 4),
            "recall":    round(result.recall, 4),
            "f1":        round(result.f1, 4),
            "words_right": result.words_right,
            "words_total": result.words_total,
            "reference": ref_text,
            "hypothesis": text,
        }

        # ── write JSON ────────────────────────────────────────────────────────
        ts   = datetime.now().strftime("%y%m%d_%H%M")
        host = hw["hostname"].split(".")[0]
        bk   = record["backend"].replace("/", "-")
        stem = f"{ts}__bench_{bk}_{lang}_{host}"
        json_path = out_dir / f"{stem}.json"
        json_path.write_text(json.dumps(record, indent=2, ensure_ascii=False),
                             encoding="utf-8")

        # ── optional detailed markdown ────────────────────────────────────────
        if args.detailed:
            md_path = out_dir / f"{stem}.md"
            md_path.write_text(
                f"# Benchmark: {bk} / {lang} / {host}\n\n"
                f"| Field | Value |\n|---|---|\n"
                + "\n".join(
                    f"| {k} | {v} |" for k, v in {
                        "Backend": record["backend"], "Model": model_id,
                        "Language": lang, "Hardware": hw["cpu"],
                        "Audio duration": f"{dur:.2f}s",
                        "Latency": f"{latency:.2f}s", "RTF": f"{rtf:.3f}",
                        "WER": f"{result.wer:.1%}", "Precision": f"{result.precision:.1%}",
                        "Recall": f"{result.recall:.1%}", "F1": f"{result.f1:.1%}",
                        "Words right": f"{result.words_right}/{result.words_total}",
                    }.items()
                )
                + "\n\n" + _word_diff_md(ref_text, text, result) + "\n",
                encoding="utf-8",
            )
            print(f"Detailed report: {md_path}")

        # ── one-line summary ──────────────────────────────────────────────────
        print(f"[{lang}] latency={latency:.2f}s  RTF={rtf:.3f}  "
              f"WER={result.wer:.1%}  F1={result.f1:.1%}  "
              f"({result.words_right}/{result.words_total} words right)")
        print(f"JSON: {json_path}")

        return record

    finally:
        if ctx is not None:
            ctx.__exit__(None, None, None)


def main() -> None:
    p = argparse.ArgumentParser(description="Benchmark one audio file against one reference.")
    p.add_argument("--audio",       required=True,  help="WAV file to transcribe")
    p.add_argument("--reference",   required=True,  help="Ground-truth text file")
    p.add_argument("--language",    required=True,  help="Whisper language code, e.g. en, fr, hu")
    p.add_argument("--endpoint",    default="http://localhost:4444/v1/audio/transcriptions",
                   help="Running transcription endpoint URL")
    p.add_argument("--auto-launch", metavar="BACKEND",
                   help="Auto-start this backend (faster_whisper / whispercpp_cpu / …)")
    p.add_argument("--model",       help="Model id to pass to auto-launched backend")
    p.add_argument("--detailed",    action="store_true", help="Write word-diff markdown")
    p.add_argument("--out",         default="benchmark/results", help="Output directory")
    p.add_argument("--fold-accents", action="store_true",
                   help="Fold accents during scoring (é→e, ő→o, …)")
    run(p.parse_args())


if __name__ == "__main__":
    main()
