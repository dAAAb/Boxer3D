"""Tensor-only wrapper around BoxerNet for CoreML conversion.

The reference model expects a dict with camera / pose / world-transform objects
(CameraTW, PoseTW) that aren't traceable. We move the SDP patch rendering and
Plücker ray encoding to the Swift side and feed them as precomputed tensors,
so the mlpackage's forward() is pure tensor ops: image + sdp + rays + 2D boxes.
"""

from __future__ import annotations

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F


# coremltools 9 has known bugs collapsing queries when tracing
# `F.scaled_dot_product_attention` (the fused op). Replace it with the explicit
# softmax(QK^T/√d)V form before loading the model, so trace sees only primitive
# ops CoreML converts cleanly.
def _sdpa_math(q, k, v, attn_mask=None, dropout_p=0.0, is_causal=False, scale=None, **kw):
    d = q.size(-1)
    s = (1.0 / (d ** 0.5)) if scale is None else scale
    scores = (q @ k.transpose(-2, -1)) * s
    if attn_mask is not None:
        scores = scores + attn_mask
    return scores.softmax(dim=-1) @ v


F.scaled_dot_product_attention = _sdpa_math
torch.nn.functional.scaled_dot_product_attention = _sdpa_math


class BoxerNetTensorOnly(nn.Module):
    def __init__(self, boxer):
        super().__init__()
        self.dino = boxer.dino
        self.input2emb = boxer.input2emb
        self.self_attn = boxer.self_attn
        self.query2emb = boxer.query2emb
        self.cross_attn = boxer.cross_attn
        self.ale_net = boxer.head.net
        self.mean_head = boxer.head.mean_head
        self.logvar_head = boxer.head.logvar_head

        self.bbox_min = float(boxer.head.bbox_min)
        self.bbox_max = float(boxer.head.bbox_max)
        self.min_dim = float(boxer.head.min_dim)
        self.yaw_max = float(np.pi / 2)

        # Static shapes — 480 input, 16-px patches → 30×30 = 900 tokens.
        # DINOv3 RoPE is computed per-forward from H, W so arbitrary multiples
        # of the patch size work without architectural changes; accuracy may
        # drift vs. the 960-trained checkpoint until fine-tuned.
        self.fH = 30
        self.fW = 30
        self.num_patches = self.fH * self.fW

    def forward(self, img, sdp_median, ray_enc, bb2d_norm):
        """
        Args:
          img:        (1, 3, 960, 960) float, values in [0, 1]
          sdp_median: (1, 1, 60, 60)   float, median voxel-frame z per patch (-1 = invalid)
          ray_enc:    (1, 3600, 6)     float, Plücker (d, m) in voxel frame
          bb2d_norm:  (1, 3, 4)        float, [xmin, xmax, ymin, ymax] normalized to [0, 1]
        Returns:
          params: (1, 3, 7) center_xyz(voxel) + size_whd(m) + yaw(rad)
          prob:   (1, 3)    confidence = 1 / (1 + exp(logvar))
        """
        B = 1

        # DINOv3 — (1, 384, 60, 60)
        dino_feat = self.dino(img)
        dino_feat = dino_feat.reshape(B, -1, self.num_patches).permute(0, 2, 1)

        sdp_input = sdp_median.reshape(B, -1, self.num_patches).permute(0, 2, 1)
        x = torch.cat([dino_feat, sdp_input], dim=-1)
        x = torch.cat([x, ray_enc], dim=-1)

        enc = self.input2emb(x)
        enc = self.self_attn(enc)

        q = self.query2emb(bb2d_norm)
        q = self.cross_attn(q, enc)

        h = self.ale_net(q)
        mu = self.mean_head(h)
        logvar = torch.clamp(self.logvar_head(h), -10.0, 3.0)

        center = mu[..., :3]
        size = torch.sigmoid(mu[..., 3:6]) * (self.bbox_max - self.bbox_min) + self.bbox_min
        size = torch.clamp(size, min=self.min_dim)
        yaw = self.yaw_max * torch.tanh(mu[..., 6:7])

        params = torch.cat([center, size, yaw], dim=-1)
        prob = 1.0 / (1.0 + torch.exp(logvar.squeeze(-1)))

        return params, prob
