"""Convert BoxerNet PyTorch source → native CoreML .mlpackage.

Steps:
  1. Load BoxerNet from HuggingFace checkpoint (via facebook/boxer repo).
  2. Wrap in a tensor-only forward (see wrapper.py).
  3. Run once on dummy inputs to sanity-check shapes.
  4. torch.jit.trace → coremltools.convert.
  5. Save to output/BoxerNet.mlpackage.

Run:
  uv pip install -r requirements.txt
  bash boxer-src/scripts/download_ckpts.sh     # writes boxer-src/ckpts/
  python convert.py
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).parent.resolve()
sys.path.insert(0, str(ROOT / "boxer-src"))

from boxernet.boxernet import BoxerNet  # noqa: E402

from wrapper import BoxerNetTensorOnly  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt-dir", default=str(ROOT / "boxer-src" / "ckpts"))
    ap.add_argument("--out", default=str(ROOT / "output" / "BoxerNet.mlpackage"))
    ap.add_argument("--precision", choices=["fp32", "fp16"], default="fp16")
    ap.add_argument(
        "--compute-units",
        choices=["cpuOnly", "cpuAndGPU", "all"],
        default="cpuAndGPU",
        help="ANE often OOMs on 200MB+ models; cpuAndGPU is the safe default.",
    )
    ap.add_argument("--skip-save", action="store_true", help="stop before saving (for debugging)")
    ap.add_argument(
        "--image-size",
        type=int,
        default=480,
        help="Square input edge length in pixels. Must be divisible by 16 (DINOv3 patch).",
    )
    args = ap.parse_args()
    if args.image_size % 16 != 0:
        sys.exit(f"--image-size must be divisible by 16; got {args.image_size}")
    grid = args.image_size // 16
    n_tokens = grid * grid

    ckpt_dir = Path(args.ckpt_dir)
    boxer_ckpt = ckpt_dir / "boxernet_hw960in4x6d768-wssxpf9p.ckpt"
    if not boxer_ckpt.exists():
        sys.exit(
            f"Missing checkpoint: {boxer_ckpt}\n"
            f"Run: bash {ROOT / 'boxer-src' / 'scripts' / 'download_ckpts.sh'}"
        )

    # BoxerNet code reads DINOv3 weights from demo_utils.CKPT_PATH (hardcoded
    # relative to repo). The download script writes to boxer-src/ckpts/, which is
    # exactly where demo_utils.CKPT_PATH already points, so no override needed.

    print(f"[1/5] Loading BoxerNet from {boxer_ckpt}")
    boxer = BoxerNet.load_from_checkpoint(str(boxer_ckpt), device="cpu")
    boxer.eval()

    wrapper = BoxerNetTensorOnly(boxer, image_size=args.image_size).eval()

    print(f"[2/5] Sanity-checking wrapper forward at {args.image_size}x{args.image_size} ({n_tokens} tokens)")
    img = torch.rand(1, 3, args.image_size, args.image_size)
    sdp = torch.rand(1, 1, grid, grid)
    ray = torch.rand(1, n_tokens, 6)
    bb2d = torch.tensor(
        [[[0.1, 0.5, 0.1, 0.5], [0.2, 0.6, 0.2, 0.6], [0.3, 0.7, 0.3, 0.7]]]
    )

    with torch.no_grad():
        params, prob = wrapper(img, sdp, ray, bb2d)
    print(f"      params: {tuple(params.shape)}, prob: {tuple(prob.shape)}")
    assert params.shape == (1, 3, 7) and prob.shape == (1, 3)

    print("[3/5] Tracing with torch.jit.trace")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (img, sdp, ray, bb2d), strict=False)

    if args.skip_save:
        print("--skip-save set, exiting before CoreML conversion")
        return

    print("[4/5] Converting to CoreML (this can take several minutes)")
    import coremltools as ct

    compute_units = {
        "cpuOnly": ct.ComputeUnit.CPU_ONLY,
        "cpuAndGPU": ct.ComputeUnit.CPU_AND_GPU,
        "all": ct.ComputeUnit.ALL,
    }[args.compute_units]
    precision = (
        ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32
    )

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="image", shape=img.shape, dtype=np.float32),
            ct.TensorType(name="sdp_median", shape=sdp.shape, dtype=np.float32),
            ct.TensorType(name="ray_enc", shape=ray.shape, dtype=np.float32),
            ct.TensorType(name="bb2d_norm", shape=bb2d.shape, dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="params"),
            ct.TensorType(name="prob"),
        ],
        compute_units=compute_units,
        compute_precision=precision,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
    )

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    print(f"[5/5] Saving to {out}")
    mlmodel.save(str(out))
    print("Done.")


if __name__ == "__main__":
    main()
