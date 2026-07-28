#!/usr/bin/env python3
"""Compare every OpenRouter transcription model on the same Turkish audio.

Phase 0 of the Murmur cloud migration: pick an ASR provider on measured word
error rate rather than on vendor benchmark tables, which do not cover Turkish.

Usage:
    export OPENROUTER_API_KEY=sk-or-...
    python3 bakeoff.py                       run every model on every sample
    python3 bakeoff.py --language auto       let the model detect the language
    python3 bakeoff.py --models qwen,whisper substring filter on model id

Writes report.md (human comparison) and results.json (raw, for re-scoring)
next to this script. Standard library only, no pip install needed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import sys
import time
import unicodedata
import wave
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
REF_DIR = HERE / "references"
VOCAB_FILE = HERE / "vocabulary.txt"

MODELS_URL = "https://openrouter.ai/api/v1/models?output_modalities=transcription"
TRANSCRIBE_URL = "https://openrouter.ai/api/v1/audio/transcriptions"
KEY_URL = "https://openrouter.ai/api/v1/key"
CHAT_URL = "https://openrouter.ai/api/v1/chat/completions"

REQUEST_TIMEOUT = 180  # long enough for a cold model on a slow provider
MAX_PARALLEL = 4  # keep well under any per-key rate limit


# ---------------------------------------------------------------- text scoring


APOSTROPHES = "'’‘ʼ´`"


def tr_fold(text: str) -> str:
    """Lowercase Turkish correctly, then strip everything that is not a letter,
    digit or space. Python's str.lower maps I to i and leaves a combining dot on
    İ, both wrong for Turkish, so those two are rewritten first.

    Apostrophes are deleted rather than replaced with a space. Turkish attaches
    suffixes to proper nouns with one ("PR'ı", "TestFlight'a") and models emit it
    inconsistently. Splitting on it would score a pure formatting difference as
    two word errors, which is not what we are trying to measure here."""
    text = text.replace("I", "ı").replace("İ", "i").lower()
    text = unicodedata.normalize("NFC", text)
    text = text.translate({ord(mark): None for mark in APOSTROPHES})
    text = re.sub(r"[^\w\s]", " ", text, flags=re.UNICODE)
    return re.sub(r"\s+", " ", text).strip()


def word_error_rate(reference: str, hypothesis: str) -> float:
    """Standard WER: (substitutions + deletions + insertions) / reference words.
    Can exceed 1.0 when the model hallucinates more words than were spoken."""
    ref = tr_fold(reference).split()
    hyp = tr_fold(hypothesis).split()
    if not ref:
        return 0.0 if not hyp else 1.0

    # Levenshtein over words, single row rolling to keep it O(len(hyp)) memory.
    previous = list(range(len(hyp) + 1))
    for i, ref_word in enumerate(ref, start=1):
        current = [i]
        for j, hyp_word in enumerate(hyp, start=1):
            cost = 0 if ref_word == hyp_word else 1
            current.append(
                min(
                    previous[j] + 1,  # deletion
                    current[j - 1] + 1,  # insertion
                    previous[j - 1] + cost,  # substitution
                )
            )
        previous = current
    return previous[-1] / len(ref)


# ---------------------------------------------------------------- http helpers


def make_ssl_context() -> ssl.SSLContext:
    """python.org Python ships its own OpenSSL with no root certificates wired up,
    so every HTTPS call fails with CERTIFICATE_VERIFY_FAILED until someone runs
    "Install Certificates.command". Fall back to certifi's bundle when the default
    context comes up empty, so this script works on a stock install without
    modifying the Python framework."""
    context = ssl.create_default_context()
    if context.cert_store_stats()["x509_ca"] == 0:
        try:
            import certifi

            context.load_verify_locations(certifi.where())
        except ImportError:
            print(
                "warning: no root certificates found. Run "
                '"/Applications/Python 3.x/Install Certificates.command" or pip install certifi.',
                file=sys.stderr,
            )
    return context


SSL_CONTEXT = make_ssl_context()


def build_multipart(fields: dict[str, str], filename: str, audio: bytes) -> tuple[bytes, str]:
    boundary = "----murmurbakeoff7f3a9c2e"
    body = bytearray()
    for key, value in fields.items():
        body += f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode()
    body += (
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; '
        f'filename="{filename}"\r\nContent-Type: audio/wav\r\n\r\n'
    ).encode()
    body += audio
    body += f"\r\n--{boundary}--\r\n".encode()
    return bytes(body), f"multipart/form-data; boundary={boundary}"


def wav_duration_minutes(path: Path) -> float:
    """Duration straight from the RIFF header, so the cost summary does not need
    an audio library. Returns 0.0 for anything that is not a readable PCM wav."""
    try:
        with wave.open(str(path), "rb") as handle:
            return handle.getnframes() / handle.getframerate() / 60.0
    except Exception:
        return 0.0


def fetch_models(api_key: str) -> list[str]:
    request = urllib.request.Request(MODELS_URL, headers={"Authorization": f"Bearer {api_key}"})
    with urllib.request.urlopen(request, timeout=30, context=SSL_CONTEXT) as response:
        payload = json.load(response)
    return [entry["id"] for entry in payload.get("data", [])]


def fetch_usage(api_key: str) -> float | None:
    """Dollars spent on this key so far. OpenRouter reports transcription prices in
    whatever unit the upstream provider publishes (per minute for OpenAI and
    Deepgram, per hour for Groq) and does not normalize them, so the model
    metadata cannot be turned into a monthly estimate. Reading this before and
    after a run is the only reliable way to learn what the audio actually costs."""
    request = urllib.request.Request(KEY_URL, headers={"Authorization": f"Bearer {api_key}"})
    try:
        with urllib.request.urlopen(request, timeout=30, context=SSL_CONTEXT) as response:
            return float(json.load(response)["data"]["usage"])
    except Exception:
        return None


CLEANUP_INSTRUCTIONS = """You repair Turkish speech-to-text output. You are a
proofreader, not an editor.

The ASR model does not know these proper nouns and technical terms, so when they
were spoken it wrote down something that merely sounds like them:

{vocabulary}

Restore a term from that list ONLY when the transcript contains a garbled word in
that exact position that plausibly sounds like it. "Sentri" -> "Sentry" and
"test flight" -> "TestFlight" are correct repairs.

NEVER insert a term from the list into a position where the transcript already
reads as ordinary, sensible Turkish. If the speaker said "sonra diğerine geçeriz",
that is the final text. Replacing it with a product name is a serious error, worse
than leaving a real mistake unfixed. Most transcripts need zero or one repairs.

Beyond those terms, change nothing:
- keep every filler word, repetition and self-correction exactly as spoken
- keep the wording, word order and sentence structure
- do not summarize, rephrase, translate, shorten or add anything

If the transcript already reads as a correct, sensible phrase, leave it alone even
when a list entry looks similar to it. "App Store review" is not "App Store Connect".

Output plain text only. No markdown, no bold, no quotes, no commentary.
If nothing is clearly misheard, reply with the transcript unchanged.
Reply with the transcript and nothing else."""


def load_vocabulary() -> str:
    if not VOCAB_FILE.exists():
        return ""
    lines = [line.strip() for line in VOCAB_FILE.read_text(encoding="utf-8").splitlines()]
    return ", ".join(line for line in lines if line and not line.startswith("#"))


def cleanup_text(api_key: str, model: str, text: str, vocabulary: str) -> dict:
    """Second pass: an LLM repairs ASR errors using the domain vocabulary. This is
    the pipeline Murmur will actually run, so its output is the number that decides
    the provider, not the raw transcript."""
    body = json.dumps(
        {
            "model": model,
            "messages": [
                {"role": "system", "content": CLEANUP_INSTRUCTIONS.format(vocabulary=vocabulary)},
                {"role": "user", "content": text},
            ],
            "temperature": 0,
        }
    ).encode()

    request = urllib.request.Request(
        CHAT_URL,
        data=body,
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        method="POST",
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT, context=SSL_CONTEXT) as response:
            payload = json.load(response)
        content = payload["choices"][0]["message"]["content"].strip()
        return {"text": content, "latency": time.monotonic() - started}
    except Exception as error:
        return {"error": f"{type(error).__name__}: {error}", "latency": time.monotonic() - started}


def transcribe(api_key: str, model: str, wav: Path, language: str | None) -> dict:
    fields = {"model": model}
    if language:
        fields["language"] = language
    body, content_type = build_multipart(fields, wav.name, wav.read_bytes())

    request = urllib.request.Request(
        TRANSCRIBE_URL,
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": content_type,
            # Optional OpenRouter attribution headers, not needed for auth.
            "HTTP-Referer": "https://github.com/umutozturkkk/nozomi-flow",
            "X-Title": "Nozomi Flow ASR bake-off",
        },
        method="POST",
    )

    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT, context=SSL_CONTEXT) as response:
            payload = json.load(response)
        elapsed = time.monotonic() - started
        return {"text": payload.get("text", ""), "latency": elapsed, "usage": payload.get("usage")}
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:300]
        return {"error": f"HTTP {error.code}: {detail}", "latency": time.monotonic() - started}
    except Exception as error:  # network, timeout, malformed body
        return {"error": f"{type(error).__name__}: {error}", "latency": time.monotonic() - started}


# ---------------------------------------------------------------------- report


def write_report(results: dict, samples: list[Path], models: list[str], language: str | None, cleanup_model: str = "") -> str:
    lines: list[str] = []
    lines.append("# ASR bake-off: OpenRouter transcription models on Turkish audio")
    lines.append("")
    lines.append(f"Language parameter: `{language or 'auto-detect'}`")
    lines.append(f"Samples: {len(samples)} | Models: {len(models)}")
    if cleanup_model:
        lines.append(f"Cleanup pass: `{cleanup_model}` with the vocabulary in `vocabulary.txt`")
    lines.append("")

    # Summary, ranked by mean WER across the samples the model actually returned.
    lines.append("## Summary")
    lines.append("")
    if cleanup_model:
        lines.append("| Model | Raw WER | After cleanup | Change | Mean latency | Failures |")
        lines.append("|---|---|---|---|---|---|")
    else:
        lines.append("| Model | Mean WER | Mean latency | Failures |")
        lines.append("|---|---|---|---|")

    summary = []
    for model in models:
        scored = [r for r in results[model].values() if "wer" in r]
        failed = [r for r in results[model].values() if "error" in r]
        if scored:
            mean_wer = sum(r["wer"] for r in scored) / len(scored)
            mean_latency = sum(r["latency"] for r in scored) / len(scored)
        else:
            mean_wer, mean_latency = float("inf"), float("inf")
        cleaned = [r for r in results[model].values() if "clean_wer" in r]
        mean_clean = sum(r["clean_wer"] for r in cleaned) / len(cleaned) if cleaned else float("inf")
        # Rank on whichever number will decide the provider: the cleaned one when
        # a cleanup pass ran, since that is what the app actually inserts.
        rank = mean_clean if (cleanup_model and cleaned) else mean_wer
        summary.append((rank, mean_wer, mean_clean, mean_latency, model, len(failed)))

    for rank, mean_wer, mean_clean, mean_latency, model, failures in sorted(summary):
        wer_text = "n/a" if mean_wer == float("inf") else f"{mean_wer * 100:.1f}%"
        latency_text = "n/a" if mean_latency == float("inf") else f"{mean_latency:.2f}s"
        if cleanup_model:
            clean_text = "n/a" if mean_clean == float("inf") else f"{mean_clean * 100:.1f}%"
            if mean_clean == float("inf") or mean_wer == float("inf"):
                delta_text = "n/a"
            else:
                delta_text = f"{(mean_clean - mean_wer) * 100:+.1f}"
            lines.append(
                f"| `{model}` | {wer_text} | **{clean_text}** | {delta_text} | {latency_text} | {failures} |"
            )
        else:
            lines.append(f"| `{model}` | {wer_text} | {latency_text} | {failures} |")

    lines.append("")
    lines.append(
        "> WER on the numbers sample is not directly comparable: the reference spells "
        "numbers out in words while some models emit digits. Read that section by eye "
        "and prefer the model whose format you actually want when dictating."
    )
    lines.append("")

    # Per-sample detail, so a low average cannot hide one catastrophic case.
    for sample in samples:
        reference = (REF_DIR / f"{sample.stem}.txt").read_text(encoding="utf-8").strip()
        lines.append(f"## {sample.stem}")
        lines.append("")
        lines.append("**Reference**")
        lines.append("")
        lines.append(f"> {reference}")
        lines.append("")

        rows = []
        for model in models:
            result = results[model].get(sample.stem, {})
            if "error" in result:
                rows.append((float("inf"), model, f"_{result['error']}_"))
            else:
                rows.append((result.get("wer", float("inf")), model, result.get("text", "")))

        for wer, model, text in sorted(rows):
            wer_text = "n/a" if wer == float("inf") else f"{wer * 100:.1f}%"
            lines.append(f"**`{model}`** ({wer_text})")
            lines.append("")
            lines.append(f"> {text}")
            lines.append("")
            detail = results[model].get(sample.stem, {})
            if "clean_wer" in detail:
                lines.append(f"after cleanup ({detail['clean_wer'] * 100:.1f}%)")
                lines.append("")
                lines.append(f"> {detail['clean_text']}")
                lines.append("")

    return "\n".join(lines)


# ------------------------------------------------------------------------ main


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--language", default="tr", help="ISO-639-1 code, or 'auto' to omit (default: tr)")
    parser.add_argument("--models", default="", help="comma-separated substrings to filter model ids")
    parser.add_argument(
        "--cleanup",
        default="",
        help="chat model to run a vocabulary-aware repair pass over each transcript, "
        "e.g. google/gemini-2.5-flash-lite. Off by default.",
    )
    parser.add_argument(
        "--samples",
        default="samples",
        help="directory of wav files, relative to this script (default: samples). "
        "Use 'smoke' for the synthesized plumbing check.",
    )
    args = parser.parse_args()

    api_key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not api_key:
        print("OPENROUTER_API_KEY is not set. Get a key at https://openrouter.ai/keys", file=sys.stderr)
        return 1

    sample_dir = HERE / args.samples
    samples = sorted(sample_dir.glob("*.wav"))
    if not samples:
        print(f"No samples in {sample_dir}. Run ./record.sh first.", file=sys.stderr)
        return 1

    missing = [s.stem for s in samples if not (REF_DIR / f"{s.stem}.txt").exists()]
    if missing:
        print(f"No reference text for: {', '.join(missing)}", file=sys.stderr)
        return 1

    models = fetch_models(api_key)
    if args.models:
        needles = [n.strip() for n in args.models.split(",") if n.strip()]
        models = [m for m in models if any(n in m for n in needles)]
    if not models:
        print("No models matched the filter.", file=sys.stderr)
        return 1

    language = None if args.language == "auto" else args.language

    vocabulary = load_vocabulary()
    if args.cleanup:
        print(f"Cleanup pass: {args.cleanup}  ({len(vocabulary.split(', '))} vocabulary terms)")

    jobs = [(model, sample) for model in models for sample in samples]
    print(f"{len(models)} models x {len(samples)} samples = {len(jobs)} requests")
    spent_before = fetch_usage(api_key)
    print()

    results: dict[str, dict[str, dict]] = {model: {} for model in models}

    def run(job: tuple[str, Path]) -> tuple[str, str, dict]:
        model, sample = job
        outcome = transcribe(api_key, model, sample, language)
        if "text" in outcome:
            reference = (REF_DIR / f"{sample.stem}.txt").read_text(encoding="utf-8")
            outcome["wer"] = word_error_rate(reference, outcome["text"])
            if args.cleanup:
                repaired = cleanup_text(api_key, args.cleanup, outcome["text"], vocabulary)
                if "text" in repaired:
                    outcome["clean_text"] = repaired["text"]
                    outcome["clean_wer"] = word_error_rate(reference, repaired["text"])
                    outcome["clean_latency"] = repaired["latency"]
                else:
                    outcome["clean_error"] = repaired["error"]
        return model, sample.stem, outcome

    with ThreadPoolExecutor(max_workers=MAX_PARALLEL) as pool:
        for done, (model, stem, outcome) in enumerate(pool.map(run, jobs), start=1):
            results[model][stem] = outcome
            if "error" in outcome:
                status = f"FAIL  {outcome['error'][:60]}"
            else:
                status = f"WER {outcome['wer'] * 100:5.1f}%  {outcome['latency']:5.2f}s"
                if "clean_wer" in outcome:
                    delta = (outcome["clean_wer"] - outcome["wer"]) * 100
                    status += f"  ->  {outcome['clean_wer'] * 100:5.1f}% ({delta:+.1f})"
            print(f"[{done:>3}/{len(jobs)}] {model:<40} {stem:<14} {status}")

    (HERE / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    report = write_report(results, samples, models, language, args.cleanup)
    (HERE / "report.md").write_text(report, encoding="utf-8")

    print()
    spent_after = fetch_usage(api_key)
    if spent_before is not None and spent_after is not None:
        spent = spent_after - spent_before
        audio_minutes = sum(wav_duration_minutes(s) for s in samples)
        print(f"Actual spend: ${spent:.4f} for {len(models)} models x {audio_minutes:.2f} min of audio")
        if audio_minutes > 0:
            print(f"Per model per audio-minute: ${spent / max(len(models), 1) / audio_minutes:.4f}")
    print(f"Wrote {HERE / 'report.md'} and {HERE / 'results.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
