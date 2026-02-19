trap 'echo "[pipeline] ERROR on line $LINENO. Last command: $BASH_COMMAND" >&2' ERR

#!/usr/bin/env bash
set -euo pipefail

# Keep memory predictable
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1

IMAGES_DIR="$1"
OUT_DIR="$2"

mkdir -p "$OUT_DIR"

DB_PATH="$OUT_DIR/colmap.db"
SPARSE_DIR="$OUT_DIR/sparse"
UNDIST_DIR="$OUT_DIR/undistorted"
MVS_DIR="$OUT_DIR/openmvs"

mkdir -p "$SPARSE_DIR" "$UNDIST_DIR" "$MVS_DIR"

echo "[pipeline] images: $IMAGES_DIR"
echo "[pipeline] out:    $OUT_DIR"

# Remove any non-image files (e.g., metadata.json) so COLMAP doesn't try to read them
find "$IMAGES_DIR" -maxdepth 1 -type f ! \( -iname "*.jpg" -o -iname "*.jpeg" \) -print -delete || true

IMG_COUNT=$(find "$IMAGES_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) | wc -l | tr -d ' ')
echo "[pipeline] image count: $IMG_COUNT"
if [ "$IMG_COUNT" -lt 20 ]; then
  echo "[pipeline] Not enough images ($IMG_COUNT). Need at least 20."
  exit 2
fi

# --- knobs ---
MAX_IMG_SIZE="${MAX_IMG_SIZE:-800}"
RES_LEVEL="${OPENMVS_RES_LEVEL:-4}"
SKIP_DENSE="${SKIP_DENSE:-1}"          # default to 1 to avoid OOM until we upgrade memory
SEQ_OVERLAP="${SEQ_OVERLAP:-8}"
SEQ_LOOP_DETECT="${SEQ_LOOP_DETECT:-0}"   # keep 0 (loop detection needs vocab tree)
echo "[pipeline] MAX_IMG_SIZE=$MAX_IMG_SIZE OPENMVS_RES_LEVEL=$RES_LEVEL SKIP_DENSE=$SKIP_DENSE"
echo "[pipeline] SEQ_OVERLAP=$SEQ_OVERLAP SEQ_LOOP_DETECT=$SEQ_LOOP_DETECT"

# Locate OpenMVS binaries (don't rely on PATH)
OPENMVS_BIN="${OPENMVS_BIN:-/opt/openmvs/bin}"
echo "[pipeline] OPENMVS_BIN=$OPENMVS_BIN"
ls -la "$OPENMVS_BIN" | head -n 120 || true

INTERFACE_COLMAP="$OPENMVS_BIN/InterfaceCOLMAP"
DENSIFY="$OPENMVS_BIN/DensifyPointCloud"
RECON_MESH="$OPENMVS_BIN/ReconstructMesh"
REFINE_MESH="$OPENMVS_BIN/RefineMesh"
TEXTURE_MESH="$OPENMVS_BIN/TextureMesh"

# Run OpenMVS tools with a private LD_LIBRARY_PATH so COLMAP is never affected
run_openmvs () {
  LD_LIBRARY_PATH="/opt/openmvs/lib:${LD_LIBRARY_PATH:-}" "$@"
}

if ! command -v colmap >/dev/null 2>&1; then
  echo "[pipeline] ERROR: colmap not found on PATH"
  echo "[pipeline] PATH=$PATH"
  exit 20
fi

if [ ! -x "$INTERFACE_COLMAP" ]; then
  echo "[pipeline] ERROR: InterfaceCOLMAP not found/executable at $INTERFACE_COLMAP"
  echo "[pipeline] Searching under /opt for InterfaceCOLMAP..."
  find /opt -maxdepth 6 -type f -name "InterfaceCOLMAP" -print || true
  exit 10
fi

if [ ! -x "$RECON_MESH" ]; then
  echo "[pipeline] ERROR: ReconstructMesh not found/executable at $RECON_MESH"
  find /opt -maxdepth 6 -type f -name "ReconstructMesh" -print || true
  exit 11
fi

# 1) COLMAP sparse (CPU)
echo "[pipeline] colmap feature_extractor..."
colmap feature_extractor \
  --database_path "$DB_PATH" \
  --image_path "$IMAGES_DIR" \
  --ImageReader.single_camera 1 \
  --SiftExtraction.max_image_size "$MAX_IMG_SIZE" \
  --SiftExtraction.num_threads 1 \
  --SiftExtraction.peak_threshold 0.02 \
  --SiftExtraction.use_gpu 0

echo "[pipeline] colmap sequential_matcher..."
colmap sequential_matcher \
  --database_path "$DB_PATH" \
  --SiftMatching.use_gpu 0 \
  --SequentialMatching.overlap "$SEQ_OVERLAP" \
  --SequentialMatching.loop_detection "$SEQ_LOOP_DETECT"

echo "[pipeline] colmap mapper..."
colmap mapper \
  --database_path "$DB_PATH" \
  --image_path "$IMAGES_DIR" \
  --output_path "$SPARSE_DIR"

MODEL_DIR="$SPARSE_DIR/0"
if [ ! -d "$MODEL_DIR" ]; then
  echo "[pipeline] No sparse model produced (expected $MODEL_DIR)."
  exit 3
fi

# 2) Undistort images for OpenMVS
echo "[pipeline] colmap image_undistorter..."
colmap image_undistorter \
  --image_path "$IMAGES_DIR" \
  --input_path "$MODEL_DIR" \
  --output_path "$UNDIST_DIR" \
  --output_type COLMAP

# 3) Convert COLMAP -> OpenMVS scene
echo "[pipeline] OpenMVS InterfaceCOLMAP..."
run_openmvs "$INTERFACE_COLMAP" \
  -i "$UNDIST_DIR" \
  -o "$MVS_DIR/scene.mvs" \
  -w "$MVS_DIR"

# LOW-MEMORY MODE (default):
# Skip densify (biggest RAM hog). Attempt a coarse mesh directly.
if [ "$SKIP_DENSE" = "1" ]; then
  echo "[pipeline] SKIP_DENSE=1 -> attempting coarse mesh from scene.mvs"

  run_openmvs "$RECON_MESH" \
    "$MVS_DIR/scene.mvs" \
    -w "$MVS_DIR"

  # OpenMVS naming varies by build; grab first produced PLY
  if [ -f "$MVS_DIR/scene_mesh.ply" ]; then
    cp "$MVS_DIR/scene_mesh.ply" "$OUT_DIR/mesh.ply"
    echo "[pipeline] done -> $OUT_DIR/mesh.ply (scene_mesh.ply)"
    exit 0
  fi

  MESH_CANDIDATE="$(ls -1 "$MVS_DIR"/*.ply 2>/dev/null | head -n 1 || true)"
  if [ -n "$MESH_CANDIDATE" ]; then
    cp "$MESH_CANDIDATE" "$OUT_DIR/mesh.ply"
    echo "[pipeline] done -> $OUT_DIR/mesh.ply ($(basename "$MESH_CANDIDATE"))"
    exit 0
  fi

  echo "[pipeline] SKIP_DENSE=1 but no mesh PLY produced"
  ls -la "$MVS_DIR" || true
  exit 4
fi

# 4) Densify point cloud (higher RAM) — only if enabled
if [ ! -x "$DENSIFY" ]; then
  echo "[pipeline] ERROR: DensifyPointCloud not found/executable at $DENSIFY"
  find /opt -maxdepth 6 -type f -name "DensifyPointCloud" -print || true
  exit 12
fi

echo "[pipeline] OpenMVS DensifyPointCloud..."
run_openmvs "$DENSIFY" \
  "$MVS_DIR/scene.mvs" \
  -w "$MVS_DIR" \
  --resolution-level "$RES_LEVEL"

# 5) Mesh
echo "[pipeline] OpenMVS ReconstructMesh..."
run_openmvs "$RECON_MESH" \
  "$MVS_DIR/scene_dense.mvs" \
  -w "$MVS_DIR"

if [ ! -f "$MVS_DIR/scene_dense_mesh.ply" ]; then
  echo "[pipeline] Expected mesh not found: $MVS_DIR/scene_dense_mesh.ply"
  ls -la "$MVS_DIR" || true
  exit 5
fi

cp "$MVS_DIR/scene_dense_mesh.ply" "$OUT_DIR/mesh.ply"
echo "[pipeline] done -> $OUT_DIR/mesh.ply"
