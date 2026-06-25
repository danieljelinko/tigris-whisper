#!/usr/bin/env python3
"""Suite orchestrator: run benchmark across all manifest entries × chosen backends.

Usage:
  # Auto-launch both backends, all manifest languages, write detailed reports + update README
  uv run python benchmark/run_suite.py \\
      --backends faster_whisper,whispercpp_cpu \\
      --detailed --update-readme

  # Target a running server for one backend
  uv run python benchmark/run_suite.py \\
      --endpoint http://localhost:4444 \\
      --backends external \\
      --detailed
"""
import argparse, json, pathlib, sys, traceback
from datetime import datetime

REPO = pathlib.Path(__file__).parent.parent
sys.path.insert(0, str(REPO))

import tomllib
from benchmark.eval              import score, word_diff
from benchmark.transcribe_client import transcribe, probe_model, audio_duration_s
from benchmark.hardware          import collect as hw_collect


def _load_manifest(path: pathlib.Path) -> list[dict]:
    return tomllib.loads(path.read_text(encoding="utf-8")).get("entry", [])


def _run_one(entry: dict, endpoint: str, fold_accents: bool) -> dict | None:
    audio = REPO / entry["audio"]
    ref   = pathlib.Path(REPO / entry["reference"]).read_text(encoding="utf-8").strip()
    lang  = entry["language"]
    if not audio.exists():
        print(f"  SKIP {lang}: audio not found at {audio}")
        return None
    print(f"  {entry.get('label', lang)}: transcribing …", end=" ", flush=True)
    try:
        text, latency = transcribe(endpoint + "/v1/audio/transcriptions", audio, lang)
        dur = audio_duration_s(audio)
        rtf = latency / dur if dur else 0.0
        r   = score(ref, text, fold_accents=fold_accents)
        print(f"latency={latency:.2f}s  WER={r.wer:.1%}  F1={r.f1:.1%}")
        return {
            "category": entry.get("category", ""), "length": entry.get("length", ""),
            "language": lang, "label": entry.get("label", lang),
            "audio_dur_s": round(dur, 3), "latency_s": round(latency, 3),
            "rtf": round(rtf, 3),
            "H": r.H, "S": r.S, "D": r.D, "I": r.I,
            "wer": round(r.wer, 4), "precision": round(r.precision, 4),
            "recall": round(r.recall, 4), "f1": round(r.f1, 4),
            "words_right": r.words_right, "words_total": r.words_total,
            "reference": ref, "hypothesis": text,
            "_result": r,     # kept for word_diff; stripped before JSON serialisation
        }
    except Exception as e:
        print(f"ERROR: {e}")
        traceback.print_exc()
        return None


def _aggregate_md(backend: str, model_id: str, hw: dict,
                  rows: list[dict], detailed: bool) -> str:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M")
    hw_str = f"{hw['cpu']} ({hw['os']} {hw['os_ver']})"
    lines = [
        f"# Benchmark results — {backend}",
        "",
        f"**Date:** {ts}  |  **Backend:** {backend}  |  **Model:** {model_id}",
        f"**Hardware:** {hw_str}",
        "",
    ]

    # group by (category, length) preserving manifest order
    groups: dict[tuple, list[dict]] = {}
    for r in rows:
        if r is None: continue
        key = (r.get("category", ""), r.get("length", ""))
        groups.setdefault(key, []).append(r)

    TABLE_HDR = [
        "| Language | Audio dur | Latency | RTF | WER | Precision | Recall | F1 | Words right |",
        "|---|---|---|---|---|---|---|---|---|",
    ]

    def _row_line(r: dict) -> str:
        return (f"| {r['label']} | {r['audio_dur_s']:.1f}s | {r['latency_s']:.2f}s | "
                f"{r['rtf']:.3f} | {r['wer']:.1%} | {r['precision']:.1%} | "
                f"{r['recall']:.1%} | {r['f1']:.1%} | {r['words_right']}/{r['words_total']} |")

    for (category, length), group_rows in groups.items():
        section = " — ".join(p.capitalize() for p in [category, length] if p)
        if section: lines += [f"## {section}", ""]
        lines += TABLE_HDR
        lines += [_row_line(r) for r in group_rows]
        lines.append("")

    if detailed:
        lines += ["---", ""]
        for r in rows:
            if r is None: continue
            cat_len = f"{r.get('category','')} / {r.get('length','')} / " if r.get("category") else ""
            chunks = word_diff(r["_result"])
            lines += [
                f"## {cat_len}{r['label']} — word diff",
                "",
                "| Op | Reference | Hypothesis |",
                "|---|---|---|",
            ]
            for c in chunks:
                op = c["op"]
                marker = {"equal": "✓", "substitute": "⚠", "delete": "✗", "insert": "+"}.get(op, op)
                lines.append(
                    f"| {marker} {op} | {' '.join(c['ref']) or '—'} "
                    f"| {' '.join(c['hyp']) or '—'} |"
                )
            lines += ["", f"**Reference:** {r['reference']}", "",
                      f"**Hypothesis:** {r['hypothesis']}", ""]
    return "\n".join(lines) + "\n"


def _strip_internal(rows: list[dict]) -> list[dict]:
    return [{k: v for k, v in r.items() if not k.startswith("_")}
            for r in rows if r is not None]


def run_suite(args: argparse.Namespace) -> None:
    manifest_path = pathlib.Path(args.manifest)
    entries  = _load_manifest(manifest_path)
    out_dir  = pathlib.Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    hw       = hw_collect()
    ts       = datetime.now().strftime("%y%m%d_%H%M")
    host     = hw["hostname"].split(".")[0]

    backends = [b.strip() for b in args.backends.split(",")] if args.backends else ["external"]

    all_results = []

    for backend in backends:
        print(f"\n=== Backend: {backend} ===")
        ctx = None
        if backend != "external":
            from benchmark.backend_launch import launched_backend
            ctx = launched_backend(backend, model=args.model or None)
            base_url = ctx.__enter__()
        else:
            base_url = args.endpoint.rstrip("/")

        try:
            try:   model_id = probe_model(base_url)
            except Exception: model_id = args.model or "unknown"
            print(f"  Model: {model_id}")

            rows = [_run_one(e, base_url, args.fold_accents) for e in entries]
            rows_clean = [r for r in rows if r is not None]

            bk   = backend.replace("/", "-")
            stem = f"{ts}__bench_{bk}_{host}"

            # JSON
            suite_record = {
                "timestamp": datetime.now().strftime("%Y-%m-%dT%H:%M"),
                "backend": backend, "model": model_id, "hardware": hw,
                "entries": _strip_internal(rows),
            }
            json_path = out_dir / f"{stem}.json"
            json_path.write_text(json.dumps(suite_record, indent=2, ensure_ascii=False),
                                 encoding="utf-8")
            print(f"  JSON: {json_path}")

            # Markdown
            md = _aggregate_md(backend, model_id, hw, rows_clean, args.detailed)
            md_path = out_dir / f"{stem}.md"
            md_path.write_text(md, encoding="utf-8")
            print(f"  Report: {md_path}")

            all_results.append(suite_record)

        finally:
            if ctx is not None:
                ctx.__exit__(None, None, None)

    if args.update_readme:
        from benchmark.readme_snippet import update_readme
        update_readme(out_dir, REPO / "README.md")
        print("\nREADME updated with latest benchmark results.")


def main() -> None:
    p = argparse.ArgumentParser(description="Run benchmark suite across manifest × backends.")
    p.add_argument("--manifest",  default="benchmark/manifest.toml")
    p.add_argument("--backends",  default="faster_whisper",
                   help="Comma-separated backend ids, or 'external'")
    p.add_argument("--endpoint",  default="http://localhost:4444",
                   help="Base URL for external backend (no path)")
    p.add_argument("--model",     help="Model to pass to auto-launched backends")
    p.add_argument("--detailed",  action="store_true", help="Include word-diff in reports")
    p.add_argument("--out",       default="benchmark/results")
    p.add_argument("--fold-accents", action="store_true")
    p.add_argument("--update-readme", action="store_true",
                   help="Splice latest results table into README.md")
    run_suite(p.parse_args())


if __name__ == "__main__":
    main()
