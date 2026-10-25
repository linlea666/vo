# Vo Player

一款给苹果电脑（Apple 芯片 M1/M2/M3/M4）用的视频播放器，重点是**画面修复**：昏暗、夜景、噪点多的视频，可以实时调亮，也可以用本地 AI 修复一次后保存，以后打开直接播放修复版，不重复处理。

## 功能

- **几乎所有格式**：mp4、mov、m4v、mkv、avi、flv、webm、wmv、ts、rmvb 等（libmpv / FFmpeg 内核，硬件解码）
- **循环**：单个视频循环（⌘L）、A-B 段循环（⌘B：第一次设 A 点，第二次设 B 点，第三次取消）
- **画面旋转 / 翻转**：顺时针 ⌘R、逆时针 ⌘⇧R、水平/垂直翻转；按视频记住
- **实时修复**（免费、零等待、不改原文件）：亮度、对比度、伽马（暗部提亮）、饱和度、降噪、锐化，以及“昏暗修复”“强力提亮”等一键预设；按住“对比原画”看效果
- **AI 暗光修复（本地）**：Zero-DCE++ 模型在本机运行，免费、视频不上传；处理后保存为新的 mp4（HEVC，保留原音轨）
- **修复结果缓存**：按视频内容“指纹”识别（改名、移动也认得），同一视频同一参数只处理一次；再次打开自动提示/播放修复版，顶部一键切换 原片 ⇄ 修复版
- 其他：拖拽打开、最近打开、倍速、逐帧、截图到桌面、全屏

## 安装

1. 到仓库的 **Actions → Build DMG** 最新一次成功运行，下载 `VoPlayer-dmg`（或在 Releases 页下载）。
2. 打开 DMG，把 VoPlayer 拖进“应用程序”。
3. **第一次打开**（因为没有付费开发者签名，只需做一次）：
   - 在“应用程序”里右键点 VoPlayer → 打开 → 再点“打开”；
   - macOS 15 起如果没有“打开”按钮：系统设置 → 隐私与安全性 → 下方点“仍要打开”；
   - 或者在“终端”执行：`xattr -cr /Applications/VoPlayer.app`

想设为默认播放器：在访达里选中一个视频 → ⌘I 显示简介 → “打开方式”选 Vo Player → “全部更改”。

## 修复说明

| 方式 | 费用 | 速度 | 适合 |
| --- | --- | --- | --- |
| 实时修复 | 免费 | 立即生效 | 稍暗、偏灰、噪点，所有格式 |
| AI 暗光修复（本地） | 免费 | 预计约为视频时长的 1～3 倍（1080p，待实测） | 很暗的夜景、室内、逆光；目前支持 mp4 / mov / m4v |

- AI 修复结果默认保存在 `~/Library/Application Support/VoPlayer/Enhanced/`，也可以在修复面板里选择“保存到原视频旁边”。
- 偏好设置（⌘,）里可以查看占用空间、删除单个或全部修复版。
- AI 修复对“暗”效果明显；严重模糊、马赛克只能有限改善。
- 云端 AI（花额度的那种）留到下一阶段，缓存机制已经为它准备好（提交后立刻记下任务 ID，断网重开会继续取结果，不会重复提交）。

## 开发

工程用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成：

```bash
brew install xcodegen
xcodegen generate
open VoPlayer.xcodeproj
```

- `VoPlayer/`：应用（SwiftUI + AppKit）。`Player/` 播放内核封装与状态，`UI/` 界面，`Enhance/` AI 导出。
- `Packages/VoCore/`：与界面无关的核心逻辑（视频指纹、修复缓存、画面参数、Zero-DCE++ 推理），`swift test --package-path Packages/VoCore` 运行测试。
- `scripts/export_zero_dce.py`：从官方 PyTorch 权重导出模型文件和测试参考数据（无需安装 PyTorch）。
- `scripts/make_dmg.sh`：打包 DMG。
- CI：`.github/workflows/build-dmg.yml` 在 macOS 上测试、编译、打包；推送 `v*` 标签时自动发布 Release。

## 许可与致谢

- 播放内核：[mpv](https://mpv.io) / [MPVKit](https://github.com/mpvkit/MPVKit)（LGPL 版本）、FFmpeg。
- AI 模型：Zero-DCE++（Li, Guo, Loy, *Learning to Enhance Low-Light Image via Zero-Reference Deep Curve Estimation*, TPAMI 2021），权重来自 [Li-Chongyi/Zero-DCE_extension](https://github.com/Li-Chongyi/Zero-DCE_extension)。原仓库未声明开源许可，仅供个人学习使用。
