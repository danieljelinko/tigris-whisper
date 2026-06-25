"""Tests for benchmark/run_suite.py — pure logic only (mock the HTTP boundary)."""
from benchmark.run_suite import _run_one, _aggregate_md

HW = {"os": "Linux", "os_ver": "6.17", "cpu": "Test CPU", "hostname": "testhost", "python": "3.12", "has_nvidia": False}


def _entry(**overrides):
    base = {
        "category": "general", "length": "short", "language": "en",
        "audio": "tests/fixtures/sample_speech.wav",
        "reference": "tests/fixtures/sample_speech.txt",
        "label": "English",
    }
    base.update(overrides)
    return base


def test_run_one_includes_category_and_length(tmp_path, monkeypatch):
    # Given a manifest entry with category/length and a reference file on disk
    ref_path = tmp_path / "ref.txt"
    ref_path.write_text("hello world")
    audio_path = tmp_path / "audio.wav"
    audio_path.write_bytes(b"")
    entry = _entry(category="software", length="long", reference=str(ref_path), audio=str(audio_path))

    import benchmark.run_suite as run_suite
    monkeypatch.setattr(run_suite, "transcribe", lambda *a, **kw: ("hello world", 1.0))
    monkeypatch.setattr(run_suite, "audio_duration_s", lambda *a, **kw: 2.0)
    monkeypatch.setattr(run_suite.pathlib.Path, "exists", lambda self: True)

    # When we run one benchmark entry
    result = _run_one(entry, "http://x", fold_accents=False)

    # Then category and length are carried through into the result
    assert result["category"] == "software"
    assert result["length"] == "long"


def _row(category: str, length: str, label: str) -> dict:
    return {
        "category": category, "length": length, "label": label,
        "audio_dur_s": 1.0, "latency_s": 0.5, "rtf": 0.5,
        "wer": 0.1, "precision": 0.9, "recall": 0.9, "f1": 0.9,
        "words_right": 9, "words_total": 10,
    }


def test_aggregate_md_groups_rows_by_category_and_length():
    # Given rows from two different category/length groups
    rows = [_row("general", "short", "English"), _row("software", "long", "French")]

    # When we render the aggregate markdown
    md = _aggregate_md("faster_whisper", "small", HW, rows, detailed=False)

    # Then each group gets its own labeled section, in row order
    assert "## General — Short" in md
    assert "## Software — Long" in md
    assert md.index("General — Short") < md.index("Software — Long")


def test_aggregate_md_keeps_rows_of_same_group_in_one_table():
    # Given two rows belonging to the same category/length group
    rows = [_row("general", "short", "English"), _row("general", "short", "French")]

    # When we render the aggregate markdown
    md = _aggregate_md("faster_whisper", "small", HW, rows, detailed=False)

    # Then there is only one section header for the shared group
    assert md.count("## General — Short") == 1
    assert "English" in md and "French" in md
