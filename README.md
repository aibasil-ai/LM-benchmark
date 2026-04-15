# LM-benchmark

在 Windows 環境使用 LM Studio 進行本地模型自動化 benchmark 的實用腳本，支援多模型批次評測。

本專案同時涵蓋兩種評測面向：

- 能力評測（`lm-eval` 任務分數）
- 效能評測（TTFT、TPS、P95 等指標）

## 主要功能

- 單次執行可批次跑多個模型
- 可分開跑能力或效能（`-SkipQuality` / `-SkipPerformance`）
- 自動輸出 CSV 與執行中繼資料
- 支援 Windows PowerShell 5.1 相容處理
- 內建 UTF-8 編碼處理與 `-DebugEncoding` 偵錯模式

## 檔案說明

- `run-lmstudio-benchmark.ps1`：主執行腳本
- `benchmark-config.example.json`：設定檔範例
- `README-benchmark.md`：詳細使用說明

## 快速開始

1. 建立虛擬環境並安裝依賴

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -U "lm-eval[api]"
```

2. 準備設定檔

```powershell
Copy-Item .\benchmark-config.example.json .\benchmark-config.json
```

3. 啟動 LM Studio Local Server（預設 `http://localhost:1234`）

4. 執行 benchmark

```powershell
.\run-lmstudio-benchmark.ps1
```

## 常用指令

只跑能力評測：

```powershell
.\run-lmstudio-benchmark.ps1 -SkipPerformance
```

只跑效能評測：

```powershell
.\run-lmstudio-benchmark.ps1 -SkipQuality
```

檢查中文編碼是否正確傳送：

```powershell
.\run-lmstudio-benchmark.ps1 -SkipQuality -DebugEncoding
```

## 輸出結果

每次執行會在 `results\yyyyMMdd-HHmmss\` 產生：

- `quality_metrics.csv`
- `perf_raw.csv`
- `perf_summary.csv`
- `run_manifest.json`

## 備註

- 正式能力分數建議不要使用 `quality.limit`（只適合快速測試）
- 若設定檔含中文內容，請使用 UTF-8 儲存
- 若終端機顯示中文亂碼，可先執行 `chcp 65001`
