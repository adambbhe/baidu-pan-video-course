# ==============================================================
# 端到端集成测试入口 (PowerShell)
# 启动 mock server → 运行下载 → ASR → 验证 → 清理
# ==============================================================

$TEST_DIR = $PSScriptRoot
$SKILL_DIR = Resolve-Path "$PSScriptRoot\..\.."

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  端到端集成测试" -ForegroundColor Cyan
Write-Host "  模拟: 下载 M3U8 → 分片下载 → 合并 MP4 → ASR → SRT" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

# 检测 Python
$pyCmd = $null
if (Get-Command python -ErrorAction SilentlyContinue) { $pyCmd = "python" }
elseif (Get-Command python3 -ErrorAction SilentlyContinue) { $pyCmd = "python3" }

if (-not $pyCmd) {
    Write-Host "[ERROR] Python not found in PATH" -ForegroundColor Red
    exit 1
}
Write-Host "[INFO] Using: $(& $pyCmd --version 2>&1)" -ForegroundColor Blue

# 检查 faster-whisper
$hasFasterWhisper = $false
try {
    $result = & $pyCmd -c "import faster_whisper; print('ok')" 2>&1
    if ($result -eq "ok") { $hasFasterWhisper = $true }
} catch {}

if ($hasFasterWhisper) {
    Write-Host "[INFO] faster-whisper: available (real ASR mode)" -ForegroundColor Green
} else {
    Write-Host "[INFO] faster-whisper: not installed (mock ASR mode)" -ForegroundColor Yellow
}

# 检查 ffmpeg
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    Write-Host "[INFO] ffmpeg: available" -ForegroundColor Green
} else {
    Write-Host "[INFO] ffmpeg: not found (using mock audio)" -ForegroundColor Yellow
}

Write-Host ""

# 运行测试
$testScript = Join-Path $TEST_DIR "run_e2e_test.py"
& $pyCmd $testScript
$exitCode = $LASTEXITCODE

Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "E2E TEST PASSED" -ForegroundColor Green
} else {
    Write-Host "E2E TEST FAILED (exit code: $exitCode)" -ForegroundColor Red
}

exit $exitCode
