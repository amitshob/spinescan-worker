#!/usr/bin/env bash
set -euo pipefail

IMAGES_DIR="$1"
OUT_DIR="$2"

mkdir -p "$OUT_DIR"

DB_PATH="$OUT_DIR/colmap.db"
SPARSE_DIR="$OUT_DIR/sparse"
DENSE_DIR="$OUT_DIR/dense"

mkdir -p "$SPARSE_DIR" "$DENSE_DIR"

echo "[pipeline] images: $IMAGES_DIR"
echo "[pipeline] out:    $OUT_DIR"

# 0) Basic sanity
IMG_COUNT=$(find "$IMAGES_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) | wc -l | tr -d ' ')
if [ "$IMG_COUNT" -lt 20 ]; then
  echo "[pipeline] Not enough images ($IMG_COUNT). Need at least 20."
  exit 2
fi

# 1) COLMAP sparse reconstruction
colmap feature_extractor \
  --database_path "$DB_PATH" \
  --image_path "$IMAGES_DIR" \
  --ImageReader.single_camera 1 \
  --SiftExtraction.max_image_size 1600 \
  --SiftExtraction.use_gpu 0

colmap exhaustive_matcher \
  --database_path "$DB_PATH" \
  --SiftMatching.use_gpu 0

echo "[pipeline] mapper..."
colmap mapper \
  --database_path "$DB_PATH" \
  --image_path "$IMAGES_DIR" \
  --output_path "$SPARSE_DIR"

MODEL_DIR="$SPARSE_DIR/0"
if [ ! -d "$MODEL_DIR" ]; then
  echo "[pipeline] No sparse model produced (expected $MODEL_DIR)."
  exit 3
fi

# 2) Dense reconstruction prep
echo "[pipeline] image_undistorter..."
colmap image_undistorter \
  --image_path "$IMAGES_DIR" \
  --input_path "$MODEL_DIR" \
  --output_path "$DENSE_DIR" \
  --output_type COLMAP

# 3) Dense stereo + fusion
echo "[pipeline] patch_match_stereo..."
colmap patch_match_stereo \
  --workspace_path "$DENSE_DIR" \
  --workspace_format COLMAP \
  --PatchMatchStereo.geom_consistency true \
  --PatchMatchStereo.max_image_size 1600

echo "[pipeline] stereo_fusion..."
colmap stereo_fusion \
  --workspace_path "$DENSE_DIR" \
  --workspace_format COLMAP \
  --input_type geometric \
  --output_path "$OUT_DIR/fused.ply"

# 4) Mesh (Poisson)
echo "[pipeline] poisson_mesher..."
colmap poisson_mesher \
  --input_path "$OUT_DIR/fused.ply" \
  --output_path "$OUT_DIR/mesh.ply"

echo "[pipeline] done -> $OUT_DIR/mesh.ply"
