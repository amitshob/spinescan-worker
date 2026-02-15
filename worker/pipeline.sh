#!/usr/bin/env bash
set -euo pipefail
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

# 1) COLMAP sparse (CPU)
echo "[pipeline] colmap feature_extractor..."
colmap feature_extractor \
  --database_path "$DB_PATH" \
  --image_path "$IMAGES_DIR" \
  --ImageReader.single_camera 1 \
  --SiftExtraction.max_image_size 1024 \
  --SiftExtraction.use_gpu 0

echo "[pipeline] colmap exhaustive_matcher..."
colmap exhaustive_matcher \
  --database_path "$DB_PATH" \
  --SiftMatching.use_gpu 0

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

# 4) Densify point cloud (speed-first)
# resolution-level: higher = faster/rougher. Start at 2.
echo "[pipeline] OpenMVS DensifyPointCloud..."
DensifyPointCloud \
  "$MVS_DIR/scene.mvs" \
  -w "$MVS_DIR" \
  --resolution-level 3

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
