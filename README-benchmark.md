# LM Studio 自動化 Benchmark

這套腳本會一次完成兩件事：

- 能力評測：使用 `lm-eval` 跑任務並彙整成 `quality_metrics.csv`
- 效能評測：使用 LM Studio `POST /api/v1/chat` 收集 `TTFT/TPS`，輸出 `perf_raw.csv` 與 `perf_summary.csv`

## 1) 準備設定檔

1. 複製範例設定檔：

```powershell
Copy-Item .\benchmark-config.example.json .\benchmark-config.json
```

2. 編輯 `benchmark-config.json`：

- `models`：要批次跑的模型清單
- `quality.tasks`：`lm-eval` 任務
- `performance.prompts`：效能測試用 prompt
- `lmstudio.apiBase` / `lmstudio.openaiBaseUrl`：LM Studio URL

## 2) 啟動 LM Studio

- 請先確認 LM Studio server 已啟動
- 若有開 API Token，請先設定環境變數（名稱要跟 `apiTokenEnv` 一致）

```powershell
$env:LMSTUDIO_API_TOKEN = "<你的 token>"
```

## 3) 執行 benchmark

```powershell
.\run-lmstudio-benchmark.ps1
```

可用參數：

- 只跑能力：

```powershell
.\run-lmstudio-benchmark.ps1 -SkipPerformance
```

- 只跑效能：

```powershell
.\run-lmstudio-benchmark.ps1 -SkipQuality
```

- 指定設定檔與輸出資料夾：

```powershell
.\run-lmstudio-benchmark.ps1 -ConfigPath .\benchmark-config.json -OutputRoot .\results
```

- 啟用編碼偵錯（可確認中文 prompt 是否正確送出）：

```powershell
.\run-lmstudio-benchmark.ps1 -SkipQuality -DebugEncoding
```

## 4) 輸出檔案

每次執行都會在 `results\yyyyMMdd-HHmmss\` 產生：

- `quality_metrics.csv`：能力分數（長表）
- `perf_raw.csv`：每次請求的 TTFT/TPS 原始資料
- `perf_summary.csv`：依模型彙整的平均/中位數/P95
- `run_manifest.json`：本次執行中繼資料

## 注意事項

- `local-chat-completions` 通常要配 `--apply_chat_template`，腳本已預設開啟。
- `quality.limit` 建議只用於快速測試；正式分數建議移除或設為 `null`。
- 若你改用 `local-completions` 跑 loglikelihood 任務，請同步調整 `quality.backend` 與 `extraModelArgs`（例如改成 `/v1/completions`）。
- 若 `benchmark-config.json` 含中文內容，建議使用 UTF-8 編碼儲存。
