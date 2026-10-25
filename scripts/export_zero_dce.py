#!/usr/bin/env python3
"""把 Zero-DCE++ 的 PyTorch 权重导出成 VoPlayer 使用的二进制文件，并生成测试用参考输出。

不依赖 PyTorch：.pth（zip 格式）里的张量直接用 pickle + numpy 读出。

用法：
    python3 scripts/export_zero_dce.py <Epoch99.pth>

权重来源：https://github.com/Li-Chongyi/Zero-DCE_extension
（Zero-DCE++/snapshots_Zero_DCE++/Epoch99.pth）

输出：
    Packages/VoCore/Sources/VoCore/Resources/zero_dce_pp.bin
        头部 8 字节 b"ZDCEPP01"，随后按顺序存放 float32 小端：
        e_conv1..e_conv7，每层依次为
          depth_conv.weight [C,1,3,3]  depth_conv.bias [C]
          point_conv.weight [O,C,1,1]  point_conv.bias [O]
    Packages/VoCore/Tests/VoCoreTests/Resources/zero_dce_reference.json
        固定输入（由公式生成，Swift 测试里用同样的公式重建）对应的参考输出。

参考实现与 VoCore/ZeroDCE.swift 的约定一致：
    下采样：按整数倍做区域平均（边缘不足一块时只平均实际像素）
    曲线参数估计：7 层深度可分离卷积（与原论文网络相同）
    上采样：双线性，align_corners=True（与原网络的 UpsamplingBilinear2d 相同）
    增强：x = x + r * (x^2 - x)，迭代 8 次
"""

import json
import pickle
import struct
import sys
import zipfile
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
WEIGHTS_OUT = REPO / "Packages/VoCore/Sources/VoCore/Resources/zero_dce_pp.bin"
FIXTURE_OUT = REPO / "Packages/VoCore/Tests/VoCoreTests/Resources/zero_dce_reference.json"

LAYERS = [(3, 32), (32, 32), (32, 32), (32, 32), (64, 32), (64, 32), (64, 3)]


# ---------- 读取 .pth（不依赖 torch） ----------

def load_state_dict(path):
    zf = zipfile.ZipFile(path)
    names = zf.namelist()
    prefix = names[0].split("/")[0]
    storages = {}

    def load_storage(key, dtype):
        if key not in storages:
            raw = zf.read(f"{prefix}/data/{key}")
            storages[key] = np.frombuffer(raw, dtype=dtype)
        return storages[key]

    class FloatStorage:
        dtype = np.float32

    def rebuild_tensor_v2(storage, offset, size, stride, *args):
        arr = np.lib.stride_tricks.as_strided(
            storage[offset:], shape=size, strides=[s * storage.itemsize for s in stride]
        )
        return np.array(arr, dtype=np.float32)

    class Unpickler(pickle.Unpickler):
        def find_class(self, module, name):
            if module == "torch._utils" and name == "_rebuild_tensor_v2":
                return rebuild_tensor_v2
            if module == "torch" and name == "FloatStorage":
                return FloatStorage
            if module == "collections" and name == "OrderedDict":
                import collections
                return collections.OrderedDict
            raise pickle.UnpicklingError(f"unsupported {module}.{name}")

        def persistent_load(self, pid):
            # ('storage', storage_type, key, location, numel)
            _, storage_type, key, _location, _numel = pid
            return load_storage(key, storage_type.dtype)

    with zf.open(f"{prefix}/data.pkl") as f:
        return Unpickler(f).load()


def ordered_weights(state):
    out = []
    for i, (cin, cout) in enumerate(LAYERS, start=1):
        dw = state[f"e_conv{i}.depth_conv.weight"]
        db = state[f"e_conv{i}.depth_conv.bias"]
        pw = state[f"e_conv{i}.point_conv.weight"]
        pb = state[f"e_conv{i}.point_conv.bias"]
        assert dw.shape == (cin, 1, 3, 3), dw.shape
        assert db.shape == (cin,), db.shape
        assert pw.shape == (cout, cin, 1, 1), pw.shape
        assert pb.shape == (cout,), pb.shape
        out.append((dw.reshape(cin, 9), db, pw.reshape(cout, cin), pb))
    return out


# ---------- 参考实现 ----------

def downsample_area(x, factor):
    c, h, w = x.shape
    lh, lw = -(-h // factor), -(-w // factor)
    out = np.zeros((c, lh, lw), dtype=np.float64)
    for i in range(lh):
        for j in range(lw):
            block = x[:, i * factor:(i + 1) * factor, j * factor:(j + 1) * factor]
            out[:, i, j] = block.mean(axis=(1, 2))
    return out


def depthwise3x3(x, w, b):
    c, h, wd = x.shape
    padded = np.pad(x, ((0, 0), (1, 1), (1, 1)))
    out = np.zeros_like(x)
    for k in range(9):
        dy, dx = divmod(k, 3)
        out += w[:, k][:, None, None] * padded[:, dy:dy + h, dx:dx + wd]
    return out + b[:, None, None]


def pointwise(x, w, b):
    c, h, wd = x.shape
    return (w @ x.reshape(c, -1)).reshape(-1, h, wd) + b[:, None, None]


def estimate_curves(x_low, weights):
    def layer(i, inp):
        dw, db, pw, pb = weights[i]
        return pointwise(depthwise3x3(inp, dw, db), pw, pb)

    relu = lambda v: np.maximum(v, 0)
    x1 = relu(layer(0, x_low))
    x2 = relu(layer(1, x1))
    x3 = relu(layer(2, x2))
    x4 = relu(layer(3, x3))
    x5 = relu(layer(4, np.concatenate([x3, x4])))
    x6 = relu(layer(5, np.concatenate([x2, x5])))
    return np.tanh(layer(6, np.concatenate([x1, x6])))


def upsample_bilinear_align_corners(x, h, w):
    c, lh, lw = x.shape

    def coords(n_out, n_in):
        if n_out == 1 or n_in == 1:
            return np.zeros(n_out)
        return np.arange(n_out) * (n_in - 1) / (n_out - 1)

    ys, xs = coords(h, lh), coords(w, lw)
    y0 = np.floor(ys).astype(int); y1 = np.minimum(y0 + 1, lh - 1); fy = ys - y0
    x0 = np.floor(xs).astype(int); x1 = np.minimum(x0 + 1, lw - 1); fx = xs - x0
    top = x[:, y0][:, :, x0] * (1 - fx) + x[:, y0][:, :, x1] * fx
    bottom = x[:, y1][:, :, x0] * (1 - fx) + x[:, y1][:, :, x1] * fx
    return top * (1 - fy)[None, :, None] + bottom * fy[None, :, None]


def enhance(x, weights, factor):
    curves = estimate_curves(downsample_area(x, factor), weights)
    r = upsample_bilinear_align_corners(curves, x.shape[1], x.shape[2])
    for _ in range(8):
        x = x + r * (x * x - x)
    return x


def fixture_input(h, w):
    """与 Swift 测试中的 ZeroDCETests.fixtureInput 公式完全一致。"""
    x = np.zeros((3, h, w), dtype=np.float64)
    for c in range(3):
        for i in range(h):
            for j in range(w):
                x[c, i, j] = 0.02 + 0.3 * (((i * 7 + j * 13 + c * 29) % 97) / 97.0)
    return x


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    weights = ordered_weights(load_state_dict(sys.argv[1]))

    WEIGHTS_OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(WEIGHTS_OUT, "wb") as f:
        f.write(b"ZDCEPP01")
        for dw, db, pw, pb in weights:
            for arr in (dw, db, pw, pb):
                f.write(np.ascontiguousarray(arr, dtype="<f4").tobytes())
    print(f"wrote {WEIGHTS_OUT} ({WEIGHTS_OUT.stat().st_size} bytes)")

    weights64 = [tuple(a.astype(np.float64) for a in layer) for layer in weights]
    h, w, factor = 30, 44, 4
    x = fixture_input(h, w)
    curves = estimate_curves(downsample_area(x, factor), weights64)
    out = enhance(x, weights64, factor)
    FIXTURE_OUT.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE_OUT.write_text(json.dumps({
        "height": h, "width": w, "factor": factor,
        "curves_shape": list(curves.shape),
        "curves": [round(float(v), 6) for v in curves.reshape(-1)],
        "output": [round(float(v), 6) for v in out.reshape(-1)],
    }))
    print(f"wrote {FIXTURE_OUT}; output mean {out.mean():.4f} (input mean {x.mean():.4f})")


if __name__ == "__main__":
    main()
