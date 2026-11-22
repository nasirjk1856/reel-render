#!/usr/bin/env bash
# render.sh v3 — render a vertical reel (1080x1920, H.264 + AAC) with FFmpeg:
# EDIT 5-second motion clips together with smooth crossfades, add a
# voiceover, burn captions in.
#
# Usage:
#   bash scripts/render.sh --clip clip1.mp4 --clip clip2.mp4 \
#       --title "Title text" \
#       [--subtitle "Subtitle text"] \
#       [--voiceover-text "What the voice says..."] [--voice en-US-GuyNeural] \
#       [--voiceover-file voice.mp3] \
#       [--captions "First line
#   Second line
#   Third line"] \
#       [--duration 20] [--start 0] [--output reel.mp4]
#
# --clip           Motion clip: local .mp4 file or a direct http(s) URL to an
#                  .mp4 file (downloaded with curl). Repeat for more clips;
#                  they are joined in the order given. (v1: --footage <one
#                  clip> still works as an alias for a single --clip.)
# --clips          Same as --clip, but comma-separated in one argument.
# --title          Title text drawn on the reel (required).
# --subtitle       Optional second line of text (default: none).
# --voiceover-text Optional text to speak. Generated with edge-tts (free
#                  Microsoft neural voices, needs internet). If generation
#                  fails, the script FAILS LOUDLY — it never ships a reel
#                  pretending to have a voiceover it does not have.
# --voice          edge-tts voice name (default: en-US-GuyNeural, clear male
#                  English). Any edge-tts voice works, e.g. en-US-AriaNeural.
# --voiceover-file Instead of generating, use a ready-made voiceover .mp3
#                  (e.g. generated elsewhere). Mutually exclusive with
#                  --voiceover-text.
# --captions       Optional captions, either:
#                    * a path to an .srt file, or
#                    * newline-separated caption lines. The lines are split
#                      evenly across the reel's ACTUAL edited length (v3
#                      timing: NOT word-synced — each line shows for
#                      actual/lines).
# --duration       Reel length in seconds (default: 20).
# --start          Seconds to skip at the start of EACH clip (default: 2,
#                  kept from v1; pass 0 for pre-trimmed clips).
# --output         Output file path (default: reel.mp4).
#
# v3 editing (new in v3):
#   * Clips are joined with 0.5 s CROSSFADES (xfade video + acrossfade
#     audio) instead of hard cuts. The join is frame-accurate: every clip
#     length is snapped to whole frames at 30 fps before the xfade offsets
#     are computed.
#   * Duration handling: the crossfades eat (N-1) x 0.5 s, so the clips
#     must total --duration + (N-1) x 0.5 s for an exact-length reel.
#       - MORE than needed: the excess is trimmed EVENLY across all clips,
#         half from the head and half from the tail of each clip
#         (centre-cut), never trimming a clip below 1.0 s (any remainder is
#         redistributed to the other clips; if every clip is at 1.0 s and
#         excess still remains, the tail is cut to --duration).
#       - LESS than needed: the reel comes out SHORTER than requested and
#         a clear WARNING is printed. Nothing is ever padded — no frozen
#         frames, no still-image padding (the owner rejects stills).
#   * Upscale treatment: HF clips arrive at 480x832 and are upscaled 2.25x
#     to 1080x1920. The scale uses lanczos plus a LIGHT unsharp
#     (5:5:0.5, luma only) on sub-1080p sources — it only tightens what is
#     already there, it does not invent detail. 1080p sources are not
#     sharpened.
#   * Captions are timed to the FINAL edited timeline (the actual output
#     length, after transitions), so they still change at the right moments.
#
# Pipeline: each clip is normalised to 1080x1920 / 30 fps / H.264 (no
# audio), joined with xfade crossfades, then title/subtitle are drawn,
# captions are burned in (libass subtitles filter, DejaVu Sans), fade in/out
# is applied. Audio: the clips' original audio (if any clip has it) is kept
# as a low bed (volume 0.12) under the voiceover, crossfaded with
# acrossfade; with no voiceover it is the main track; with no original
# audio and no voiceover, the reel is silent (-an).
# Video: libx264 preset veryfast, yuv420p, +faststart. Audio: AAC 128k.
#
# Proven 22 Nov 2026 on this VM: v2 — 20 s, 1080x1920, H.264 + AAC.
# v3 test (see README): 20 s reel from 2x HF 5.1 s clips + 10.8 s Pexels
# segment, crossfades verified frame by frame. No secrets, no network calls
# besides the footage download and the edge-tts voice generation.
set -euo pipefail

TRANS_DUR=0.5     # crossfade length in seconds (video + audio)
MIN_CLIP_LEN=1.0  # never trim a clip below this many seconds
FPS=30

CLIPS=()
FOOTAGE=""
TITLE=""
SUBTITLE=""
DURATION=20
START=2
OUTPUT="reel.mp4"
VOICEOVER_TEXT=""
VOICE="en-US-GuyNeural"
VOICEOVER_FILE=""
CAPTIONS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clip)          CLIPS+=("$2"); shift 2 ;;
    --clips)         IFS=',' read -ra _parts <<< "$2"; CLIPS+=("${_parts[@]}"); shift 2 ;;
    --footage)       FOOTAGE="$2"; shift 2 ;;
    --title)         TITLE="$2"; shift 2 ;;
    --subtitle)      SUBTITLE="$2"; shift 2 ;;
    --duration)      DURATION="$2"; shift 2 ;;
    --start)         START="$2"; shift 2 ;;
    --output)        OUTPUT="$2"; shift 2 ;;
    --voiceover-text) VOICEOVER_TEXT="$2"; shift 2 ;;
    --voice)         VOICE="$2"; shift 2 ;;
    --voiceover-file) VOICEOVER_FILE="$2"; shift 2 ;;
    --captions)      CAPTIONS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# v1 alias: --footage is a single clip.
if [[ -n "$FOOTAGE" ]]; then CLIPS+=("$FOOTAGE"); fi
if [[ ${#CLIPS[@]} -eq 0 ]]; then echo "--clip (or --footage) is required" >&2; exit 2; fi
if [[ -z "$TITLE" ]]; then echo "--title is required" >&2; exit 2; fi
if [[ -n "$VOICEOVER_TEXT" && -n "$VOICEOVER_FILE" ]]; then
  echo "--voiceover-text and --voiceover-file are mutually exclusive" >&2; exit 2
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- drawtext escaping (colon, quote, backslash, percent are special) -------
escape_drawtext() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//:/\\:}"
  s="${s//\'/\\\'}"
  s="${s//%/\\%}"
  printf '%s' "$s"
}

TITLE_ESC="$(escape_drawtext "$TITLE")"
SUBTITLE_ESC="$(escape_drawtext "$SUBTITLE")"

# --- Font: prefer the DejaVu Bold file, fall back to the fontconfig name ----
if [[ -f /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf ]]; then
  FONT_OPT="fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
else
  # drawtext with a font name needs fontconfig (present on ubuntu-latest).
  FONT_OPT="font='DejaVu Sans'"
fi

# --- 1. Resolve clips to local files ----------------------------------------
CLIP_FILES=()
i=0
for c in "${CLIPS[@]}"; do
  i=$((i + 1))
  if [[ "$c" =~ ^https?:// ]]; then
    f="$WORKDIR/clip${i}.mp4"
    echo "Downloading clip $i: $c"
    curl -fsSL --max-time 300 -o "$f" "$c"
  else
    if [[ ! -f "$c" ]]; then echo "Clip file not found: $c" >&2; exit 2; fi
    f="$c"
  fi
  CLIP_FILES+=("$f")
done

N=${#CLIP_FILES[@]}

# --- 2. Plan: per-clip (ss, dur) + actual output length ---------------------
# Probe each clip, cut to its usable length (after --start), then:
#   * total > needed: trim the excess evenly, half head / half tail
#     (centre-cut), never below MIN_CLIP_LEN (redistribute the remainder);
#   * total <= needed: use everything, output comes out short + warning.
# All lengths are snapped to whole frames at $FPS so xfade offsets stay
# frame-accurate. Writes lines "ss dur" per clip, then ACTUAL and SHORTFALL.
PLAN="$WORKDIR/plan.txt"
python3 - "$DURATION" "$START" "$TRANS_DUR" "$MIN_CLIP_LEN" "$FPS" "$PLAN" \
  "${CLIP_FILES[@]}" <<'PY'
import subprocess, sys
duration = float(sys.argv[1]); start = float(sys.argv[2])
trans = float(sys.argv[3]); min_len = float(sys.argv[4]); fps = int(sys.argv[5])
plan_path = sys.argv[6]; files = sys.argv[7:]

def probe(f):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
        "format=duration", "-of", "csv=p=0", f],
        capture_output=True, text=True, check=True)
    return float(out.stdout.strip())

def snap(x):
    return round(x * fps) / fps

usable = []
for f in files:
    d = probe(f)
    u = d - start
    if u <= 0:
        sys.exit(f"clip {f} is {d}s long; --start {start}s leaves nothing usable")
    usable.append(u)

n = len(files)
needed = duration + (n - 1) * trans
total = sum(usable)

if total <= needed:
    durs = [snap(u) for u in usable]
    starts = [snap(start)] * n
    actual = sum(durs) - (n - 1) * trans
    shortfall = duration - actual
else:
    excess = total - needed
    durs = list(usable)
    remaining = excess
    while remaining > 0.001:
        eligible = [i for i in range(n) if durs[i] > min_len]
        if not eligible:
            break
        share = remaining / len(eligible)
        took = 0.0
        for i in eligible:
            take = min(share, durs[i] - min_len)
            durs[i] -= take
            took += take
        remaining -= took
        if took <= 0:
            break
    starts = []
    final_durs = []
    for i in range(n):
        trim = usable[i] - durs[i]
        starts.append(snap(start + trim / 2.0))
        final_durs.append(snap(durs[i]))
    durs = final_durs
    actual = sum(durs) - (n - 1) * trans
    shortfall = 0.0

with open(plan_path, "w") as f:
    for i in range(n):
        f.write(f"{starts[i]:.3f} {durs[i]:.3f}\n")
    f.write(f"ACTUAL {actual:.3f}\n")
    f.write(f"SHORTFALL {shortfall:.3f}\n")
PY

PLAN_SS=(); PLAN_DUR=(); ACTUAL="$DURATION"; SHORTFALL=0
while read -r a b; do
  case "$a" in
    ACTUAL) ACTUAL="$b" ;;
    SHORTFALL) SHORTFALL="$b" ;;
    *) PLAN_SS+=("$a"); PLAN_DUR+=("$b") ;;
  esac
done < "$PLAN" || true

# Final length is the edited length, capped at the requested duration (the
# cap only bites if every clip hit the 1.0 s floor and excess still remained
# — then the tail is cut to --duration).
FINAL_LEN=$(awk -v a="$ACTUAL" -v d="$DURATION" 'BEGIN { printf "%.3f", (a < d ? a : d) }')

if (( $(awk -v s="$SHORTFALL" 'BEGIN { print (s > 0.001) }') )); then
  echo "WARNING: clips total only ${ACTUAL}s of edited video;" >&2
  echo "WARNING: reel will be ${FINAL_LEN}s instead of the requested ${DURATION}s." >&2
  echo "WARNING: no padding was added — frozen frames are never used." >&2
fi
echo "Plan: $N clip(s), edited length ${FINAL_LEN}s (requested ${DURATION}s)"
for ((i = 0; i < N; i++)); do
  echo "  clip $((i + 1)): ss=${PLAN_SS[$i]} dur=${PLAN_DUR[$i]}"
done

# --- 3. Normalise each clip: 1080x1920, 30 fps, H.264, no audio ------------
# Identical streams, so xfade can join them frame-accurately. The audio bed
# is cut from the SAME (ss, dur) window as the video, so bed and video stay
# in sync across the crossfades (v2 cut the bed from the full clip).
NORM_FILES=()
BED_FILES=()
HAS_AUDIO=0
i=0
for f in "${CLIP_FILES[@]}"; do
  i=$((i + 1))
  ss="${PLAN_SS[$((i - 1))]}"; dur="${PLAN_DUR[$((i - 1))]}"
  # Light unsharp only for sub-1080p sources (the 480p HF upscale); 1080p
  # sources are not sharpened.
  src_h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
    -of csv=p=0 "$f")
  if (( src_h < 1080 )); then
    SHARPEN=",unsharp=5:5:0.5:5:5:0.0"
  else
    SHARPEN=""
  fi
  norm="$WORKDIR/norm${i}.mp4"
  echo "Normalising clip $i -> 1080x1920 30fps (ss=${ss} dur=${dur})"
  ffmpeg -y -v error -ss "$ss" -t "$dur" -i "$f" \
    -vf "scale=1080:1920:force_original_aspect_ratio=increase:flags=lanczos,crop=1080:1920${SHARPEN},format=yuv420p,fps=${FPS}" \
    -c:v libx264 -preset veryfast -an "$norm"
  NORM_FILES+=("$norm")
  # Bed segment for this clip (real audio, or silence if the clip has none).
  bed="$WORKDIR/bed${i}.aac"
  if ffprobe -v error -select_streams a:0 -show_entries stream=index \
       -of csv=p=0 "$f" | grep -q .; then
    ffmpeg -y -v error -ss "$ss" -t "$dur" -i "$f" -vn -c:a aac -ar 48000 -ac 2 "$bed"
    HAS_AUDIO=1
  else
    ffmpeg -y -v error -f lavfi -i anullsrc=r=48000:cl=stereo -t "$dur" -c:a aac "$bed"
  fi
  BED_FILES+=("$bed")
done

# --- 4. Voiceover ------------------------------------------------------------
VOICE_FILE=""
if [[ -n "$VOICEOVER_FILE" ]]; then
  if [[ ! -f "$VOICEOVER_FILE" ]]; then echo "Voiceover file not found: $VOICEOVER_FILE" >&2; exit 2; fi
  VOICE_FILE="$VOICEOVER_FILE"
elif [[ -n "$VOICEOVER_TEXT" ]]; then
  if ! command -v edge-tts >/dev/null 2>&1; then
    echo "edge-tts not found, installing it..."
    python3 -m pip install --break-system-packages edge-tts \
      || { echo "ERROR: could not install edge-tts (needs internet + pip)" >&2; exit 1; }
  fi
  VOICE_FILE="$WORKDIR/voice.mp3"
  echo "Generating voiceover with edge-tts (voice: $VOICE)..."
  EDGE_TTS_ARGS=(--voice "$VOICE" --text "$VOICEOVER_TEXT" --write-media "$VOICE_FILE")
  # edge-tts uses aiohttp, which does not read proxy env vars; pass the
  # proxy explicitly when one is set (this VM's egress proxy, for example).
  if [[ -n "${https_proxy:-${HTTPS_PROXY:-}}" ]]; then
    EDGE_TTS_ARGS+=(--proxy "${https_proxy:-$HTTPS_PROXY}")
  fi
  if ! edge-tts "${EDGE_TTS_ARGS[@]}"; then
    echo "ERROR: edge-tts failed to generate the voiceover." >&2
    echo "The reel was NOT rendered — a reel without its promised voiceover is worse than no reel." >&2
    echo "Check the voice name, the network, and (behind a proxy) that the proxy allows the edge-tts websocket." >&2
    exit 1
  fi
  if [[ ! -s "$VOICE_FILE" ]]; then
    echo "ERROR: edge-tts produced an empty voiceover file." >&2; exit 1
  fi
fi

# --- 5. Captions (timed to the FINAL edited length) --------------------------
SRT_FILE=""
if [[ -n "$CAPTIONS" ]]; then
  SRT_FILE="$WORKDIR/captions.srt"
  if [[ -f "$CAPTIONS" ]]; then
    echo "Using caption file: $CAPTIONS"
    cp "$CAPTIONS" "$SRT_FILE"
  else
    echo "Building timed captions (even split across ${FINAL_LEN}s)..."
    python3 - "$CAPTIONS" "$FINAL_LEN" "$SRT_FILE" <<'PY'
import sys
text, dur, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
lines = [l.strip() for l in text.splitlines() if l.strip()]
if not lines:
    sys.exit("no caption lines given")
n = len(lines)
step = dur / n
def ts(s):
    ms = int(round(s * 1000))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    sec, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{sec:02d},{ms:03d}"
with open(out, "w") as f:
    for i, line in enumerate(lines):
        f.write(f"{i + 1}\n{ts(i * step)} --> {ts((i + 1) * step)}\n{line}\n\n")
PY
  fi
fi

# --- 6. Final render: crossfade join + overlays + audio mix -----------------
# Inputs: 0..N-1 = normalised video, N..2N-1 = bed audio (only if any clip
# has real audio), last = voiceover (if any).
# Video chain: setpts each input, then xfade chain (0.5 s dissolve).
#   xfade offset for incoming clip i = sum(durs[0..i-1]) - i * TRANS_DUR.
# Audio bed chain: asetpts each bed, then acrossfade chain (same 0.5 s).
# Overlays (drawtext title/subtitle, captions, fades) run on the joined
# video; the audio mix is voiceover at full volume + bed at 0.12, padded to
# the full reel length; voiceover alone if there is no bed; bed alone if
# there is no voiceover; silent (-an) if there is neither.
FADE_OUT_START=$(awk -v d="$FINAL_LEN" 'BEGIN { printf "%.1f", d - 0.5 }')

FC=""
for ((i = 0; i < N; i++)); do
  FC+="[${i}:v]setpts=PTS-STARTPTS[v${i}];"
done
if (( N == 1 )); then
  FC+="[v0]null[vx];"
else
  prev="v0"
  cum="${PLAN_DUR[0]}"
  for ((i = 1; i < N; i++)); do
    off=$(awk -v c="$cum" -v k="$i" -v t="$TRANS_DUR" 'BEGIN { printf "%.3f", c - k * t }')
    FC+="[${prev}][v${i}]xfade=transition=fade:duration=${TRANS_DUR}:offset=${off}[x${i}];"
    prev="x${i}"
    cum=$(awk -v c="$cum" -v d="${PLAN_DUR[$i]}" 'BEGIN { printf "%.3f", c + d }')
  done
  FC+="[${prev}]null[vx];"
fi

INPUTS=()
for f in "${NORM_FILES[@]}"; do INPUTS+=(-i "$f"); done
if (( HAS_AUDIO == 1 )); then
  for ((i = 0; i < N; i++)); do
    bi=$((N + i))
    FC+="[${bi}:a]asetpts=PTS-STARTPTS[b${i}];"
  done
  if (( N == 1 )); then
    FC+="[b0]anull[bed];"
  else
    prev="b0"
    for ((i = 1; i < N; i++)); do
      FC+="[${prev}][b${i}]acrossfade=d=${TRANS_DUR}[c${i}];"
      prev="c${i}"
    done
    FC+="[${prev}]anull[bed];"
  fi
  for f in "${BED_FILES[@]}"; do INPUTS+=(-i "$f"); done
fi

# Overlays on the joined video.
OV="[vx]drawtext=${FONT_OPT}:text='${TITLE_ESC}':fontcolor=white:fontsize=72:borderw=4:bordercolor=black:x=(w-text_w)/2:y=200"
if [[ -n "$SUBTITLE" ]]; then
  OV+=",drawtext=${FONT_OPT}:text='${SUBTITLE_ESC}':fontcolor=yellow:fontsize=44:borderw=3:bordercolor=black:x=(w-text_w)/2:y=300"
fi
if [[ -n "$SRT_FILE" ]]; then
  # libass renders SRT with a default PlayResY of 288, so style sizes are
  # scaled by video_height/288 (6.67x at 1920): FontSize 12 ≈ 80 px tall,
  # MarginV 22 ≈ 147 px from the bottom. (FontSize 30 here would render
  # ~200 px tall and sit mid-frame — verified the hard way, 22 Nov 2026.)
  OV+=",subtitles='${SRT_FILE}':force_style='FontName=DejaVu Sans,FontSize=12,PrimaryColour=&HFFFFFF&,OutlineColour=&H000000&,BorderStyle=1,Outline=2,Shadow=0,Alignment=2,MarginV=22'"
fi
OV+=",fade=t=in:st=0:d=0.5,fade=t=out:st=${FADE_OUT_START}:d=0.5[vout];"
FC+="$OV"

# Audio mix.
# NOTE: VO_IDX is the ffmpeg INPUT index (0-based count of -i inputs), not
# the INPUTS array length — each input adds two array elements (-i + path).
NUM_INPUTS=${#NORM_FILES[@]}
if (( HAS_AUDIO == 1 )); then NUM_INPUTS=$((NUM_INPUTS + N)); fi
VO_IDX=-1
if [[ -n "$VOICE_FILE" ]]; then
  INPUTS+=(-i "$VOICE_FILE")
  VO_IDX=$NUM_INPUTS
fi
AUDIO_MAP=()
if [[ -n "$VOICE_FILE" && "$HAS_AUDIO" == 1 ]]; then
  FC+="[${VO_IDX}:a]volume=1.0[vo];[bed]volume=0.12[bd];[vo][bd]amix=inputs=2:duration=longest:normalize=0,apad=whole_dur=${FINAL_LEN},atrim=0:${FINAL_LEN}[aout];"
  AUDIO_MAP=(-map "[aout]")
elif [[ -n "$VOICE_FILE" ]]; then
  FC+="[${VO_IDX}:a]apad=whole_dur=${FINAL_LEN},atrim=0:${FINAL_LEN}[aout];"
  AUDIO_MAP=(-map "[aout]")
elif (( HAS_AUDIO == 1 )); then
  FC+="[bed]apad=whole_dur=${FINAL_LEN},atrim=0:${FINAL_LEN}[aout];"
  AUDIO_MAP=(-map "[aout]")
fi

echo "Rendering ${FINAL_LEN}s vertical reel -> ${OUTPUT}"
if [[ ${#AUDIO_MAP[@]} -gt 0 ]]; then
  ffmpeg -y -v error \
    "${INPUTS[@]}" \
    -filter_complex "$FC" \
    -map "[vout]" "${AUDIO_MAP[@]}" \
    -c:v libx264 -preset veryfast -threads 2 \
    -pix_fmt yuv420p -movflags +faststart \
    -c:a aac -b:a 128k -t "$FINAL_LEN" \
    "$OUTPUT"
else
  ffmpeg -y -v error \
    "${INPUTS[@]}" \
    -filter_complex "$FC" \
    -map "[vout]" \
    -c:v libx264 -preset veryfast -threads 2 \
    -pix_fmt yuv420p -movflags +faststart -an -t "$FINAL_LEN" \
    "$OUTPUT"
fi

echo "Done: $OUTPUT"
ffprobe -v error -show_entries format=duration,size \
  -show_entries stream=width,height,codec_name -of default=nw=1 "$OUTPUT"
