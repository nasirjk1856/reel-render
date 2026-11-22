#!/usr/bin/env python3
"""Build a word-synced SRT: time each caption line to the words actually
spoken in the voiceover.

Usage:
    python3 make_timed_srt.py --words words.json --text "voiceover script" \
        --captions "English line 1\nEnglish line 2" \
        --duration 20 --out timed.srt

The voiceover script is split into sentences (on . ? ! and the Urdu
stops . / ?). Each caption line must correspond, IN ORDER, to one spoken
sentence — the caption text itself can be in another language (e.g. an
Urdu voiceover with English captions), but there must be exactly one
caption per sentence. Each sentence's words are matched as a consecutive
sequence in the word-boundary stream, so the caption appears exactly while
those words are spoken — no more fixed 5-second grid.

Exits 0 with the SRT written, or 3 when the timing cannot be built
(counts differ, or a sentence's words are not found) — the caller then
falls back to even-split captions.
"""
import argparse
import json
import re
import sys

PUNCT = ".,?!;:\"'()[]{}<>«»“”‘’…—–-۔؟،؛"


def norm(word):
    return word.strip(PUNCT).lower()


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
    ap.add_argument("--words", required=True)
    ap.add_argument("--text", required=True)
    ap.add_argument("--captions", required=True)
    ap.add_argument("--duration", type=float, required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    with open(args.words, encoding="utf-8") as f:
        spoken = json.load(f)
    if not spoken:
        print("no word boundaries in file", file=sys.stderr)
        return 3
    spoken_norm = [norm(w["text"]) for w in spoken]

    sentences = split_sentences(args.text)
    lines = [l.strip() for l in args.captions.splitlines() if l.strip()]
    if not sentences or not lines:
        print("no sentences or no caption lines", file=sys.stderr)
        return 3
    if len(sentences) != len(lines):
        print(f"sentences ({len(sentences)}) != captions ({len(lines)})",
              file=sys.stderr)
        return 3

    entries = []
    pos = 0
    for sent, line in zip(sentences, lines):
        seg = [w for w in (norm(w) for w in sent.split()) if w]
        if not seg:
            print(f"empty sentence: {sent!r}", file=sys.stderr)
            return 3
        found = -1
        for j in range(pos, len(spoken_norm) - len(seg) + 1):
            if spoken_norm[j:j + len(seg)] == seg:
                found = j
                break
        if found < 0:
            print(f"sentence not found in spoken words: {sent!r}",
                  file=sys.stderr)
            return 3
        start = spoken[found]["start_ms"] / 1000.0 - 0.05
        end = spoken[found + len(seg) - 1]["end_ms"] / 1000.0 + 0.05
        entries.append((max(0.0, start), end, line))
        pos = found + len(seg)

    # No overlaps; clamp to the reel length.
    cleaned = []
    for i, (s, e, line) in enumerate(entries):
        if i + 1 < len(entries):
            e = min(e, entries[i + 1][0] - 0.05)
        e = min(e, args.duration)
        if e - s < 0.2:
            continue
        cleaned.append((s, e, line))
    if len(cleaned) != len(entries):
        print("timing entries collapsed", file=sys.stderr)
        return 3

    with open(args.out, "w", encoding="utf-8") as f:
        for i, (s, e, line) in enumerate(cleaned, 1):
            f.write(f"{i}\n{ts(s)} --> {ts(e)}\n{line}\n\n")
    print(f"timed captions: {len(cleaned)} entries, "
          f"{cleaned[0][0]:.2f}s..{cleaned[-1][1]:.2f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
