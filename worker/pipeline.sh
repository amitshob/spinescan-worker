#!/usr/bin/env bash
set -euo pipefail

IMAGES_DIR="$1"
OUT_DIR="$2"

mkdir -p "$OUT_DIR"

# Working dirs
DB_DIR="$OUT_DIR/colmap_db"
SPARSE_DIR="$OUT_DIR/sparse"
DENSE_DIR="$OUT_DIR/dense"
MVS_DIR="$OUT_DIR/mvs"

mkdir -p "$SPARSE_DIR" "$DENSE_DIR" "$MVS_DIR"

# 1) COLMAP: feature extraction + matching + mapping
colmap feature_extractor \
  --database_path "$DB_DIR.db" \
  --image_path "$IMAGES_DIR" \
  --ImageReader.single_camera 1

colmap exhaustive_matcher \
  --database_path "$DB_DIR.db"

colmap mapper \
  --database_path "$DB_DIR.db" \
  --image_path "$IMAGES_DIR" \
  --output_path "$SPARSE_DIR"

# pick first model folder (0)
MODEL_DIR="$SPARSE_DIR/0"

# 2) COLMAP: dense preparation + stereo + fusion
colmap image_undistorter \
  --image_path "$IMAGES_DIR" \
  --input_path "$MODEL_DIR" \
  --output_path "$DENSE_DIR" \
  --output_type COLMAP

colmap patch_match_stereo \
  --workspace_path "$DENSE_DIR" \
  --workspace_format COLMAP \
  --PatchMatchStereo.geom_consistency true

colmap stereo_fusion \
  --workspace_path "$DENSE_DIR" \
  --workspace_format COLMAP \
  --input_type geometric \
  --output_path "$OUT_DIR/fused.ply"

# 3) Mesh: Poisson (fast-ish, no texture)
colmap poisson_mesher \
  --input_path "$OUT_DIR/fused.ply" \
  --output_path "$OUT_DIR/mesh.ply"

