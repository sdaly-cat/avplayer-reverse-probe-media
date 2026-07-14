#!/usr/bin/env bash
#
# make-test-media.sh — regenerate the synthetic reverse-probe test clips.
#
# Produces two H.264 MP4s that are IDENTICAL except for GOP structure:
#   synthetic_ball_1080p_5994fps_3min_closedgop.mp4   (open-gop=0)
#   synthetic_ball_1080p_5994fps_3min_opengop.mp4     (open-gop=1)
#
# Each clip is a DVD-style bouncing ball over a faint static grid, with burned-in overlays:
#   - static format label (says "CLOSED GOP-30" / "OPEN GOP-30")
#   - live timecode  (TC HH:MM:SS.mmm)
#   - live FRAME counter (cyan) — in reverse, watch it decrement: smooth = good, stutter = jank
#   - a direction ARROW inside the ball pointing the way it travels in FORWARD playback
#     (so reverse is unmistakable: in reverse the ball moves OPPOSITE the arrow)
#
# REQUIREMENTS
#   ffmpeg built WITH the `drawtext` filter (needs libfreetype). Homebrew's slim `ffmpeg`
#   formula does NOT include it — install `ffmpeg-full`:
#       brew install ffmpeg-full && brew link --overwrite --force ffmpeg-full
#   Verify:  ffmpeg -hide_banner -filters | grep drawtext
#
# USAGE
#   ./scripts/make-test-media.sh [OUT_DIR]        # default OUT_DIR = ./ (repo root)
#
# AFTER REGENERATING — publish to the GitHub Release the app streams from:
#   gh release upload v1 --clobber \
#     "$OUT_DIR/synthetic_ball_1080p_5994fps_3min_closedgop.mp4" \
#     "$OUT_DIR/synthetic_ball_1080p_5994fps_3min_opengop.mp4" \
#     --repo sdaly-cat/avplayer-reverse-probe-media
#   (--clobber replaces the existing assets in place, so the URLs baked into the app don't change.)
#
set -euo pipefail

OUT_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

# ---- Knobs (tweak these to change the media) --------------------------------
WIDTH=1920
HEIGHT=1080
FPS="60000/1001"        # 59.94 (NTSC). Use "60" for exactly 60, "30" for 30, etc.
DURATION="${DURATION:-180}"   # seconds (env-overridable: DURATION=15 ./make-test-media.sh for a quick preview)
BITRATE="12M"           # CBR target. Drives file size (~270MB at 12M/180s). Match our media.
GOP=30                  # keyframe interval (frames)
FONT="/System/Library/Fonts/Supplemental/Arial.ttf"   # any TTF drawtext can read

BG_COLOR="0x0d1b2a"     # dark navy background
BALL_COLOR="0xffd21e"   # yellow ball
BALL_SIZE=160           # ball sprite is BALL_SIZE x BALL_SIZE; radius = BALL_SIZE/2
BALL_R2=$(( (BALL_SIZE/2) * (BALL_SIZE/2) ))           # radius^2 for the circle mask
BALL_C=$(( BALL_SIZE/2 ))                              # ball center
SPEED_X=0.27            # horizontal bounce frequency (bigger = faster)
SPEED_Y=0.37            # vertical bounce frequency (different from X so it wanders)
GRID=128               # static reference-grid spacing (px)
ARROW_SIZE=150         # size of the direction-arrow glyph drawn inside the ball
MAXX=$(( WIDTH - BALL_SIZE ))    # ball horizontal travel range (matches overlay's W-w)
MAXY=$(( HEIGHT - BALL_SIZE ))   # ball vertical travel range   (matches overlay's H-h)

# The direction arrow needs diagonal-arrow glyphs (U+2196..2199). Arial lacks them; Apple Symbols
# has them, but its path contains a space (awkward in an ffmpeg filtergraph) — so stage a no-space
# copy in a temp dir and remove it on exit.
ARROW_FONT_SRC="/System/Library/Fonts/Apple Symbols.ttf"
ARROW_FONT="$(mktemp -d)/arrows.ttf"
cp "$ARROW_FONT_SRC" "$ARROW_FONT"
trap 'rm -rf "$(dirname "$ARROW_FONT")"' EXIT
# -----------------------------------------------------------------------------

encode() {
  local open_gop="$1"   # 0 = closed, 1 = open
  local gop_label="$2"  # "CLOSED" / "OPEN"
  local out="$3"

  echo ">>> Encoding $gop_label GOP -> $out"

  # Filtergraph:
  #  [0] background color + faint static grid
  #  [1] ball color source -> carved into a circle via geq alpha
  #  overlay the ball on the grid, bouncing (triangle-wave position from t)
  #  then three drawtext passes (format label, timecode, frame counter)
  # The arrow tracks the ball via the SAME t-based position formula, and one of four diagonal
  # glyphs is enabled per motion quadrant. Velocity sign (from the triangle-wave position):
  #   moving RIGHT when mod(t*SPEED_X,2) >= 1 ; moving DOWN when mod(t*SPEED_Y,2) >= 1.
  # (direction flips exactly at each bounce, which is what we want to see in reverse)
  local ax="'${MAXX}*abs(mod(t*${SPEED_X},2)-1)+${BALL_C}-text_w/2'"
  local ay="'${MAXY}*abs(mod(t*${SPEED_Y},2)-1)+${BALL_C}-text_h/2'"
  local aopts="fontfile=${ARROW_FONT}:fontsize=${ARROW_SIZE}:fontcolor=black:borderw=6:bordercolor=white@0.85:x=${ax}:y=${ay}"

  local filter="[0:v]drawgrid=w=${GRID}:h=${GRID}:t=2:color=white@0.10[bg];\
[1:v]format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(lte((X-${BALL_C})*(X-${BALL_C})+(Y-${BALL_C})*(Y-${BALL_C}),${BALL_R2}),255,0)'[ball];\
[bg][ball]overlay=x='(W-w)*abs(mod(t*${SPEED_X},2)-1)':y='(H-h)*abs(mod(t*${SPEED_Y},2)-1)':shortest=1[m];\
[m]drawtext=${aopts}:text='↘':enable='gte(mod(t*${SPEED_X},2),1)*gte(mod(t*${SPEED_Y},2),1)'[ar1];\
[ar1]drawtext=${aopts}:text='↗':enable='gte(mod(t*${SPEED_X},2),1)*lt(mod(t*${SPEED_Y},2),1)'[ar2];\
[ar2]drawtext=${aopts}:text='↙':enable='lt(mod(t*${SPEED_X},2),1)*gte(mod(t*${SPEED_Y},2),1)'[ar3];\
[ar3]drawtext=${aopts}:text='↖':enable='lt(mod(t*${SPEED_X},2),1)*lt(mod(t*${SPEED_Y},2),1)'[ar4];\
[ar4]drawtext=fontfile=${FONT}:text='${WIDTH}x${HEIGHT} | 59.94 fps | H.264 High | ${gop_label} GOP-${GOP}':x=40:y=40:fontsize=44:fontcolor=white:box=1:boxcolor=black@0.55:boxborderw=14[m2];\
[m2]drawtext=fontfile=${FONT}:text='TC %{pts\\:hms}':x=40:y=h-130:fontsize=52:fontcolor=white:box=1:boxcolor=black@0.55:boxborderw=14[m3];\
[m3]drawtext=fontfile=${FONT}:text='FRAME %{n}':x=40:y=h-66:fontsize=52:fontcolor=0x00E5FF:box=1:boxcolor=black@0.55:boxborderw=14,format=yuv420p[v]"

  ffmpeg -y \
    -f lavfi -i "color=c=${BG_COLOR}:s=${WIDTH}x${HEIGHT}:r=${FPS}" \
    -f lavfi -i "color=c=${BALL_COLOR}:s=${BALL_SIZE}x${BALL_SIZE}:r=${FPS}" \
    -filter_complex "$filter" \
    -map "[v]" -t "$DURATION" \
    -c:v libx264 -profile:v high -preset veryfast \
    -x264-params "open-gop=${open_gop}:nal-hrd=cbr:keyint=${GOP}:min-keyint=${GOP}:scenecut=0" \
    -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize "$BITRATE" \
    -pix_fmt yuv420p -movflags +faststart \
    "$out"
}

encode 0 "CLOSED" "$OUT_DIR/synthetic_ball_1080p_5994fps_3min_closedgop.mp4"
encode 1 "OPEN"   "$OUT_DIR/synthetic_ball_1080p_5994fps_3min_opengop.mp4"

echo
echo "Done. Verify GOP structure in the ffmpeg log (look for 'open_gop=0' vs 'open_gop=1')."
echo "Then upload with the 'gh release upload v1 --clobber ...' command in this script's header."
