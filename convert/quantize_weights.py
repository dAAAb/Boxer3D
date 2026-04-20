"""Post-quantize the fp32 BoxerNet mlpackage weights to int8.

Keeps compute precision at fp32 (so softmax stays numerically stable) while
cutting weight storage ~4× (383 MB → ~96 MB). Linear symmetric int8 is the
coremltools default and is usually accurate enough for transformer inference.
"""

from pathlib import Path

import coremltools as ct
from coremltools.optimize.coreml import (
    OpLinearQuantizerConfig,
    OptimizationConfig,
    linear_quantize_weights,
)

ROOT = Path(__file__).parent.resolve()
SRC = ROOT / "output" / "BoxerNet.mlpackage"
DST = ROOT / "output" / "BoxerNet_int8w.mlpackage"


def main():
    print(f"Loading {SRC}")
    model = ct.models.MLModel(str(SRC))
    cfg = OptimizationConfig(
        global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"),
    )
    print("Quantizing weights → int8")
    q = linear_quantize_weights(model, config=cfg)
    q.save(str(DST))
    print(f"Wrote {DST}")


if __name__ == "__main__":
    main()
