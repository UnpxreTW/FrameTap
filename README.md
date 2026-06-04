# FrameTap

原生 macOS 影片抽幀工具——**不需 ffmpeg、零外部相依**。

`FrameTap` 只用 Apple 的 **AVFoundation** 框架與 Xcode 內建的 Swift 工具鏈，把影片
（`.mp4` / `.mov`、H.264 / HEVC）轉成一連串 PNG / JPEG 影格。它是為了把影格餵給 LLM
視覺模型而做的（例如逐格逆向 UI 動畫）——這件大家通常為了它而拖進整個 ffmpeg 的窄差事。

## 為什麼

「影片 → 影格」的業界標準是 `ffmpeg`，但你其實只用到它的一個 filter（`-vf fps=N`）。在
macOS 上，`AVAssetImageGenerator` 原生就能做同一件事，而且抽幀時間**精確**（zero
tolerance、不 snap 到 keyframe），免安裝、免 Homebrew、免 40 MB 二進位檔。

取捨：AVFoundation 解 H.264 / HEVC（多數平台、包含 X / Twitter 給的就是這個），但
**不解 VP9 / webm**。那類來源請改用 ffmpeg。

## 安裝

從 [Releases](../../releases) 下載二進位檔，或從原始碼編譯：

```bash
git clone https://github.com/UnpxreTW/FrameTap.git
cd FrameTap
swift build -c release
cp .build/release/frametap /usr/local/bin/   # 或任何在 $PATH 上的位置
```

需要 macOS 13 以上。

## 用法

```bash
frametap <影片> [選項]
```

```bash
# 在 0:02–0:03 區間以 60fps 抽 60 幀（精確檢視 easing）
frametap clip.mp4 --start 0:02 --end 0:03 --fps 60

# 整支影片、512px 寬 PNG，輸出到 ./clip-frames/
frametap clip.mp4
```

| 選項 | 預設 | 說明 |
| --- | --- | --- |
| `--start <S>` | `0` | `S` / `MM:SS` / `HH:MM:SS` |
| `--end <S>` | 影片結尾 | |
| `--fps <N>` | `30` | 每秒目標影格數 |
| `--max-frames <N>` | `100` | 硬上限；超過時自動降 fps 均勻鋪滿 |
| `--width <PX>` | `512` | 輸出寬度、高度依比例自動 |
| `--format <fmt>` | `png` | `png` 或 `jpg` |
| `--quality <0-1>` | `0.9` | 僅 jpg |
| `--out <DIR>` | `<影片>-frames` | 輸出目錄 |
| `-h`, `--help` | | 顯示說明 |

影格命名為 `frame_%04d_t<秒>.<副檔名>`、時間戳對齊**原始影片**時間軸；工具會把影格路徑
以 markdown 清單印到 stdout，方便 agent 依序讀取。
