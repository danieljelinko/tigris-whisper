"""Render latest benchmark results into README.md between BENCH comment markers.

Reads all benchmark/results/*.json suite files, picks the most recent result per
(backend, language), renders a compact markdown table, and splices it between:
  <!-- BENCH:START -->
  <!-- BENCH:END -->

Idempotent: safe to re-run after every suite run.

Usage:
  uv run python benchmark/readme_snippet.py               # auto-detect README
  uv run python benchmark/readme_snippet.py --readme README.md --results benchmark/results
"""
import argparse, json, pathlib, re, sys
from datetime import datetime

REPO = pathlib.Path(__file__).parent.parent
sys.path.insert(0, str(REPO))

START_MARKER = "<!-- BENCH:START -->"
END_MARKER   = "<!-- BENCH:END -->"


def _load_results(results_dir: pathlib.Path) -> list[dict]:
    rows = []
    for f in sorted(results_dir.glob("*.json")):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
            # suite file has "entries" list
            if "entries" in data:
                for entry in data["entries"]:
                    rows.append({
                        "backend":   data.get("backend", "?"),
                        "model":     data.get("model", "?"),
                        "hardware":  data.get("hardware", {}),
                        "timestamp": data.get("timestamp", ""),
                        **entry,
                    })
            else:
                # single-run file
                rows.append(data)
        except Exception:
            pass
    return rows


def _best_rows(rows: list[dict]) -> list[dict]:
    "Keep the most recent result per (backend, language)."
    best: dict[tuple, dict] = {}
    for r in rows:
        key = (r.get("backend", ""), r.get("language", ""))
        if key not in best or r.get("timestamp", "") > best[key].get("timestamp", ""):
            best[key] = r
    return sorted(best.values(), key=lambda r: (r.get("backend", ""), r.get("language", "")))


def render_table(results_dir: pathlib.Path) -> str:
    rows = _best_rows(_load_results(results_dir))
    if not rows:
        return "_No benchmark results yet. Run `uv run python benchmark/run_suite.py` to generate them._\n"

    lines = [
        "| Backend | Model | Hardware | Language | Latency | RTF | WER | F1 | Words right |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for r in rows:
        hw   = r.get("hardware", {})
        cpu  = hw.get("cpu", "?").split("@")[0].strip()   # truncate freq
        lang = r.get("label", r.get("language", "?"))
        lines.append(
            f"| {r.get('backend','?')} | {r.get('model','?')} | {cpu} "
            f"| {lang} | {r.get('latency_s','?'):.2f}s "
            f"| {r.get('rtf', 0):.3f} | {r.get('wer', 0):.1%} "
            f"| {r.get('f1', 0):.1%} "
            f"| {r.get('words_right','?')}/{r.get('words_total','?')} |"
        )
    ts = datetime.now().strftime("%Y-%m-%d")
    lines += ["", f"_Last updated: {ts}. See [`benchmark/results/`](benchmark/results/) for full reports._"]
    return "\n".join(lines) + "\n"


def update_readme(results_dir: pathlib.Path, readme_path: pathlib.Path) -> None:
    content = readme_path.read_text(encoding="utf-8")
    if START_MARKER not in content or END_MARKER not in content:
        raise ValueError(
            f"README is missing BENCH markers.\n"
            f"Add these between ## Quick install and ## Backends by platform:\n\n"
            f"## Benchmark results\n{START_MARKER}\n{END_MARKER}"
        )
    table = render_table(results_dir)
    new_block = f"{START_MARKER}\n{table}{END_MARKER}"
    updated = re.sub(
        re.escape(START_MARKER) + r".*?" + re.escape(END_MARKER),
        new_block,
        content,
        flags=re.DOTALL,
    )
    readme_path.write_text(updated, encoding="utf-8")


def main() -> None:
    p = argparse.ArgumentParser(description="Update README benchmark table.")
    p.add_argument("--readme",  default=str(REPO / "README.md"))
    p.add_argument("--results", default=str(REPO / "benchmark/results"))
    a = p.parse_args()
    update_readme(pathlib.Path(a.results), pathlib.Path(a.readme))
    print(f"README updated: {a.readme}")


if __name__ == "__main__":
    main()
