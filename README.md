# Reel Render — free 20-second vertical reels with FFmpeg on GitHub Actions

Renders a **20-second vertical reel (1080x1920, H.264 + AAC)** from motion
clip(s): **edits the clips together with smooth 0.5 s crossfades** (no hard
cuts), adds a free voiceover, burns captions in, draws a
title. It runs on GitHub's free runner minutes — no cloud render API, no paid
service, no manual editing.

## How it fits the pipeline

```
n8n Agent 1 ── researches the topic, writes the voiceover script + captions,
               and supplies the motion clip(s) as direct .mp4 URLs
        │
        │  repository_dispatch  (event_type: render-reel)
        ▼
GitHub Actions ── this repo ── FFmpeg crossfades clips, edge-tts voiceover,
                                burned-in captions, reel.mp4
        │
        │  workflow artifact "reel" (kept 7 days)
        ▼
n8n Agent 2 ── downloads the artifact, posts the reel
```

Agent 1 sends this JSON as the `client_payload` of the `repository_dispatch`
event (or the same fields as `workflow_dispatch` inputs):

```json
{
  "event_type": "render-reel",
  "client_payload": {
    "footage_url": "https://example.com/clip1.mp4,https://example.com/clip2.mp4",
    "title_text": "WAIT FOR IT...",
    "subtitle_text": "Ocean power in 20 seconds",
    "voiceover_text": "Watch the ocean power. Every wave carries a hidden force.",
    "voice_name": "en-US-GuyNeural",
    "caption_lines": "Watch the ocean power.\nEvery wave carries a hidden force.\nFollow for more.",
    "duration_seconds": "20"
  }
}
```

## Motion clips — where they come from

This repo **assembles** clips; it does not choose or generate the footage.
The motion clips arrive as direct `.mp4` URLs from the upstream agent.
Decided by the owner (22 Nov 2026): the motion is **free Hugging Face AI
video** — Lightricks LTX-Video on ZeroGPU, ~5 s vertical clips at 480x832,
generated anonymously or on the owner's free HF account (5 min GPU/day;
anonymous is only 2 min/day, not enough for 5 reels). Clips are original AI
video, genuinely moving — verified 22 Nov 2026 (ocean + hydraulic-press
crush clips). **FFmpeg animation is the fallback** so a reel never stalls
if the AI service queues or fails. The owner's PC is **not** used —
everything runs automatically with his PC off. Pexels stock is **not** the
reel source (it was only test footage for proving the render + motion).

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `footage_url` | yes | — | Direct link(s) to `.mp4` file(s). Comma-separated for several clips — joined in order. Must be direct file URLs, not web pages. |
| `title_text` | yes | — | Big white title text, top of the reel. |
| `subtitle_text` | no | `""` | Smaller yellow line under the title. Omit for title only. |
| `voiceover_text` | no | `""` | Script to speak. Generated with free edge-tts (Microsoft neural voices). Omit for no voiceover. |
| `voice_name` | no | `en-US-GuyNeural` | Clear male English voice. Any edge-tts voice works (e.g. `en-US-AriaNeural`). |
| `caption_lines` | no | `""` | Captions, one per line. Split **evenly** across the reel (see below). |
| `duration_seconds` | no | `20` | Reel length in seconds. Clips should total at least this long. |

**Caption timing (v3 rule):** the lines are split evenly across the reel's
**actual edited length** — with 3 lines over 20 s, line 1 shows 0–6.7 s,
line 2 6.7–13.3 s, line 3 13.3–20 s. Captions are
**not** word-synced to the voiceover. (A future version can use edge-tts
`--write-subtitles` timestamps for real word timing.)

## v3 editing — crossfades, trimming, upscale

- **Transitions:** clips are joined with a **0.5 s dissolve crossfade**
  (`xfade` video + `acrossfade` audio), not hard cuts. Verified frame by
  frame 22 Nov 2026: the mid-transition frame is a visible blend of both
  clips. All clip lengths are snapped to whole frames at 30 fps so the
  crossfade offsets stay frame-accurate.
- **Duration handling:** the crossfades eat (N−1) × 0.5 s, so the clips must
  total `duration_seconds` + (N−1) × 0.5 s for an exact-length reel.
  *More than needed:* the excess is trimmed **evenly** across all clips —
  half from the head, half from the tail of each clip (centre-cut), never
  below 1.0 s per clip (the remainder is redistributed; if every clip is
  already at 1.0 s, the tail is cut to the requested length).
  *Less than needed:* the reel comes out **shorter** and a clear warning
  is printed. Nothing is ever padded — no frozen frames, no still-image
  padding.
- **Upscale treatment:** 480p clips (the HF AI clips) are upscaled 2.25×
  with lanczos plus a **light unsharp** (5:5:0.5, luma only) — it only
  tightens what is already there, it does not invent detail. 1080p sources
  are not sharpened. The upscale is softer than true 1080p — honest limit,
  not a defect to hide.
- **Audio bed:** the clips' original audio (if any) is cut from the same
  window as the video, so bed and picture stay in sync across the
  crossfades (v2 cut the bed from the full clip).

## v3.1 text style — poster type (Anton, white + orange)

- **Font:** `fonts/Anton-Regular.ttf` (Anton, SIL Open Font Licence —
  bundled in this repo, no download needed on the runner). Title, subtitle
  and captions all use it; DejaVu Sans Bold is the fallback if the file is
  missing. The script registers Anton with fontconfig at run time so the
  libass caption renderer finds it.
- **Title:** 118 px white caps with a heavy black outline.
  **Subtitle:** 64 px orange `#FF9F1C` caps with a black outline.
  **Captions:** Anton caps, white with a heavy black outline — v3.2:
  FontSize 16, placed just below the centre of the frame (MarginV 115),
  per the owner's approval 22 Nov 2026.
- **Clip count for a full 20 s reel:** the crossfades eat (N−1) × 0.5 s, so
  four 5 s clips total 20.4 s but render only ~19 s. Supply **five 5 s
  clips** (25.5 s total) and the planner trims to an exact 20 s reel.

**`--start`:** `render.sh` defaults to skipping the first 2 s of each clip
(v1 behaviour); the workflow passes `--start 0`, so agent-supplied clips
are used exactly as given.

**Manual runs:** in the GitHub web UI the `caption_lines` box is a single
line — real newlines only work via `repository_dispatch` (what n8n sends)
or the API. For a manual run, leave captions out or trigger via curl.

**Audio:** the clips' original audio (if any) is kept as a quiet bed
(volume 0.12) under the voiceover; with no voiceover it is the main track;
with neither, the reel is silent. If voiceover generation fails, the run
**fails** instead of shipping a silent reel that was supposed to have a voice.

## Free-tier math (GitHub Free)

- Included usage: **2,000 Linux minutes/month** on a private repo
  (standard runners are free and unlimited on a public repo).
- One 20-second reel with voiceover + captions takes **~1–3 minutes**.
- 5 reels a day ≈ 5–15 minutes a day ≈ **150–450 minutes a month** —
  inside the free allowance. (Edge-tts itself is free — no key, no account.)

## Trigger it manually

1. Push this repo to GitHub (private or public).
2. Go to **Actions → Render Reel → Run workflow**.
3. Fill in `footage_url`, `title_text`, (optional) `subtitle_text`,
   `voiceover_text`, `voice_name`, `duration_seconds` → **Run workflow**.
4. When the run finishes, download the **`reel`** artifact from the run page.

Or trigger it from anywhere with a `repository_dispatch` POST:

```bash
curl -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer <GITHUB_TOKEN>" \
  https://api.github.com/repos/<owner>/<repo>/dispatches \
  -d '{"event_type":"render-reel","client_payload":{"footage_url":"https://example.com/clip.mp4","title_text":"WAIT FOR IT...","voiceover_text":"Watch this.","caption_lines":"Watch this.\nFollow for more.","duration_seconds":"20"}}'
```

(The token only needs `repo` scope for a private repo, or `public_repo`
for a public one. It lives in n8n, never in this repo.)

## Render locally (test the same command)

```bash
# Single clip, voiceover + captions:
bash scripts/render.sh --footage clip.mp4 --title "WAIT FOR IT..." \
  --voiceover-text "Watch the ocean power." \
  --captions "Watch the ocean power.
Every wave carries a hidden force.
Follow for more." \
  --duration 20 --output reel.mp4

# Several clips joined, pre-made voiceover file instead of edge-tts:
bash scripts/render.sh --clip clip1.mp4 --clip clip2.mp4 \
  --title "OCEAN POWER" --voiceover-file voice.mp3 \
  --captions captions.srt --duration 20 --start 0 --output reel.mp4
```

`--clip` accepts a local file or a direct `.mp4` URL (repeat it, or use
`--clips "a.mp4,b.mp4"`). `--captions` accepts an `.srt` file path or
newline-separated lines. `--voiceover-file` takes a ready `.mp3` instead
of generating one with edge-tts.

## Honest limits (v3)

- Render takes **~1–3 minutes per reel** — fast, but not instant.
- **Captions are evenly timed, not word-synced** to the voiceover.
- **The voiceover is a synthetic neural voice, not a human recording.**
- edge-tts needs internet on the runner (GitHub runners have direct
  internet; behind a strict proxy its websocket can fail — the script then
  fails loudly instead of shipping a silent reel).
- The footage URL(s) **must be direct `.mp4` links** (a Pexels/YouTube page
  URL will not work; use the file's direct link).
- If the clips total less than the requested length, the reel comes out
  **shorter** (with a warning) — nothing is padded. Any aspect-ratio input
  is scaled and centre-cropped to 1080x1920. Artifacts are kept **7 days** —
  download the reel promptly.
- HF AI clips are **5 s at 480p** — each 20 s reel needs 3–4 clips joined,
  and the upscale to 1080p is softer than true 1080p.
- **v1 behaviour is kept:** title/subtitle-only rendering still works —
  just omit `voiceover_text` and `caption_lines`.
