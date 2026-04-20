#!/bin/bash
# Download only the BoxerNet + DINOv3 checkpoints we need (skip OWLv2,
# which is a 2D detector we don't use — iOS side uses yolo11n).
set -e

DIR="$(dirname "$0")/boxer-src/ckpts"
BASE_URL="https://huggingface.co/facebook/boxer/resolve/main"

FILES=(
  "boxernet_hw960in4x6d768-wssxpf9p.ckpt"
  "dinov3_vits16plus_pretrain_lvd1689m-4057cbaa.pth"
)

mkdir -p "$DIR"
for f in "${FILES[@]}"; do
  if [ -f "$DIR/$f" ]; then
    echo "Already exists: $DIR/$f"
    continue
  fi
  echo "Downloading $f ..."
  curl -L --progress-bar -o "$DIR/$f" "$BASE_URL/$f"
done
echo "Done → $DIR"
