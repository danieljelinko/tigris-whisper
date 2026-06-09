"""Tests for benchmark/eval.py — pure metric logic, no network."""
import pytest
from benchmark.eval import normalize, score, word_diff, ScoreResult


# ── normalize ─────────────────────────────────────────────────────────────────

def test_normalize_lowercases_and_strips_punctuation():
    # Given text with mixed case and punctuation
    # When normalized
    result = normalize("Hello, World!")
    # Then lowercase tokens, no punctuation
    assert result == ["hello", "world"]


def test_normalize_collapses_whitespace():
    assert normalize("  foo   bar  ") == ["foo", "bar"]


def test_normalize_keeps_accents_by_default():
    # Given accented French text
    result = normalize("café crème")
    assert result == ["café", "crème"]


def test_normalize_folds_accents_when_flag_set():
    result = normalize("café crème", fold_accents=True)
    assert result == ["cafe", "creme"]


def test_normalize_hungarian_accents_preserved_by_default():
    result = normalize("Győr vonat")
    assert result == ["győr", "vonat"]


def test_normalize_hungarian_accents_folded():
    result = normalize("Győr vonat", fold_accents=True)
    assert result == ["gyor", "vonat"]


def test_normalize_empty_string_returns_empty_list():
    assert normalize("") == []


def test_normalize_digits_kept():
    assert normalize("Train 17:45") == ["train", "1745"]


# ── score ─────────────────────────────────────────────────────────────────────

def test_score_perfect_match():
    # Given identical reference and hypothesis
    result = score("hello world", "hello world")
    # Then zero errors, WER=0, F1=1
    assert result.H == 2
    assert result.S == 0
    assert result.D == 0
    assert result.I == 0
    assert result.wer == pytest.approx(0.0)
    assert result.precision == pytest.approx(1.0)
    assert result.recall == pytest.approx(1.0)
    assert result.f1 == pytest.approx(1.0)
    assert result.words_right == 2
    assert result.words_total == 2


def test_score_one_substitution():
    # Given ref "hello world foo", hyp "hello world bar" (1 substitution)
    result = score("hello world foo", "hello world bar")
    assert result.H == 2
    assert result.S == 1
    assert result.D == 0
    assert result.I == 0
    assert result.wer == pytest.approx(1 / 3)
    assert result.recall == pytest.approx(2 / 3)
    assert result.precision == pytest.approx(2 / 3)


def test_score_one_deletion():
    # Given ref "hello world", hyp "hello" (1 deletion)
    result = score("hello world", "hello")
    assert result.H == 1
    assert result.D == 1
    assert result.I == 0
    assert result.recall == pytest.approx(0.5)


def test_score_one_insertion():
    # Given ref "hello", hyp "hello world" (1 insertion)
    result = score("hello", "hello world")
    assert result.H == 1
    assert result.I == 1
    assert result.D == 0
    assert result.precision == pytest.approx(0.5)


def test_score_f1_harmonic_mean():
    # P=1.0, R=0.5 → F1=2/3
    result = score("hello world", "hello")
    assert result.f1 == pytest.approx(2 * 1.0 * 0.5 / (1.0 + 0.5))


def test_score_returns_scoreresult_type():
    assert isinstance(score("a b", "a b"), ScoreResult)


def test_score_accent_preserved_by_default():
    # "café" ≠ "cafe" with default normalization
    result = score("café au lait", "cafe au lait")
    assert result.S == 1  # café ≠ cafe is a substitution


def test_score_accent_folded_treats_as_match():
    result = score("café au lait", "cafe au lait", fold_accents=True)
    assert result.S == 0
    assert result.H == 3


# ── word_diff ──────────────────────────────────────────────────────────────────

def test_word_diff_all_equal():
    # Given perfect match
    result = score("hello world", "hello world")
    chunks = word_diff(result)
    assert all(c["op"] == "equal" for c in chunks)
    assert [c["ref"] for c in chunks] == [["hello"], ["world"]] or \
           [w for c in chunks for w in c["ref"]] == ["hello", "world"]


def test_word_diff_substitution_chunk():
    result = score("hello world foo", "hello world bar")
    chunks = word_diff(result)
    ops = [c["op"] for c in chunks]
    assert "substitute" in ops


def test_word_diff_deletion_chunk():
    result = score("hello world", "hello")
    chunks = word_diff(result)
    ops = [c["op"] for c in chunks]
    assert "delete" in ops


def test_word_diff_insertion_chunk():
    result = score("hello", "hello world")
    chunks = word_diff(result)
    ops = [c["op"] for c in chunks]
    assert "insert" in ops
