"""Sanity-check: run CoreML mlpackage vs PyTorch wrapper on same inputs."""

from __future__ import annotations

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
    import coremltools as ct

    import sys as _sys
    mlpackage = ROOT / "output" / (_sys.argv[1] if len(_sys.argv) > 1 else "BoxerNet.mlpackage")
    ckpt = ROOT / "boxer-src" / "ckpts" / "boxernet_hw960in4x6d768-wssxpf9p.ckpt"

    print("Loading PyTorch BoxerNet…")
    boxer = BoxerNet.load_from_checkpoint(str(ckpt), device="cpu")
    boxer.eval()
    wrapper = BoxerNetTensorOnly(boxer).eval()

    print("Loading CoreML mlpackage…")
    mlmodel = ct.models.MLModel(str(mlpackage), compute_units=ct.ComputeUnit.CPU_ONLY)

    torch.manual_seed(0)
    img = torch.rand(1, 3, 960, 960)
    sdp = torch.rand(1, 1, 60, 60) * 3.0  # depth in metres
    ray = torch.randn(1, 3600, 6)
    bb2d = torch.tensor(
        [[[0.15, 0.55, 0.12, 0.58], [0.30, 0.80, 0.25, 0.75], [0.05, 0.45, 0.50, 0.95]]]
    )

    with torch.no_grad():
        pt_params, pt_prob = wrapper(img, sdp, ray, bb2d)

    cm_out = mlmodel.predict(
        {
            "image": img.numpy(),
            "sdp_median": sdp.numpy(),
            "ray_enc": ray.numpy(),
            "bb2d_norm": bb2d.numpy(),
        }
    )
    # CoreML flattens tuple outputs; keys follow output names in convert.py.
    cm_params = np.asarray(cm_out["params"])
    cm_prob = np.asarray(cm_out["prob"])

    p_diff = np.abs(pt_params.numpy() - cm_params).max()
    q_diff = np.abs(pt_prob.numpy() - cm_prob).max()
    print(f"Params  max|PT - CoreML|: {p_diff:.5f}")
    print(f"Prob    max|PT - CoreML|: {q_diff:.5f}")
    print()
    print("PyTorch params:\n", pt_params[0].numpy())
    print("CoreML  params:\n", cm_params[0])

    tol = float(os.environ.get("TOL", "5e-3"))
    print(f"\nTolerance {tol}; params Δ={p_diff:.4f}, prob Δ={q_diff:.4f}")
    if p_diff < tol and q_diff < tol:
        print("OK.")
    else:
        print("DIVERGED (might still be acceptable for quantized weights).")


if __name__ == "__main__":
    main()
