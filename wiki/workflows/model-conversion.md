---
title: BoxerNet → CoreML conversion
updated: 2026-04-23
source: convert/
---

# Model conversion

Convert the upstream PyTorch BoxerNet checkpoint to a native CoreML
`.mlpackage` that ships in the app. Source of truth:
[`convert/README.md`](../../convert/README.md).

## When to run this

- Porting a new BoxerNet checkpoint upstream.
- Changing `numBoxes` (see [static-num-boxes.md](../concepts/static-num-boxes.md)).
- Changing `imageSize` (default 480, half of the paper's 960).

Otherwise the existing `boxer/BoxerNetModel.mlpackage` in the repo is
fine — don't re-run unnecessarily.

## Inputs

- Python 3.11 + [uv](https://github.com/astral-sh/uv).
- GitHub clone of `facebookresearch/boxer` (CC-BY-NC-4.0).
- Meta BoxerNet + DINOv3 checkpoints (download via
  `convert/download_ckpts.sh`).

## Pipeline

```bash
cd convert
git clone --depth 1 https://github.com/facebookresearch/boxer.git boxer-src
uv venv --python 3.11 .venv
source .venv/bin/activate
uv pip install -r requirements.txt
./download_ckpts.sh

python convert.py --precision fp32          # MANDATORY fp32 — see gotchas
python quantize_weights.py                   # optional: int8 weights, 97 MB
python verify.py BoxerNet_int8w.mlpackage    # sanity check vs PyTorch
```

Artefacts land in `convert/output/`. Drag the `.mlpackage` into the Xcode
`boxer/` folder.

## File map (convert/)

| File | Purpose |
|---|---|
| `download_ckpts.sh` | Fetch Boxer + DINOv3 weights. |
| `wrapper.py` | `BoxerNetTensorOnly` — strips dict-plumbed camera/pose inputs into 4 plain tensors. Monkey-patches `F.scaled_dot_product_attention` to explicit form. |
| `convert.py` | PyTorch → coremltools trace → `.mlpackage`. |
| `quantize_weights.py` | Post-training weight-only int8 quant (reduces 200 MB → 97 MB). |
| `verify.py` | Runs both models on a fixed input; reports per-tensor max diff. |
| `debug_stages.py` | Per-layer shape / dtype dump for debugging a broken conversion. |
| `bench.py` | Rough latency numbers on the mac (not representative of ANE perf, but catches regressions). |

## Dead ends to avoid

See `convert/README.md` for the authoritative list. Summary:

- **ONNX → CoreML** via `coremltools.convert` fails: `Size`,
  `Clip`-with-dynamic-bounds, `FusedMatMul` unsupported. Trace from
  PyTorch directly instead.
- **fp16 at conversion** (`--precision fp16`): softmax over 3600 tokens
  saturates → all rows identical → boxes collapse to one centre.
- **int8 weight quant**: accuracy drifts up to ~22 cm / ~13°. Acceptable
  for an AR preview, re-evaluate if the user reports wobble.
- **Fused SDPA op**: didn't trace under coremltools 9. `wrapper.py`
  replaces with the explicit `softmax(QK^T/√d)V` form.

## Licensing reminder

BoxerNet weights are **CC-BY-NC-4.0** (Meta Reality Labs). The resulting
`.mlpackage` is therefore non-commercial only. This repo ships neither
the weights nor the facebookresearch/boxer source — both are fetched at
setup time.

If you change the BoxerNet architecture or train your own checkpoint,
that obligation goes away (the code is MIT) but the CC-BY-NC applies to
the weights you downloaded.

## Related

- [coreml-native.md](../concepts/coreml-native.md) — why we went native
  for BoxerNet and not YOLO.
- [static-num-boxes.md](../concepts/static-num-boxes.md) — what the
  baked-in `numBoxes` means for the runtime.
- [gotchas.md](../gotchas.md#fp16-softmax-collapse) — the fp16 trap
  in more detail.
