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

# --- knobs ---
MAX_IMG_SIZE="${MAX_IMG_SIZE:-640}"
SEQ_OVERLAP="${SEQ_OVERLAP:-6}"
SEQ_LOOP_DETECT="${SEQ_LOOP_DETECT:-0}"
RES_LEVEL="${OPENMVS_RES_LEVEL:-4}"
SKIP_DENSE="${SKIP_DENSE:-1}"   # keep 1 for now to avoid OOM on small instances
OPENMVS_BIN="${OPENMVS_BIN:-/opt/openmvs/bin/OpenMVS}"

echo "[pipeline] MAX_IMG_SIZE=$MAX_IMG_SIZE OPENMVS_RES_LEVEL=$RES_LEVEL SKIP_DENSE=$SKIP_DENSE"
echo "[pipeline] SEQ_OVERLAP=$SEQ_OVERLAP SEQ_LOOP_DETECT=$SEQ_LOOP_DETECT"
echo "[pipeline] OPENMVS_BIN=$OPENMVS_BIN"

# Ensure tools exist
command -v colmap >/dev/null 2>&1 || { echo "[pipeline] ERROR: colmap not found in PATH"; exit 11; }
test -x "$OPENMVS_BIN/InterfaceCOLMAP" || { echo "[pipeline] ERROR: InterfaceCOLMAP missing at $OPENMVS_BIN/InterfaceCOLMAP"; exit 10; }

# Run OpenMVS tools with their private libs ONLY for those commands
run_openmvs () {
  LD_LIBRARY_PATH="/opt/openmvs/lib:${LD_LIBRARY_PATH:-}" "$@"
}

# Count only jpg/jpeg (ignore metadata.json and others)
IMG_COUNT=$(find "$IMAGES_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) | wc -l | tr -d ' ')
echo "[pipeline] image count: $IMG_COUNT"
if [ "$IMG_COUNT" -lt 40 ]; then
  echo "[pipeline] Not enough images ($IMG_COUNT). Need at least 40."
  exit 2
fi

# 1) Feature extraction (CPU, memory-capped)
echo "[pipeline] colmap feature_extractor..."
colmap feature_extractor \
  --database_path "$DB_PATH" \
  --image_path "$IMAGES_DIR" \
  --ImageReader.single_camera 1 \
  --SiftExtraction.use_gpu 0 \
  --SiftExtraction.num_threads 1 \
  --SiftExtraction.max_image_size "$MAX_IMG_SIZE" \
  --SiftExtraction.max_num_features 2500 \
  --SiftExtraction.peak_threshold 0.03

# 2) Sequential matching (CPU) - loop detection OFF to avoid visual index issues
echo "[pipeline] colmap sequential_matcher..."
colmap sequential_matcher \
  --database_path "$DB_PATH" \
  --SiftMatching.use_gpu 0 \
  --SequentialMatching.overlap "$SEQ_OVERLAP" \
  --SequentialMatching.loop_detection "$SEQ_LOOP_DETECT"

# 3) Sparse reconstruction
echo "[pipeline] colmap mapper..."
colmap mapper \
  --database_path "$DB_PATH" \
  --image_path "$IMAGES_DIR" \
  --output_path "$SPARSE_DIR"

MODEL_DIR="$SPARSE_DIR/0"
if [ ! -d "$MODEL_DIR" ]; then
  echo "[pipeline] No sparse model produced (expected $MODEL_DIR)."
  find "$SPARSE_DIR" -maxdepth 2 -type f || true
  exit 3
fi

# Optional sanity: approximate registered image count via TXT export of MODEL_DIR
TMP_TXT="$OUT_DIR/model_txt"
rm -rf "$TMP_TXT" || true
mkdir -p "$TMP_TXT"
colmap model_converter --input_path "$MODEL_DIR" --output_path "$TMP_TXT" --output_type TXT >/dev/null 2>&1 || true
REG_IMAGES=$(grep -E "^[0-9]+ " "$TMP_TXT/images.txt" 2>/dev/null | wc -l | tr -d ' ')
echo "[pipeline] registered images (approx): ${REG_IMAGES:-unknown}"

# 4) Undistort for OpenMVS
echo "[pipeline] colmap image_undistorter..."
colmap image_undistorter \
  --image_path "$IMAGES_DIR" \
  --input_path "$MODEL_DIR" \
  --output_path "$UNDIST_DIR" \
  --output_type COLMAP

if [ ! -d "$UNDIST_DIR/images" ]; then
  echo "[pipeline] ERROR: undistorted images folder missing: $UNDIST_DIR/images"
  find "$UNDIST_DIR" -maxdepth 2 -type d -print
  exit 13
fi

# 5) Convert the UNDISTORTED sparse model (not the original) to TXT for InterfaceCOLMAP.
#    image_undistorter writes a binary sparse model to $UNDIST_DIR/sparse/; we need TXT.
#    FIX: previously this converted from MODEL_DIR (original distorted model) which gave
#    InterfaceCOLMAP mismatched camera intrinsics. Now we convert from $UNDIST_DIR/sparse.
echo "[pipeline] ensure undistorted sparse TXT exists for InterfaceCOLMAP..."

UNDIST_SPARSE="$UNDIST_DIR/sparse"
mkdir -p "$UNDIST_SPARSE"

if [ ! -f "$UNDIST_SPARSE/cameras.txt" ]; then
  # Check if the undistorter produced a binary model we can convert
  if [ -f "$UNDIST_SPARSE/cameras.bin" ]; then
    echo "[pipeline] converting undistorted binary model -> TXT"
    colmap model_converter \
      --input_path "$UNDIST_SPARSE" \
      --output_path "$UNDIST_SPARSE" \
      --output_type TXT
  else
    # Fallback: undistorter did not write a sparse folder at all (older COLMAP versions).
    # Export from MODEL_DIR as a last resort, with a clear warning.
    echo "[pipeline] WARNING: $UNDIST_SPARSE/cameras.bin not found; falling back to original MODEL_DIR for TXT export."
    echo "[pipeline] Camera intrinsics may not exactly match undistorted images."
    colmap model_converter \
      --input_path "$MODEL_DIR" \
      --output_path "$UNDIST_SPARSE" \
      --output_type TXT
  fi
fi

if [ ! -f "$UNDIST_SPARSE/cameras.txt" ]; then
  echo "[pipeline] ERROR: still missing $UNDIST_SPARSE/cameras.txt after conversion attempts"
  find "$UNDIST_SPARSE" -maxdepth 2 -type f | head -n 200 || true
  exit 12
fi

echo "[pipeline] debug: first 40 lines cameras.txt"
head -n 40 "$UNDIST_SPARSE/cameras.txt" || true

echo "[pipeline] debug: first 60 lines images.txt"
head -n 60 "$UNDIST_SPARSE/images.txt" || true

echo "[pipeline] debug: count image header lines"
grep -E "^[0-9]+ " "$UNDIST_SPARSE/images.txt" | wc -l || true

# Check points3D.txt is present and non-trivial; warn if empty as it will hurt densification.
POINT_COUNT=$(grep -c -E "^[0-9]+" "$UNDIST_SPARSE/points3D.txt" 2>/dev/null || echo "0")
echo "[pipeline] points3D count: $POINT_COUNT"
if [ "$POINT_COUNT" -eq 0 ]; then
  echo "[pipeline] WARNING: points3D.txt is empty. Dense reconstruction may be lower quality."
fi

# 6) Convert COLMAP -> OpenMVS
#    -i must point to the directory containing images/ and sparse/ (with TXT files).
echo "[pipeline] OpenMVS InterfaceCOLMAP..."
run_openmvs "$OPENMVS_BIN/InterfaceCOLMAP" \
  -i "$UNDIST_DIR" \
  -o "$MVS_DIR/scene.mvs" \
  -w "$MVS_DIR"

# Ultra-low-memory MVP: stop here and output sparse point cloud (NOT a mesh)
if [ "$SKIP_DENSE" = "1" ]; then
  echo "[pipeline] SKIP_DENSE=1 -> exporting sparse model as PLY point cloud"
  colmap model_converter \
    --input_path "$MODEL_DIR" \
    --output_path "$OUT_DIR/mesh.ply" \
    --output_type PLY
  echo "[pipeline] done -> $OUT_DIR/mesh.ply (sparse point cloud)"
  exit 0
fi

# 7) Dense + Mesh (may OOM on small plans)
echo "[pipeline] OpenMVS DensifyPointCloud..."
run_openmvs "$OPENMVS_BIN/DensifyPointCloud" \
  "$MVS_DIR/scene.mvs" \
  -w "$MVS_DIR" \
  --resolution-level "$RES_LEVEL"

echo "[pipeline] OpenMVS ReconstructMesh..."
run_openmvs "$OPENMVS_BIN/ReconstructMesh" \
  "$MVS_DIR/scene_dense.mvs" \
  -w "$MVS_DIR"

if [ ! -f "$MVS_DIR/scene_dense_mesh.ply" ]; then
  echo "[pipeline] Expected mesh not found: $MVS_DIR/scene_dense_mesh.ply"
  ls -la "$MVS_DIR" || true
  exit 4
fi

cp "$MVS_DIR/scene_dense_mesh.ply" "$OUT_DIR/mesh.ply"
echo "[pipeline] done -> $OUT_DIR/mesh.ply"
