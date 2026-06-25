"""Pure ASR evaluation metrics: normalize, WER, precision/recall/F1, word-diff.

No I/O, no network — fully unit-testable.
"""
import re, unicodedata
from dataclasses import dataclass
from typing import Any
import jiwer


@dataclass
class ScoreResult:
    H: int; S: int; D: int; I: int
    wer: float; precision: float; recall: float; f1: float
    words_right: int; words_total: int
    # raw jiwer output, used by word_diff
    _output: Any = None


def normalize(text: str, *, fold_accents: bool = False) -> list[str]:
    "Lowercase, strip punctuation (keep accents unless fold_accents), split."
    text = text.lower()
    if fold_accents:
        text = "".join(c for c in unicodedata.normalize("NFD", text)
                       if unicodedata.category(c) != "Mn")
    text = re.sub(r"[^\w\s]", "", text)   # strip punctuation, keep word chars + spaces
    return text.split()


def score(reference: str, hypothesis: str, *, fold_accents: bool = False) -> ScoreResult:
    "Align ref vs hyp, return WER + precision/recall/F1 + raw alignment."
    ref_norm = " ".join(normalize(reference, fold_accents=fold_accents))
    hyp_norm = " ".join(normalize(hypothesis, fold_accents=fold_accents))
    out = jiwer.process_words(ref_norm, hyp_norm)
    H, S, D, I_ = out.hits, out.substitutions, out.deletions, out.insertions
    N = H + S + D                                    # reference word count
    M = H + S + I_                                   # hypothesis word count
    wer  = (S + D + I_) / N if N else 0.0
    prec = H / M if M else 0.0
    rec  = H / N if N else 0.0
    f1   = 2*prec*rec / (prec+rec) if (prec+rec) else 0.0
    return ScoreResult(H=H, S=S, D=D, I=I_, wer=wer,
                       precision=prec, recall=rec, f1=f1,
                       words_right=H, words_total=N, _output=out)


def word_diff(result: ScoreResult) -> list[dict]:
    "Return alignment chunks [{op, ref, hyp}] from a ScoreResult."
    out  = result._output
    refs = out.references[0]   # list[str] of normalized ref tokens
    hyps = out.hypotheses[0]   # list[str] of normalized hyp tokens
    chunks = []
    for chunk in out.alignments[0]:
        chunks.append({
            "op":  chunk.type,                         # equal / substitute / delete / insert
            "ref": refs[chunk.ref_start_idx:chunk.ref_end_idx],
            "hyp": hyps[chunk.hyp_start_idx:chunk.hyp_end_idx],
        })
    return chunks
