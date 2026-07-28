# ASR bake-off

Phase 0 of the cloud migration. Picks a transcription provider on measured
Turkish word error rate instead of on vendor benchmark tables, none of which
publish Turkish numbers.

Runs every OpenRouter transcription model against the same recordings and scores
each one against a reference text you read aloud.

## Run it

```sh
# 1. Check the plumbing before recording anything (uses a synthesized sample).
export OPENROUTER_API_KEY=sk-or-...
python3 bakeoff.py --samples smoke --models whisper-1

# 2. Record the five reference samples.
./record.sh              # lists mic devices
./record.sh 0            # records using device 0

# 3. Score every model.
python3 bakeoff.py
```

Results land in `report.md` (ranked summary plus every transcript side by side)
and `results.json` (raw, for re-scoring without re-spending).

## Reading the report

- **Sort by mean WER, but open `01-mixed-tech` first.** Turkish sentences with
  English technical terms are the case most likely to sink a model, and a good
  average can hide a catastrophic result on exactly the audio you dictate most.
- **`04-numbers` WER is not comparable across models.** The reference spells
  numbers out in words; some models emit digits. Judge that section by eye and
  prefer the output format you actually want when dictating.
- **Latency here is not the latency Murmur will show.** These are cold one-shot
  requests over the full file. In the app, upload overlaps with speaking.

## Scoring notes

WER is `(substitutions + deletions + insertions) / reference words`, so it can
exceed 100% when a model hallucinates. Before comparing, both texts are folded:
Turkish-correct lowercasing (`I` to `ı`, `İ` to `i`), apostrophes deleted rather
than split on (`PR'ı` and `PRı` must not count as two errors), remaining
punctuation replaced with spaces.

## Files

| Path | What |
|---|---|
| `references/*.txt` | Turkish texts to read. Ground truth for scoring. |
| `record.sh` | Records each reference as 16 kHz mono WAV via ffmpeg. |
| `bakeoff.py` | Runs the models, scores, writes the report. Stdlib only. |
| `smoke/` | Synthesized sample for checking the plumbing without recording. |
| `samples/` | Your recordings. Gitignored, they are your voice. |

## Measured result (2026-07-29)

Five recordings of one speaker's voice, Turkish, scored against the reference
texts. The mixed-language sample was reworded afterwards, so re-running produces
close but not identical numbers. `04-numbers` is excluded from the averages because its WER inverts: the
reference spells numbers out while the models emit digits, which is what you
actually want when dictating.

| Model | Raw WER | After cleanup | Mixed TR/EN | Latency | $/audio-hour |
|---|---|---|---|---|---|
| `microsoft/mai-transcribe-1.5` | 6.8% | **4.6%** | 8.8% | 1.54s | $0.360 |
| `google/chirp-3` | 7.6% | **5.5%** | 5.9% | 3.44s | $0.960 |
| `openai/whisper-large-v3` | 12.2% | **9.2%** | 20.6% | 1.26s | $0.090 |
| `deepgram/nova-3` | 13.8% | **9.3%** | 17.6% | 1.91s | $0.258 |
| `openai/whisper-1` | 13.7% | **9.3%** | 17.6% | 1.55s | $0.360 |
| `openai/gpt-4o-mini-transcribe` | 10.7% | **9.3%** | 23.5% | 1.32s | - |
| `openai/whisper-large-v3-turbo` | 14.6% | **10.9%** | 17.6% | 0.67s | $0.040 |
| `qwen/qwen3-asr-flash-2026-02-10` | 16.5% | **14.5%** | 35.3% | 2.04s | $0.126 |
| `x-ai/grok-stt-1.0` | 25.4% | **21.6%** | 52.9% | 4.30s | $0.100 |
| `openai/gpt-4o-transcribe` | 7.7% | **26.0%** | 91.2% | 1.66s | - |
| `nvidia/parakeet-tdt-0.6b-v3` | 98.5% | **98.5%** | 97.1% | 1.05s | $0.090 |
| `mistralai/voxtral-mini-transcribe` | every request failed | | | | |

`microsoft/mai-transcribe-1.5` wins on accuracy, latency and price together, so
dictation and meeting transcription can share one model. A synthesized-speech
round ranked `google/chirp-3` first by a wide margin; real voice reversed it,
which is why the recorded samples matter.

`nvidia/parakeet-tdt-0.6b-v3` has no Turkish at all (its 25 languages do not
include it) and returns gibberish. `mistralai/voxtral-mini-transcribe` returned
HTTP 400 on every request.

The cleanup pass helps on technical vocabulary but is not free: feeding it a term
that shares a stem with an ordinary word makes it rewrite correct text, and one
model had its transcript truncated to four words. Both are guarded against in the
app, not here.
