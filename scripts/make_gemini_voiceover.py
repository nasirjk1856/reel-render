#!/usr/bin/env python3
"""Generate a voiceover with Gemini native text-to-speech (single speaker).

Usage:
    GEMINI_API_KEY=... python3 make_gemini_voiceover.py \
        --text "..." --voice Kore --out-audio voice.mp3

Calls POST /v1beta/models/gemini-2.5-flash-preview-tts:generateContent with
responseModalities ["AUDIO"] and the requested prebuilt voice. The API
returns base64 PCM audio (16-bit, 24 kHz, mono); this script decodes it and
converts it to mp3 with ffmpeg.

Notes:
- The key comes ONLY from the GEMINI_API_KEY environment variable (a
  GitHub Actions secret in the reel pipeline) — never a CLI argument.
- Gemini TTS returns NO word timings, so captions for a Gemini voiceover
  use proportional timing (scripts/make_proportional_srt.py), not the
  word-synced timing of the edge-tts path.
- Exits non-zero when the key is missing, the API errors (including a
  free-tier quota refusal), or no audio comes back — the reel must never
  ship a voiceover it does not really have.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import urllib.request
import urllib.error

MODEL = "gemini-2.5-flash-preview-tts"
SAMPLE_RATE = 24000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", required=True)
    ap.add_argument("--voice", default="Kore")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--out-audio", required=True)
    args = ap.parse_args()

    key = os.environ.get("GEMINI_API_KEY", "")
    if not key:
        print("ERROR: GEMINI_API_KEY is not set", file=sys.stderr)
        return 1

    url = (f"https://generativelanguage.googleapis.com/v1beta/models/"
           f"{args.model}:generateContent")
    body = json.dumps({
        "contents": [{"parts": [{"text": args.text}]}],
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {
                "voiceConfig": {
                    "prebuiltVoiceConfig": {"voiceName": args.voice}
                }
            },
        },
    }).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers={
        "Content-Type": "application/json",
        "x-goog-api-key": key,
    })
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            resp = json.load(r)
    except urllib.error.HTTPError as e:
        try:
            detail = json.load(e).get("error", {}).get("message", "")
        except Exception:
            detail = e.read().decode("utf-8", "replace")[:500]
        print(f"ERROR: Gemini TTS HTTP {e.code}: {detail}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"ERROR: Gemini TTS request failed: {e}", file=sys.stderr)
        return 1

    try:
        parts = resp["candidates"][0]["content"]["parts"]
        b64 = next(p["inlineData"]["data"] for p in parts if "inlineData" in p)
        pcm = base64.b64decode(b64)
    except (KeyError, IndexError, StopIteration, ValueError) as e:
        print(f"ERROR: no audio in Gemini TTS response: {e}", file=sys.stderr)
        print(json.dumps(resp)[:500], file=sys.stderr)
        return 1
    if not pcm:
        print("ERROR: Gemini TTS returned empty audio", file=sys.stderr)
        return 1

    pcm_path = args.out_audio + ".pcm"
    with open(pcm_path, "wb") as f:
        f.write(pcm)
    conv = subprocess.run([
        "ffmpeg", "-y", "-v", "error",
        "-f", "s16le", "-ar", str(SAMPLE_RATE), "-ac", "1",
        "-i", pcm_path, "-c:a", "libmp3lame", "-q:a", "4",
        args.out_audio,
    ])
    os.remove(pcm_path)
    if conv.returncode != 0 or not os.path.exists(args.out_audio):
        print("ERROR: ffmpeg could not convert the Gemini PCM audio",
              file=sys.stderr)
        return 1
    seconds = len(pcm) / 2 / SAMPLE_RATE
    print(f"gemini voiceover: {os.path.getsize(args.out_audio)} bytes, "
          f"~{seconds:.1f}s of audio (voice: {args.voice})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
