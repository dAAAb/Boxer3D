"""Compare PyTorch vs CoreML at each stage of the wrapper forward to localize
where outputs diverge.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

ROOT = Path(__file__).parent.resolve()
sys.path.insert(0, str(ROOT / "boxer-src"))

from boxernet.boxernet import BoxerNet  # noqa: E402
from wrapper import BoxerNetTensorOnly  # noqa: E402


class StageWrapper(nn.Module):
    """Outputs several intermediate tensors so we can see where PyTorch and
    CoreML start disagreeing."""

    def __init__(self, w: BoxerNetTensorOnly):
        super().__init__()
        self.w = w

    def forward(self, img, sdp_median, ray_enc, bb2d_norm):
        w = self.w
        B = 1
        dino_feat = w.dino(img)
        dino_feat = dino_feat.reshape(B, -1, w.num_patches).permute(0, 2, 1)
        sdp_input = sdp_median.reshape(B, -1, w.num_patches).permute(0, 2, 1)
        x = torch.cat([dino_feat, sdp_input], dim=-1)
        x = torch.cat([x, ray_enc], dim=-1)
        enc = w.input2emb(x)
        enc = w.self_attn(enc)
        q0 = w.query2emb(bb2d_norm)      # stage A
        q1 = w.cross_attn(q0, enc)       # stage B
        h = w.ale_net(q1)                # stage C
        mu = w.mean_head(h)              # stage D
        return q0, q1, h, mu, enc


def main():
    import coremltools as ct

    ckpt = ROOT / "boxer-src" / "ckpts" / "boxernet_hw960in4x6d768-wssxpf9p.ckpt"
    boxer = BoxerNet.load_from_checkpoint(str(ckpt), device="cpu")
    boxer.eval()
    wrapper = BoxerNetTensorOnly(boxer).eval()
    stages = StageWrapper(wrapper).eval()

    torch.manual_seed(0)
    img = torch.rand(1, 3, 960, 960)
    sdp = torch.rand(1, 1, 60, 60) * 3.0
    ray = torch.randn(1, 3600, 6)
    bb2d = torch.tensor(
        [[[0.15, 0.55, 0.12, 0.58], [0.30, 0.80, 0.25, 0.75], [0.05, 0.45, 0.50, 0.95]]]
    )

    with torch.no_grad():
        q0_pt, q1_pt, h_pt, mu_pt, enc_pt = stages(img, sdp, ray, bb2d)

    print("Tracing stage wrapper…")
    with torch.no_grad():
        traced = torch.jit.trace(stages, (img, sdp, ray, bb2d), strict=False)

    print("Converting…")
    ml = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="image", shape=img.shape),
            ct.TensorType(name="sdp_median", shape=sdp.shape),
            ct.TensorType(name="ray_enc", shape=ray.shape),
            ct.TensorType(name="bb2d_norm", shape=bb2d.shape),
        ],
        outputs=[
            ct.TensorType(name="q0"),
            ct.TensorType(name="q1"),
            ct.TensorType(name="h"),
            ct.TensorType(name="mu"),
            ct.TensorType(name="enc"),
        ],
        convert_to="mlprogram",
        compute_units=ct.ComputeUnit.CPU_ONLY,
        compute_precision=ct.precision.FLOAT32,  # isolate trace bug from fp16 loss
        minimum_deployment_target=ct.target.iOS17,
    )

    out = ml.predict({
        "image": img.numpy(),
        "sdp_median": sdp.numpy(),
        "ray_enc": ray.numpy(),
        "bb2d_norm": bb2d.numpy(),
    })

    def diff(name, pt, cm):
        d = np.abs(pt - cm).max()
        pt_rows_same = (pt[0] == pt[0, :1]).all() if pt.ndim >= 2 else False
        cm_rows_same = (cm[0] == cm[0, :1]).all() if cm.ndim >= 2 else False
        print(f"{name:>6}  shape {pt.shape}  max|Δ|={d:.4f}  PT-collapsed={pt_rows_same}  CM-collapsed={cm_rows_same}")

    diff("q0",  q0_pt.numpy(),  np.asarray(out["q0"]))
    diff("q1",  q1_pt.numpy(),  np.asarray(out["q1"]))
    diff("h",   h_pt.numpy(),   np.asarray(out["h"]))
    diff("mu",  mu_pt.numpy(),  np.asarray(out["mu"]))
    diff("enc", enc_pt.numpy(), np.asarray(out["enc"]))


if __name__ == "__main__":
    main()
