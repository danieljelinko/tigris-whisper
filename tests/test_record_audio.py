"""Tests for benchmark/record_audio.py — pure logic only (no real recording)."""
from pathlib import Path

from benchmark.record_audio import find_pending


def test_find_pending_lists_txt_files_without_matching_wav(tmp_path: Path):
    # Given a data dir with one text that has a wav and one that doesn't
    done = tmp_path / "general" / "short"
    done.mkdir(parents=True)
    (done / "en.txt").write_text("hello")
    (done / "en.wav").write_bytes(b"")

    pending = tmp_path / "software" / "short"
    pending.mkdir(parents=True)
    (pending / "fr.txt").write_text("bonjour")

    # When we look for pending recordings
    result = find_pending(tmp_path)

    # Then only the text without a wav is returned
    assert result == [pending / "fr.txt"]


def test_find_pending_returns_empty_when_all_have_wavs(tmp_path: Path):
    # Given a data dir where every text already has a matching wav
    done = tmp_path / "general" / "short"
    done.mkdir(parents=True)
    (done / "en.txt").write_text("hello")
    (done / "en.wav").write_bytes(b"")

    # When we look for pending recordings
    result = find_pending(tmp_path)

    # Then nothing is pending
    assert result == []


def test_find_pending_sorted_for_deterministic_order(tmp_path: Path):
    # Given two pending texts in different categories
    a = tmp_path / "software" / "short"
    a.mkdir(parents=True)
    (a / "hu.txt").write_text("szia")

    b = tmp_path / "general" / "long"
    b.mkdir(parents=True)
    (b / "en.txt").write_text("hello")

    # When we look for pending recordings
    result = find_pending(tmp_path)

    # Then results are sorted by path
    assert result == sorted(result)
