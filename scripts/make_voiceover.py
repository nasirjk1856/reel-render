#!/usr/bin/env python3
"""Generate a voiceover with edge-tts and capture word-boundary timings.

Usage:
    python3 make_voiceover.py --text "..." --voice ur-PK-AsadNeural \
        --out-audio voice.mp3 --out-words words.json [--proxy URL]

Writes the mp3 plus a JSON list of {"text": word, "start_ms": n,
"end_ms": n} for every word the voice actually speaks (WordBoundary events
from the edge-tts service). If the service sends no word boundaries, the
words file is an empty list and the caller falls back to even-split
captions. Exits non-zero (and writes nothing usable) when no audio comes
back — the reel must never ship a voiceover it does not really have.
"""
import argparse
import asyncio
import json
import sys


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", required=True)
    ap.add_argument("--voice", default="en-US-GuyNeural")
    ap.add_argument("--out-audio", required=True)
    ap.add_argument("--out-words", required=True)
    ap.add_argument("--proxy", default="")
    args = ap.parse_args()

    try:
        import edge_tts
    except ImportError:
        print("ERROR: edge-tts is not installed", file=sys.stderr)
        return 1

    kwargs = {}
    if args.proxy:
        kwargs["proxy"] = args.proxy
    try:
        communicate = edge_tts.Communicate(args.text, args.voice, **kwargs)
    except TypeError:
        # Older edge-tts without a proxy argument.
        communicate = edge_tts.Communicate(args.text, args.voice)

    audio = bytearray()
    words = []
    async for chunk in communicate.stream():
        ctype = chunk.get("type")
        if ctype == "audio":
            data = chunk.get("data")
            if data:
                audio.extend(data)
        elif ctype == "WordBoundary":
            # offset/duration arrive in 100-nanosecond units.
            try:
                start_ms = int(chunk["offset"]) // 10000
                dur_ms = int(chunk["duration"]) // 10000
            except (KeyError, TypeError, ValueError):
                continue
            text = (chunk.get("text") or "").strip()
            if not text:
                continue
            words.append({
                "text": text,
                "start_ms": start_ms,
                "end_ms": start_ms + dur_ms,
            })

    if not audio:
        print("ERROR: edge-tts returned no audio", file=sys.stderr)
        return 1
    with open(args.out_audio, "wb") as f:
        f.write(bytes(audio))
    with open(args.out_words, "w", encoding="utf-8") as f:
        json.dump(words, f, ensure_ascii=False)
    print(f"voiceover: {len(audio)} bytes, {len(words)} word boundaries")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
