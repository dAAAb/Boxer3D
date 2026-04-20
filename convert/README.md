# BoxerNet → native CoreML

Convert BoxerNet from its PyTorch source
([facebookresearch/boxer](https://github.com/facebookresearch/boxer),
CC-BY-NC-4.0) to a native CoreML `.mlpackage`, avoiding the ONNX→CoreML
dead ends (unsupported `Size`/`Clip`-with-dynamic-bounds/`FusedMatMul`).

## Why

With `ONNXRuntime + CoreML EP` the graph fragments into 136 partitions
with 211 CPU-fallback nodes, duplicating the model in memory (ORT + CoreML
compiled cache) and forcing GPU↔CPU bridging at every boundary.

Native `.mlpackage` gives CoreML the whole graph, single copy, full-graph
optimization.

## Run

```bash
git clone --depth 1 https://github.com/facebookresearch/boxer.git boxer-src
uv venv --python 3.11 .venv
source .venv/bin/activate
uv pip install -r requirements.txt
./download_ckpts.sh                  # BoxerNet + DINOv3 weights → boxer-src/ckpts/
python convert.py --precision fp32   # fp16 compute causes softmax collapse
python quantize_weights.py           # post-quantize → int8 weights, 97 MB
python verify.py BoxerNet_int8w.mlpackage  # outputs vs PyTorch
```

## Design

`BoxerNetTensorOnly` (`wrapper.py`) strips the camera/pose dict plumbing
and takes four plain tensors:

| Input        | Shape            | Produced by (Swift side)                  |
|--------------|------------------|--------------------------------------------|
| `image`      | (1, 3, 960, 960) | Center-crop + resize of ARKit frame        |
| `sdp_median` | (1, 1, 60, 60)   | Median LiDAR depth per 16×16 patch         |
| `ray_enc`    | (1, 3600, 6)     | Plücker encoding per patch in voxel frame  |
| `bb2d_norm`  | (1, 3, 4)        | YOLO boxes in xmin/xmax/ymin/ymax, [0,1]   |

Outputs `params: (1, 3, 7) = (cx, cy, cz, w, h, d, yaw)` in voxel frame +
`prob: (1, 3)`. Swift applies `T_world_voxel` to get world-frame OBBs.

## Known quirks

- **fp16 compute collapses queries** — softmax over 3600 tokens saturates
  in fp16 (all rows output the same value). `--precision fp32` required.
- **int8 weight quantization** — `params` diverge by up to ~22 cm / ~13°
  vs fp32; fine for AR scan, re-evaluate if detection gets wobbly.
- **`F.scaled_dot_product_attention` is monkey-patched** (`wrapper.py`)
  to the explicit `softmax(QK^T/√d)V` form — the fused op didn't trace
  cleanly under coremltools 9.

## License

This directory ships no model weights or facebookresearch/boxer code;
both are fetched at setup time. Weights are under CC-BY-NC-4.0 (Meta),
so mlpackage use is **non-commercial only**.
