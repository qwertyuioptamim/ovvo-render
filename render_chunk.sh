#!/usr/bin/env bash
# =====================================================================
# render_chunk.sh — FREEZE. GitHub Actions render worker
# Renders ONE frame chunk of a packed Blender 3.6 Eevee scene.
# Called by .github/workflows/render.yml; also runnable locally
# (that is exactly how it was validated — see BUILDLOG.md).
#
# Inputs (environment variables):
#   SCENE_ZIP_URL  Direct-download URL of the scene .zip   (required)
#   FRAME_START    First frame of this chunk                (required)
#   FRAME_END      Last frame of this chunk                 (required)
#   BLEND_PATH     Path of the .blend inside the zip        (optional;
#                  default: the only/first .blend found, root preferred)
#   BLENDER_BIN    Blender executable                       (optional;
#                  default: ./blender-3.6.10-linux-x64/blender if present,
#                  else `blender` from PATH)
#   OUT_DIR        Where frame_NNNN.png files go            (optional;
#                  default: ./out)
#   WORK_DIR       Scratch dir for download/extract         (optional;
#                  default: mktemp -d)
#
# The scene's cameras are bound via timeline markers and scene.camera
# is None by design — bind_cameras.py (same dir as this script) is
# passed to Blender and applies the marker binding every frame.
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${SCENE_ZIP_URL:?SCENE_ZIP_URL is required}"
: "${FRAME_START:?FRAME_START is required}"
: "${FRAME_END:?FRAME_END is required}"
BLEND_PATH="${BLEND_PATH:-}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
mkdir -p "$OUT_DIR" "$WORK_DIR"

if [ -z "${BLENDER_BIN:-}" ]; then
  if [ -x "$PWD/blender-3.6.10-linux-x64/blender" ]; then
    BLENDER_BIN="$PWD/blender-3.6.10-linux-x64/blender"
  else
    BLENDER_BIN="$(command -v blender || true)"
  fi
fi
[ -n "${BLENDER_BIN:-}" ] && [ -x "$BLENDER_BIN" ] || {
  echo "ERROR: no usable BLENDER_BIN (got '${BLENDER_BIN:-}')"; exit 1; }

# Software-GL (llvmpipe) defaults — only where the caller has not
# already provided its own GL environment (the local Mesa recipe and
# the JANCTION/Colab EGL fixes pass theirs in explicitly).
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
if [ -z "${__EGL_VENDOR_LIBRARY_DIRS:-}" ] && [ -d /usr/share/glvnd/egl_vendor.d ]; then
  export __EGL_VENDOR_LIBRARY_DIRS=/usr/share/glvnd/egl_vendor.d
fi

echo "== render_chunk: frames $FRAME_START-$FRAME_END"
echo "== blender: $BLENDER_BIN"
"$BLENDER_BIN" --version | head -1

# ---- 1. Fetch + extract the scene ----
ZIP="$WORK_DIR/scene.zip"
if [ ! -f "$ZIP" ]; then
  echo "== downloading: $SCENE_ZIP_URL"
  curl -L --fail --retry 3 --retry-delay 5 -o "$ZIP" "$SCENE_ZIP_URL"
fi
SCENE_DIR="$WORK_DIR/scene"
mkdir -p "$SCENE_DIR"
if command -v unzip >/dev/null 2>&1; then
  unzip -q -o "$ZIP" -d "$SCENE_DIR"
else
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$ZIP" "$SCENE_DIR"
fi

# ---- 2. Locate the .blend ----
if [ -n "$BLEND_PATH" ]; then
  BLEND="$SCENE_DIR/$BLEND_PATH"
else
  # Prefer a .blend at the zip root; else the first one found.
  BLEND="$(find "$SCENE_DIR" -maxdepth 1 -name '*.blend' | sort | head -1 || true)"
  if [ -z "$BLEND" ]; then
    BLEND="$(find "$SCENE_DIR" -name '*.blend' | sort | head -1 || true)"
  fi
fi
[ -n "${BLEND:-}" ] && [ -f "$BLEND" ] || { echo "ERROR: .blend not found in scene zip"; exit 1; }
echo "== blend: $BLEND"

# ---- 3. Render the chunk (animation range; marker cameras applied) ----
"$BLENDER_BIN" -b "$BLEND" \
  --python "$SCRIPT_DIR/bind_cameras.py" \
  -o "$OUT_DIR/frame_" -F PNG \
  -s "$FRAME_START" -e "$FRAME_END" -a

# ---- 4. Verify the chunk is complete ----
EXPECTED=$((FRAME_END - FRAME_START + 1))
GOT=0
for n in $(seq "$FRAME_START" "$FRAME_END"); do
  f="$(printf '%s/frame_%04d.png' "$OUT_DIR" "$n")"
  if [ -s "$f" ]; then GOT=$((GOT + 1)); else echo "MISSING/EMPTY: $f"; fi
done
echo "== frames rendered: $GOT / $EXPECTED"
[ "$GOT" -eq "$EXPECTED" ] || { echo "ERROR: incomplete chunk"; exit 1; }
FIRST="$(printf '%s/frame_%04d.png' "$OUT_DIR" "$FRAME_START")"
sha256sum "$FIRST" || true
echo "== render_chunk DONE"
