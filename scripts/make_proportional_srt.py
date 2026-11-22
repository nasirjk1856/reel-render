#!/usr/bin/env python3
"""Build a proportionally timed SRT: split the voiceover's length across
its sentences by word count.

Usage:
    python3 make_proportional_srt.py --text "voiceover script" \
        --captions "English line 1\nEnglish line 2" \
        --duration 19.2 --out timed.srt

Used for Gemini TTS voiceovers, which return no word timings — so the
exact word-sync of make_timed_srt.py is impossible. This is the next best
thing: each caption covers its sentence's share of the spoken time
(a sentence with twice the words gets twice the time), instead of the
even split that gives every line the same seconds whatever it says.

Requires exactly one caption line per spoken sentence, in order (same
rule as the word-synced path). Exits 3 when the counts differ — the
caller then falls back to the even split.
"""
import argparse
import re
import sys


def split_sentences(text):
    # Sentence ends: . ! ? plus Arabic ؟ / Urdu ۔ and Devanagari danda । ॥
    parts = re.split(r"(?<=[.!?؟۔।॥])\s+", text.strip())
    return [p.strip() for p in parts if p.strip()]


def ts(seconds):
    seconds = max(0.0, seconds)
    ms = int(round(seconds * 1000))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    sec, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{sec:02d},{ms:03d}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", required=True)
    ap.add_argument("--captions", required=True)
    ap.add_argument("--duration", type=float, required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    sentences = split_sentences(args.text)
    lines = [l.strip() for l in args.captions.splitlines() if l.strip()]
    if not sentences or not lines:
        print("no sentences or no caption lines", file=sys.stderr)
        return 3
    if len(sentences) != len(lines):
        print(f"sentences ({len(sentences)}) != captions ({len(lines)})",
              file=sys.stderr)
        return 3

    counts = [max(1, len(s.split())) for s in sentences]
    total = sum(counts)
    entries = []
    t = 0.0
    for i, (line, c) in enumerate(zip(lines, counts)):
        span = args.duration * c / total
        start = t
        end = args.duration if i == len(lines) - 1 else t + span - 0.05
        if end - start >= 0.2:
            entries.append((start, end, line))
        t += span
    if len(entries) != len(lines):
        print("timing entries collapsed", file=sys.stderr)
        return 3

    with open(args.out, "w", encoding="utf-8") as f:
        for i, (s, e, line) in enumerate(entries, 1):
            f.write(f"{i}\n{ts(s)} --> {ts(e)}\n{line}\n\n")
    print(f"proportional captions: {len(entries)} entries over "
          f"{args.duration:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
