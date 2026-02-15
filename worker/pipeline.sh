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

IMG_COUNT=$(find "$IMAGES_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) | wc -l | tr -d ' ')
echo "[pipeline] image count: $IMG_COUNT"
if [ "$IMG_COUNT" -lt 20 ]; then
  echo "[pipeline] Not enough images ($IMG_COUNT). Need at least 20."
  exit 2
fi

# --- knobs ---
MAX_IMG_SIZE="${MAX_IMG_SIZE:-800}"              # reduce memory
RES_LEVEL="${OPENMVS_RES_LEVEL:-4}"              # higher = lower memory, rougher
SKIP_DENSE="${SKIP_DENSE:-0}"                    # set to 1 to skip densify (low-memory mode)
echo "[pipeline] MAX_IMG_SIZE=$MAX_IMG_SIZE OPENMVS_RES_LEVEL=$RES_LEVEL SKIP_DENSE=$SKIP_DENSE"

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
  --SequentialMatching.overlap 8 \
  --SequentialMatching.loop_detection 0

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
InterfaceCOLMAP \
  -i "$UNDIST_DIR" \
  -o "$MVS_DIR/scene.mvs" \
  -w "$MVS_DIR"

# LOW-MEMORY MODE:
# Skip DensifyPointCloud (biggest RAM hog). Try to reconstruct a coarse mesh directly from scene.mvs.
if [ "$SKIP_DENSE" = "1" ]; then
  echo "[pipeline] SKIP_DENSE=1 -> skipping DensifyPointCloud, attempting coarse mesh from scene.mvs"

  ReconstructMesh \
    "$MVS_DIR/scene.mvs" \
    -w "$MVS_DIR"

  # Common OpenMVS output names vary. Prefer scene_mesh.ply.
  if [ -f "$MVS_DIR/scene_mesh.ply" ]; then
    cp "$MVS_DIR/scene_mesh.ply" "$OUT_DIR/mesh.ply"
    echo "[pipeline] done -> $OUT_DIR/mesh.ply (coarse mesh: scene_mesh.ply)"
    exit 0
  fi

  # Otherwise, grab any .ply produced (best-effort)
  MESH_CANDIDATE=$(ls -1 "$MVS_DIR"/*.ply 2>/dev/null | head -n 1 || true)
  if [ -n "$MESH_CANDIDATE" ]; then
    cp "$MESH_CANDIDATE" "$OUT_DIR/mesh.ply"
    echo "[pipeline] done -> $OUT_DIR/mesh.ply (coarse mesh: $(basename "$MESH_CANDIDATE"))"
    exit 0
  fi

  echo "[pipeline] SKIP_DENSE=1 but no mesh PLY produced"
  ls -la "$MVS_DIR" || true
  exit 4
fi

# 4) Densify point cloud (higher RAM)
echo "[pipeline] OpenMVS DensifyPointCloud..."
DensifyPointCloud \
  "$MVS_DIR/scene.mvs" \
  -w "$MVS_DIR" \
  --resolution-level "$RES_LEVEL"

# 5) Mesh
echo "[pipeline] OpenMVS ReconstructMesh..."
ReconstructMesh \
  "$MVS_DIR/scene_dense.mvs" \
  -w "$MVS_DIR"

if [ ! -f "$MVS_DIR/scene_dense_mesh.ply" ]; then
  echo "[pipeline] Expected mesh not found: $MVS_DIR/scene_dense_mesh.ply"
  ls -la "$MVS_DIR" || true
  exit 4
fi

cp "$MVS_DIR/scene_dense_mesh.ply" "$OUT_DIR/mesh.ply"
echo "[pipeline] done -> $OUT_DIR/mesh.ply"
