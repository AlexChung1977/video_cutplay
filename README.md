# CutPlay

Mac 影片剪輯 MVP：用自然語言選段、粗剪、匯出。分析與助理預設都在本機進行。

介面為繁體中文。目標使用者是一般創作者，不是專業剪輯師。

## 架構

| 模組 | 內容 |
|------|------|
| `CutPlayCore` | 時間軸模型、分析索引、`EditPlan`、自動套用政策、規則／LLM 規劃器、聊天 session、專案檔 |
| `CutPlayMedia` | ffprobe 匯入、FFmpeg 代理檔、停頓／場景偵測、whisper.cpp 逐字稿、分析管線 |
| `CutPlayApp` | macOS 14+ SwiftUI：媒體庫、預覽、可調寬逐字稿、時間軸、側邊 AI 助理 |

設計文件（產品決策）在專案 store，不在這個 repo。實作對齊：

- 右側聊天面板（不是指令列）
- 「信心高時直接套用」checkbox（預設關閉）
- 逐字稿是輔助面板，可調寬、可收合
- 時間軸預設：影片、聲音、逐字稿、場景

## 在 Linux 上（這個雲端環境）

無法編譯／執行 SwiftUI 介面，但核心與媒體層可以測：

```bash
swift test
```

`CutPlayApp` 在非 macOS 上只是一支說明用 stub。

## 在 Mac 上

需要：macOS 14+、Xcode 15+ 或 Swift 5.10+、`ffmpeg` / `ffprobe`（Homebrew：`brew install ffmpeg`）。

逐字稿可選：安裝 [whisper.cpp](https://github.com/ggerganov/whisper.cpp) 的 `whisper-cli`，把 ggml 模型放到 `~/Library/Application Support/CutPlay/models/`，或設 `CUTPLAY_WHISPER_MODEL`。沒有模型時仍可剪輯，只是沒有逐字稿搜尋。

```bash
swift test
swift run CutPlayApp
```

進階指令可交給本機 OpenAI-compatible 伺服器（Ollama / LM Studio）或雲端 API（只傳文字索引，不傳影片），在 App 設定裡切換。內建規則規劃器離線就能處理「刪掉停頓」「挑出講到 ○○ 的段落」等指令。

## 專案檔

`.cutplay/` 目錄：`project.json`、`index.json`、`chat.json`、`cache/`（代理檔，可刪除後重建）。
