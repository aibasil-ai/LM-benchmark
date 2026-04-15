[CmdletBinding()]
param(
    [string]$ConfigPath = ".\\benchmark-config.json",
    [string]$OutputRoot = ".\\results",
    [switch]$SkipQuality,
    [switch]$SkipPerformance,
    [switch]$DebugEncoding
)

$ErrorActionPreference = "Stop"

function Get-PropValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $Default
    }

    if ($null -eq $prop.Value) {
        return $Default
    }

    return $prop.Value
}

function To-Bool {
    param(
        [object]$Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value) {
        return $Default
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Default
    }

    switch ($text.Trim().ToLowerInvariant()) {
        "1" { return $true }
        "true" { return $true }
        "yes" { return $true }
        "y" { return $true }
        "on" { return $true }
        "0" { return $false }
        "false" { return $false }
        "no" { return $false }
        "n" { return $false }
        "off" { return $false }
        default { return $Default }
    }
}

function To-Int {
    param(
        [object]$Value,
        [int]$Default
    )

    if ($null -eq $Value) {
        return $Default
    }

    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }

    return $Default
}

function To-Double {
    param(
        [object]$Value,
        [double]$Default
    )

    if ($null -eq $Value) {
        return $Default
    }

    $parsed = 0.0
    if ([double]::TryParse(
        [string]$Value,
        [System.Globalization.NumberStyles]::Any,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsed
    )) {
        return $parsed
    }

    return $Default
}

function Write-StringDebug {
    param(
        [string]$Label,
        [AllowNull()][string]$Text,
        [int]$CodePointLimit = 64,
        [int]$PreviewLength = 120
    )

    if (-not $DebugEncoding) {
        return
    }

    if ($null -eq $Text) {
        $Text = ""
    }

    $codePoints = @()
    foreach ($char in ($Text.ToCharArray() | Select-Object -First $CodePointLimit)) {
        $codePoints += [int][char]$char
    }

    $preview = if ($Text.Length -le $PreviewLength) {
        $Text
    }
    else {
        $Text.Substring(0, $PreviewLength) + "..."
    }

    Write-Host "[DebugEncoding] $Label length: $($Text.Length)"
    Write-Host "[DebugEncoding] $Label preview: $preview"
    Write-Host "[DebugEncoding] $Label codepoints(first $CodePointLimit): $($codePoints -join ',')"
}

function Convert-ToSlug {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return "unknown-model"
    }

    $slug = $Text.ToLowerInvariant()
    $slug = [System.Text.RegularExpressions.Regex]::Replace($slug, "[^a-z0-9._-]", "-")
    $slug = [System.Text.RegularExpressions.Regex]::Replace($slug, "-+", "-")
    $slug = $slug.Trim("-")

    if ([string]::IsNullOrWhiteSpace($slug)) {
        return "unknown-model"
    }

    return $slug
}

function Get-AuthHeaders {
    param([object]$LmStudioConfig)

    $headers = @{}
    $tokenEnvName = [string](Get-PropValue -Object $LmStudioConfig -Name "apiTokenEnv" -Default "")

    if (-not [string]::IsNullOrWhiteSpace($tokenEnvName)) {
        $token = [Environment]::GetEnvironmentVariable($tokenEnvName)
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            $headers["Authorization"] = "Bearer $token"
        }
    }

    return $headers
}

function Get-NumericPercentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )

    if ($null -eq $Values -or $Values.Count -eq 0) {
        return [double]::NaN
    }

    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 1) {
        return [double]$sorted[0]
    }

    $clamped = [Math]::Max(0.0, [Math]::Min(100.0, $Percentile))
    $rank = ($clamped / 100.0) * ($sorted.Count - 1)
    $lowerIndex = [Math]::Floor($rank)
    $upperIndex = [Math]::Ceiling($rank)

    if ($lowerIndex -eq $upperIndex) {
        return [double]$sorted[$lowerIndex]
    }

    $weight = $rank - $lowerIndex
    $lowerValue = [double]$sorted[$lowerIndex]
    $upperValue = [double]$sorted[$upperIndex]
    return $lowerValue + (($upperValue - $lowerValue) * $weight)
}

function Find-LmEvalResultFile {
    param([string]$OutputPath)

    $jsonFiles = Get-ChildItem -Path $OutputPath -Recurse -File -Filter "*.json" |
        Sort-Object -Property LastWriteTime -Descending

    foreach ($file in $jsonFiles) {
        try {
            $json = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            continue
        }

        $results = Get-PropValue -Object $json -Name "results" -Default $null
        if ($null -ne $results) {
            return [PSCustomObject]@{
                Path = $file.FullName
                Json = $json
            }
        }
    }

    throw "Cannot find lm-eval result JSON under $OutputPath."
}

function Convert-LmEvalResultsToRows {
    param(
        [string]$RunId,
        [string]$ModelName,
        [string]$ModelId,
        [string]$OutputPath
    )

    $resultFile = Find-LmEvalResultFile -OutputPath $OutputPath
    $resultJson = $resultFile.Json
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($taskProp in $resultJson.results.PSObject.Properties) {
        $taskName = [string]$taskProp.Name
        $taskMetrics = $taskProp.Value

        foreach ($metricProp in $taskMetrics.PSObject.Properties) {
            $metricName = [string]$metricProp.Name
            $metricValue = $metricProp.Value

            if ($metricValue -is [System.Collections.IEnumerable] -and -not ($metricValue -is [string])) {
                continue
            }

            $numericValue = 0.0
            $isNumeric = [double]::TryParse(
                [string]$metricValue,
                [System.Globalization.NumberStyles]::Any,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$numericValue
            )

            if (-not $isNumeric) {
                continue
            }

            $rows.Add([PSCustomObject]@{
                    run_id = $RunId
                    timestamp = (Get-Date).ToString("s")
                    model_name = $ModelName
                    model_id = $ModelId
                    task = $taskName
                    metric = $metricName
                    value = [Math]::Round($numericValue, 10)
                    source_file = $resultFile.Path
                })
        }
    }

    return $rows
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath. Copy benchmark-config.example.json to benchmark-config.json first."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$lmstudio = Get-PropValue -Object $config -Name "lmstudio" -Default $null
if ($null -eq $lmstudio) {
    throw "Missing lmstudio section in config file."
}

$openaiBaseUrl = [string](Get-PropValue -Object $lmstudio -Name "openaiBaseUrl" -Default "")
$apiBase = [string](Get-PropValue -Object $lmstudio -Name "apiBase" -Default "")

if ([string]::IsNullOrWhiteSpace($openaiBaseUrl) -and -not [string]::IsNullOrWhiteSpace($apiBase)) {
    $openaiBaseUrl = $apiBase.TrimEnd("/") + "/v1"
}

if ([string]::IsNullOrWhiteSpace($apiBase) -and -not [string]::IsNullOrWhiteSpace($openaiBaseUrl)) {
    $trimmed = $openaiBaseUrl.TrimEnd("/")
    if ($trimmed.EndsWith("/v1")) {
        $apiBase = $trimmed.Substring(0, $trimmed.Length - 3)
    }
}

if ([string]::IsNullOrWhiteSpace($openaiBaseUrl)) {
    throw "Cannot resolve openaiBaseUrl. Set lmstudio.openaiBaseUrl in config."
}

if ([string]::IsNullOrWhiteSpace($apiBase)) {
    throw "Cannot resolve apiBase. Set lmstudio.apiBase in config."
}

$models = @(Get-PropValue -Object $config -Name "models" -Default @())
if ($models.Count -eq 0) {
    throw "models list is empty. Add at least one model."
}

$qualityConfig = Get-PropValue -Object $config -Name "quality" -Default @{}
$perfConfig = Get-PropValue -Object $config -Name "performance" -Default @{}

$qualityEnabled = (To-Bool -Value (Get-PropValue -Object $qualityConfig -Name "enabled" -Default $true) -Default $true) -and (-not $SkipQuality)
$perfEnabled = (To-Bool -Value (Get-PropValue -Object $perfConfig -Name "enabled" -Default $true) -Default $true) -and (-not $SkipPerformance)

$headers = Get-AuthHeaders -LmStudioConfig $lmstudio
$modelsCheckUrl = $openaiBaseUrl.TrimEnd("/") + "/models"

Write-Host "[Init] Checking LM Studio endpoint: $modelsCheckUrl"
try {
    $null = Invoke-RestMethod -Method Get -Uri $modelsCheckUrl -Headers $headers -TimeoutSec 20
}
catch {
    throw "Cannot connect to LM Studio. Make sure the service is running. Error: $($_.Exception.Message)"
}

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$runRoot = Join-Path -Path $OutputRoot -ChildPath $runId
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

$qualityRows = New-Object System.Collections.Generic.List[object]
$perfRows = New-Object System.Collections.Generic.List[object]

$lmEvalExecutable = $null
$qualityBackend = ""
$qualityTasksArg = ""
$qualityLimit = $null
$qualityApplyChatTemplate = $true
$qualityNumConcurrent = 1
$qualityMaxRetries = 3
$qualityTokenizedRequests = $false
$qualityExtraModelArgs = @()

if ($qualityEnabled) {
    $lmEvalPath = [string](Get-PropValue -Object $qualityConfig -Name "lmEvalPath" -Default ".\\.venv\\Scripts\\lm-eval.exe")
    if (Test-Path -LiteralPath $lmEvalPath) {
        $lmEvalExecutable = (Resolve-Path -LiteralPath $lmEvalPath).Path
    }
    else {
        $lmEvalExecutable = $lmEvalPath
    }

    $qualityBackend = [string](Get-PropValue -Object $qualityConfig -Name "backend" -Default "local-chat-completions")
    $qualityNumConcurrent = To-Int -Value (Get-PropValue -Object $qualityConfig -Name "numConcurrent" -Default 1) -Default 1
    $qualityMaxRetries = To-Int -Value (Get-PropValue -Object $qualityConfig -Name "maxRetries" -Default 3) -Default 3
    $qualityTokenizedRequests = To-Bool -Value (Get-PropValue -Object $qualityConfig -Name "tokenizedRequests" -Default $false) -Default $false
    $qualityApplyChatTemplate = To-Bool -Value (Get-PropValue -Object $qualityConfig -Name "applyChatTemplate" -Default $true) -Default $true

    $limitRaw = Get-PropValue -Object $qualityConfig -Name "limit" -Default $null
    if ($null -ne $limitRaw -and -not [string]::IsNullOrWhiteSpace([string]$limitRaw)) {
        $qualityLimit = To-Int -Value $limitRaw -Default 0
        if ($qualityLimit -le 0) {
            $qualityLimit = $null
        }
    }

    $tasksRaw = Get-PropValue -Object $qualityConfig -Name "tasks" -Default @("truthfulqa_gen")
    if ($tasksRaw -is [string]) {
        $tasks = @($tasksRaw.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    }
    else {
        $tasks = @($tasksRaw | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne "" })
    }

    if ($tasks.Count -eq 0) {
        throw "quality.tasks is empty. Add at least one task."
    }
    $qualityTasksArg = $tasks -join ","

    $extraArgsRaw = Get-PropValue -Object $qualityConfig -Name "extraModelArgs" -Default @()
    if ($extraArgsRaw -is [string]) {
        $qualityExtraModelArgs = @($extraArgsRaw.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    }
    else {
        $qualityExtraModelArgs = @($extraArgsRaw | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne "" })
    }
}

$perfWarmupRuns = 1
$perfRunsPerPrompt = 5
$perfTemperature = 0.0
$perfMaxOutputTokens = 256
$perfPrompts = @()

if ($perfEnabled) {
    $perfWarmupRuns = [Math]::Max(0, (To-Int -Value (Get-PropValue -Object $perfConfig -Name "warmupRuns" -Default 1) -Default 1))
    $perfRunsPerPrompt = [Math]::Max(1, (To-Int -Value (Get-PropValue -Object $perfConfig -Name "runsPerPrompt" -Default 5) -Default 5))
    $perfTemperature = To-Double -Value (Get-PropValue -Object $perfConfig -Name "temperature" -Default 0) -Default 0.0
    $perfMaxOutputTokens = [Math]::Max(1, (To-Int -Value (Get-PropValue -Object $perfConfig -Name "maxOutputTokens" -Default 256) -Default 256))

    $promptsRaw = Get-PropValue -Object $perfConfig -Name "prompts" -Default @()
    if ($promptsRaw -is [string]) {
        $perfPrompts = @($promptsRaw.Trim())
    }
    else {
        $perfPrompts = @($promptsRaw | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne "" })
    }

    if ($perfPrompts.Count -eq 0) {
        throw "performance.prompts is empty. Add at least one prompt."
    }

    if ($DebugEncoding) {
        for ($i = 0; $i -lt $perfPrompts.Count; $i++) {
            Write-StringDebug -Label ("Prompt[{0}]" -f ($i + 1)) -Text $perfPrompts[$i] -CodePointLimit 40 -PreviewLength 100
        }
    }
}

$perfEndpoint = $apiBase.TrimEnd("/") + "/api/v1/chat"

foreach ($modelItem in $models) {
    $modelId = [string](Get-PropValue -Object $modelItem -Name "id" -Default "")
    $modelName = [string](Get-PropValue -Object $modelItem -Name "name" -Default "")

    if ([string]::IsNullOrWhiteSpace($modelId)) {
        throw "A model item is missing id."
    }

    if ([string]::IsNullOrWhiteSpace($modelName)) {
        $modelName = $modelId
    }

    $slug = Convert-ToSlug -Text $modelName
    Write-Host ""
    Write-Host "[Model] $modelName ($modelId)"

    if ($qualityEnabled) {
        $qualityOutput = Join-Path -Path $runRoot -ChildPath ("quality-" + $slug)
        New-Item -ItemType Directory -Path $qualityOutput -Force | Out-Null

        $chatCompletionsUrl = $openaiBaseUrl.TrimEnd("/") + "/chat/completions"
        $modelArgsParts = @(
            "model=$modelId",
            "base_url=$chatCompletionsUrl",
            "num_concurrent=$qualityNumConcurrent",
            "max_retries=$qualityMaxRetries",
            "tokenized_requests=$($qualityTokenizedRequests.ToString().ToLowerInvariant())"
        )

        foreach ($extraArg in $qualityExtraModelArgs) {
            $modelArgsParts += $extraArg
        }

        $modelArgs = $modelArgsParts -join ","

        $cmdArgs = @(
            "run",
            "--model", $qualityBackend,
            "--model_args", $modelArgs,
            "--tasks", $qualityTasksArg,
            "--output_path", $qualityOutput,
            "--log_samples"
        )

        if ($qualityApplyChatTemplate) {
            $cmdArgs += "--apply_chat_template"
        }

        if ($null -ne $qualityLimit) {
            $cmdArgs += @("--limit", [string]$qualityLimit)
        }

        $qualityLogPath = Join-Path -Path $qualityOutput -ChildPath "lm-eval.log"
        Write-Host "[Quality] Running lm-eval ..."
        Write-Host "[Quality] Output: $qualityOutput"

        $oldErrorActionPreference = $ErrorActionPreference
        try {
            # In Windows PowerShell 5.1, native stderr lines can be promoted to
            # PowerShell errors when ErrorActionPreference is Stop.
            # lm-eval prints warnings to stderr (for example --limit warning),
            # so temporarily relax this and rely on process exit code.
            $ErrorActionPreference = "Continue"
            & $lmEvalExecutable @cmdArgs 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    $_.Exception.Message
                }
                else {
                    [string]$_
                }
            } | Tee-Object -FilePath $qualityLogPath | Out-Host
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }

        if ($exitCode -ne 0) {
            throw "lm-eval failed (exit code: $exitCode). See $qualityLogPath"
        }

        $rows = Convert-LmEvalResultsToRows -RunId $runId -ModelName $modelName -ModelId $modelId -OutputPath $qualityOutput
        foreach ($row in $rows) {
            $qualityRows.Add($row)
        }
    }

    if ($perfEnabled) {
        Write-Host "[Perf] Running /api/v1/chat benchmark ..."

        for ($promptIndex = 0; $promptIndex -lt $perfPrompts.Count; $promptIndex++) {
            $prompt = $perfPrompts[$promptIndex]
            $totalRuns = $perfWarmupRuns + $perfRunsPerPrompt

            for ($runIndex = 1; $runIndex -le $totalRuns; $runIndex++) {
                $isWarmup = $runIndex -le $perfWarmupRuns
                $phase = if ($isWarmup) { "warmup" } else { "measure" }

                Write-Host "[Perf] Prompt $($promptIndex + 1)/$($perfPrompts.Count), run $runIndex/$totalRuns ($phase)"

                $requestBody = @{
                    model = $modelId
                    input = $prompt
                    stream = $false
                    store = $false
                    temperature = $perfTemperature
                    max_output_tokens = $perfMaxOutputTokens
                }

                $jsonBody = $requestBody | ConvertTo-Json -Depth 10 -Compress
                $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)

                if ($DebugEncoding -and $runIndex -eq 1) {
                    $bodyBytesPreview = @($bodyBytes | Select-Object -First 40)
                    Write-Host "[DebugEncoding] Request body bytes(first 40): $($bodyBytesPreview -join ',')"
                }

                $invokeParams = @{
                    Method = "Post"
                    Uri = $perfEndpoint
                    Headers = $headers
                    ContentType = "application/json; charset=utf-8"
                    Body = $bodyBytes
                    TimeoutSec = 600
                }
                $response = Invoke-RestMethod @invokeParams

                if ($DebugEncoding -and $runIndex -eq 1) {
                    $responseOutput = @(Get-PropValue -Object $response -Name "output" -Default @())
                    if ($responseOutput.Count -gt 0) {
                        $outputType = [string](Get-PropValue -Object $responseOutput[0] -Name "type" -Default "")
                        $outputContent = [string](Get-PropValue -Object $responseOutput[0] -Name "content" -Default "")
                        Write-Host "[DebugEncoding] First output type: $outputType"
                        Write-StringDebug -Label ("Response[{0}]" -f ($promptIndex + 1)) -Text $outputContent -CodePointLimit 40 -PreviewLength 100
                    }
                }

                $stats = Get-PropValue -Object $response -Name "stats" -Default $null
                if ($null -eq $stats) {
                    throw "LM Studio response does not include stats; cannot calculate TTFT/TPS."
                }

                $ttft = To-Double -Value (Get-PropValue -Object $stats -Name "time_to_first_token_seconds" -Default $null) -Default ([double]::NaN)
                $tps = To-Double -Value (Get-PropValue -Object $stats -Name "tokens_per_second" -Default $null) -Default ([double]::NaN)
                $inputTokens = To-Int -Value (Get-PropValue -Object $stats -Name "input_tokens" -Default $null) -Default -1
                $outputTokens = To-Int -Value (Get-PropValue -Object $stats -Name "total_output_tokens" -Default $null) -Default -1
                $loadSeconds = To-Double -Value (Get-PropValue -Object $stats -Name "model_load_time_seconds" -Default $null) -Default ([double]::NaN)

                $perfRows.Add([PSCustomObject]@{
                        run_id = $runId
                        timestamp = (Get-Date).ToString("s")
                        model_name = $modelName
                        model_id = $modelId
                        prompt_index = $promptIndex + 1
                        run_index = $runIndex
                        is_warmup = $isWarmup
                        ttft_seconds = $ttft
                        tokens_per_second = $tps
                        input_tokens = $inputTokens
                        output_tokens = $outputTokens
                        model_load_time_seconds = $loadSeconds
                    })
            }
        }
    }
}

if ($qualityRows.Count -gt 0) {
    $qualityCsvPath = Join-Path -Path $runRoot -ChildPath "quality_metrics.csv"
    $qualityRows | Export-Csv -LiteralPath $qualityCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "[Done] Quality CSV: $qualityCsvPath"
}

if ($perfRows.Count -gt 0) {
    $perfRawCsvPath = Join-Path -Path $runRoot -ChildPath "perf_raw.csv"
    $perfRows | Export-Csv -LiteralPath $perfRawCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "[Done] Perf raw CSV: $perfRawCsvPath"

    $measuredRows = @($perfRows | Where-Object { -not $_.is_warmup })
    $summaryRows = New-Object System.Collections.Generic.List[object]

    $grouped = $measuredRows | Group-Object -Property { "{0}||{1}" -f $_.model_name, $_.model_id }
    foreach ($group in $grouped) {
        $items = @($group.Group)
        if ($items.Count -eq 0) {
            continue
        }

        $ttftValues = @($items | ForEach-Object { [double]$_.ttft_seconds } | Where-Object { -not [double]::IsNaN($_) })
        $tpsValues = @($items | ForEach-Object { [double]$_.tokens_per_second } | Where-Object { -not [double]::IsNaN($_) })

        $ttftAvg = if ($ttftValues.Count -gt 0) { [double](($ttftValues | Measure-Object -Average).Average) } else { [double]::NaN }
        $tpsAvg = if ($tpsValues.Count -gt 0) { [double](($tpsValues | Measure-Object -Average).Average) } else { [double]::NaN }

        $summaryRows.Add([PSCustomObject]@{
                run_id = $runId
                model_name = $items[0].model_name
                model_id = $items[0].model_id
                sample_count = $items.Count
                ttft_avg_seconds = [Math]::Round($ttftAvg, 6)
                ttft_median_seconds = [Math]::Round((Get-NumericPercentile -Values $ttftValues -Percentile 50), 6)
                ttft_p95_seconds = [Math]::Round((Get-NumericPercentile -Values $ttftValues -Percentile 95), 6)
                tps_avg = [Math]::Round($tpsAvg, 6)
                tps_median = [Math]::Round((Get-NumericPercentile -Values $tpsValues -Percentile 50), 6)
                tps_p95 = [Math]::Round((Get-NumericPercentile -Values $tpsValues -Percentile 95), 6)
            })
    }

    $perfSummaryCsvPath = Join-Path -Path $runRoot -ChildPath "perf_summary.csv"
    $summaryRows | Export-Csv -LiteralPath $perfSummaryCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "[Done] Perf summary CSV: $perfSummaryCsvPath"
}

$manifestPath = Join-Path -Path $runRoot -ChildPath "run_manifest.json"
$manifest = [ordered]@{
    run_id = $runId
    created_at = (Get-Date).ToString("o")
    config_path = (Resolve-Path -LiteralPath $ConfigPath).Path
    output_root = (Resolve-Path -LiteralPath $runRoot).Path
    model_count = $models.Count
    quality_enabled = $qualityEnabled
    performance_enabled = $perfEnabled
    debug_encoding = [bool]$DebugEncoding
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Host ""
Write-Host "All done. Output folder: $runRoot"
