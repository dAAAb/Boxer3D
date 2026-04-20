"""Rough inference-time benchmark on Mac. Not the same as iPhone CoreML, but
shows the single-graph CoreML path vs ONNX Runtime's partitioned one.
"""

import sys
import time
from pathlib import Path

import numpy as np
import coremltools as ct

ROOT = Path(__file__).parent.resolve()


def bench(mlpath, compute_units, warmup=3, trials=10):
    model = ct.models.MLModel(str(mlpath), compute_units=compute_units)
    img = np.random.rand(1, 3, 960, 960).astype(np.float32)
    sdp = (np.random.rand(1, 1, 60, 60) * 3.0).astype(np.float32)
    ray = np.random.randn(1, 3600, 6).astype(np.float32)
    bb2d = np.array([[[0.1, 0.5, 0.1, 0.5],
                      [0.2, 0.6, 0.2, 0.6],
                      [0.3, 0.7, 0.3, 0.7]]], dtype=np.float32)
    inputs = dict(image=img, sdp_median=sdp, ray_enc=ray, bb2d_norm=bb2d)

    for _ in range(warmup):
        model.predict(inputs)
    t0 = time.perf_counter()
    for _ in range(trials):
        model.predict(inputs)
    dt = (time.perf_counter() - t0) / trials * 1000
    print(f"  {compute_units!r:>30}  →  {dt:6.1f} ms / inference")
    return dt


def main():
    mlpath = ROOT / "output" / (sys.argv[1] if len(sys.argv) > 1 else "BoxerNet_int8w.mlpackage")
    print(f"Model: {mlpath.name}  ({mlpath.stat().st_size / 1e6:.0f} MB on disk)\n")
    bench(mlpath, ct.ComputeUnit.CPU_ONLY)
    bench(mlpath, ct.ComputeUnit.CPU_AND_GPU)
    try:
        bench(mlpath, ct.ComputeUnit.ALL)  # includes ANE when available
    except Exception as e:
        print(f"  ALL (ANE) failed: {e}")


if __name__ == "__main__":
    main()
