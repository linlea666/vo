#!/usr/bin/env python3
"""用 WebSR 的“真人实拍”权重生成 mpv 可用的 Anime4K 着色器。

Anime4K 官方 GLSL 着色器（https://github.com/bloc97/Anime4K，MIT）用动漫训练；
WebSR（https://github.com/sb2702/websr，MIT）的作者用同一网络结构在真人实拍素材上
重新训练了权重（cnn-2x-{s,m,l}-rl.json）。两者网络结构完全一致，JSON 里每层的
weights 正好是官方 GLSL 中该层 `mat4(...)` 常量的顺序拼接，bias 对应末尾的 `vec4(...)`。

所以做法是：拿官方 GLSL 当模板，逐层把常量换成 JSON 里的数值，其余代码原样保留。

自检：先用 WebSR 里与官方相同的动漫权重（*-an.json）替换，结果必须与官方着色器的
数值逐个一致，才说明对应关系正确；再输出真人版。

用法：
    python3 scripts/convert_anime4k.py <Anime4K 仓库目录> <websr 仓库目录>
输出：
    VoPlayer/Resources/Shaders/ 下的 .glsl 文件
"""

import json
import re
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT_DIR = REPO / "VoPlayer/Resources/Shaders"

NUMBER = r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?"
MAT4 = re.compile(r"mat4\(([^()]*)\)")
BIAS = re.compile(r"result \+= vec4\(([^()]*)\);")


def split_passes(text):
    """按 //!DESC 切成若干段，第一段是许可声明等头部。"""
    parts = re.split(r"(?=^//!DESC )", text, flags=re.M)
    return parts[0], parts[1:]


def pass_save_name(chunk):
    m = re.search(r"^//!SAVE (\S+)", chunk, flags=re.M)
    return m.group(1) if m else None


def fmt(v):
    s = repr(float(v))
    return s[:-2] if s.endswith(".0") and "e" not in s else s


def substitute(template_text, layers, check_only=False):
    """把模板中各卷积层的常量换成 layers 里的数值。check_only 时只比对不替换。"""
    header, passes = split_passes(template_text)
    out = [header]
    convs_seen = 0
    for chunk in passes:
        name = pass_save_name(chunk)
        layer = layers.get(name) if name else None
        if layer is None or layer.get("type") != "conv":
            out.append(chunk)
            continue
        convs_seen += 1
        weights = layer["weights"]
        bias = layer["bias"]
        mats = MAT4.findall(chunk)
        if len(mats) * 16 != len(weights):
            raise ValueError(f"{name}: 模板有 {len(mats)} 个 mat4，权重有 {len(weights)} 个数")
        bias_match = BIAS.findall(chunk)
        if len(bias_match) != 1 or len(bias) != 4:
            raise ValueError(f"{name}: 偏置数量不符")

        if check_only:
            tmpl = [float(x) for m in mats for x in re.findall(NUMBER, m)]
            tmpl_bias = [float(x) for x in re.findall(NUMBER, bias_match[0])]
            worst = max(abs(a - b) for a, b in zip(tmpl + tmpl_bias, list(weights) + list(bias)))
            if worst > 1e-6:
                raise ValueError(f"{name}: 与官方数值不一致（最大差 {worst}）")
            out.append(chunk)
            continue

        it = iter(weights)

        def repl_mat(_m):
            return "mat4(" + ", ".join(fmt(next(it)) for _ in range(16)) + ")"

        chunk = MAT4.sub(repl_mat, chunk)
        chunk = BIAS.sub(lambda _m: "result += vec4(" + ", ".join(fmt(b) for b in bias) + ");", chunk)
        out.append(chunk)

    expected = sum(1 for v in layers.values() if v.get("type") == "conv")
    if convs_seen != expected:
        raise ValueError(f"模板里匹配到 {convs_seen} 个卷积层，JSON 有 {expected} 个")
    return "".join(out)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    a4k, websr = Path(sys.argv[1]), Path(sys.argv[2])
    weights_dir = websr / "weights/anime4k"
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # WebSR 的 s/m/l 分别对应官方的这几个着色器（见 websr/weights/anime4k/README.md；
    # m 对应训练模板生成的 tensorflow/Upscale_Shader.glsl，由自检确认）
    templates = {
        "S": "glsl/Upscale/Anime4K_Upscale_CNN_x2_S.glsl",
        "M": "tensorflow/Upscale_Shader.glsl",
        "L": "glsl/Upscale/Anime4K_Upscale_CNN_x2_VL.glsl",
    }
    for size, template_path in templates.items():
        template = (a4k / template_path).read_text()
        an = json.loads((weights_dir / f"cnn-2x-{size.lower()}-an.json").read_text())["layers"]
        rl = json.loads((weights_dir / f"cnn-2x-{size.lower()}-rl.json").read_text())["layers"]

        substitute(template, an, check_only=True)  # 自检：对应关系正确
        text = substitute(template, rl)
        text = re.sub(r"^//!DESC ", "//!DESC RealLife-", text, flags=re.M)
        note = (f"// Network: Anime4K CNN x2 ({template_path}), Copyright (c) 2019-2021 bloc97, MIT License\n"
                "// Weights: WebSR real-life retrain (https://github.com/sb2702/websr, MIT,\n"
                "// Copyright (c) Sam Bhattacharyya), converted by scripts/convert_anime4k.py\n\n")
        out = OUT_DIR / f"Upscale_RealLife_x2_{size}.glsl"
        out.write_text(note + text)
        print(f"wrote {out.relative_to(REPO)} (self-check against official anime weights passed)")

    # 去模糊/去压缩痕迹：官方 Restore（Soft 版本对真人素材更温和），原样复制
    for size in ["S", "M", "L"]:
        src = a4k / f"glsl/Restore/Anime4K_Restore_CNN_Soft_{size}.glsl"
        dst = OUT_DIR / f"Restore_Soft_{size}.glsl"
        shutil.copyfile(src, dst)
        print(f"copied {dst.relative_to(REPO)}")
    shutil.copyfile(a4k / "glsl/Restore/Anime4K_Clamp_Highlights.glsl", OUT_DIR / "Clamp_Highlights.glsl")
    shutil.copyfile(a4k / "LICENSE", OUT_DIR / "LICENSE-Anime4K.txt")


if __name__ == "__main__":
    main()
