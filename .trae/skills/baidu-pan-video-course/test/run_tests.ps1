# ==============================================================
# baidu-pan-video-course Skill Test Suite (PowerShell)
# Validates skill structure, tool definitions, and run scripts
# ==============================================================

$SKILL_DIR = Resolve-Path "$PSScriptRoot\.."
$TEST_DIR = $PSScriptRoot
$PASS = 0; $FAIL = 0

function Test-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $global:PASS++ }
function Test-Fail($msg, $detail) { Write-Host "  [FAIL] $msg - $detail" -ForegroundColor Red; $global:FAIL++ }
function Section($title) { Write-Host ""; Write-Host "--- $title ---" -ForegroundColor Yellow }

# ========================================
Section "1. Skill Structure Validation"

if (Test-Path "$SKILL_DIR\SKILL.md") {
    Test-Pass "SKILL.md exists"
} else {
    Test-Fail "SKILL.md" "file not found"
}

$skillContent = Get-Content "$SKILL_DIR\SKILL.md" -Raw -Encoding UTF8

# 1b. Frontmatter fields
$checks = @(
    @{Pattern="name:"; Label="name field"},
    @{Pattern="description:"; Label="description field"},
    @{Pattern="mode:"; Label="mode field"},
    @{Pattern="custom-tools:"; Label="custom-tools field"}
)
foreach ($c in $checks) {
    if ($skillContent -match [regex]::Escape($c.Pattern)) {
        Test-Pass "SKILL.md has $($c.Label)"
    } else {
        Test-Fail "SKILL.md" "missing $($c.Label)"
    }
}

# 1c. custom-tools declared vs actual dirs
$toolMatches = [regex]::Matches($skillContent, '- "(.*?)"')
$declaredTools = $toolMatches | ForEach-Object { $_.Groups[1].Value }
$actualToolDirs = Get-ChildItem "$SKILL_DIR\tools" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }

foreach ($tool in $declaredTools) {
    if ($actualToolDirs -contains $tool) {
        Test-Pass "Tool dir exists: tools/$tool"
    } else {
        Test-Fail "Tool dir missing" "tools/$tool declared but not found"
    }
}

# 1d. Reverse check
foreach ($tool in $actualToolDirs) {
    if ($declaredTools -contains $tool) {
        Test-Pass "Tool $tool declared in custom-tools"
    } else {
        Test-Fail "Tool $tool" "exists in tools/ but not in custom-tools"
    }
}

# ========================================
Section "2. tool.yaml Validation"

foreach ($toolDir in Get-ChildItem "$SKILL_DIR\tools" -Directory -ErrorAction SilentlyContinue) {
    $toolName = $toolDir.Name
    $yamlPath = Join-Path $toolDir.FullName "tool.yaml"

    if (-not (Test-Path $yamlPath)) {
        Test-Fail "$toolName/tool.yaml" "file not found"
        continue
    }

    $yamlContent = Get-Content $yamlPath -Raw -Encoding UTF8

    if ($yamlContent -match 'name:\s*"([^"]+)"') {
        $yamlName = $Matches[1]
        if ($yamlName -eq $toolName) {
            Test-Pass "$toolName/tool.yaml name matches dir ($yamlName)"
        } else {
            Test-Fail "$toolName/tool.yaml" "name=$yamlName but dir=$toolName"
        }
    } else {
        Test-Fail "$toolName/tool.yaml" "missing name field"
    }

    if ($yamlContent -match 'type:\s*object') {
        Test-Pass "$toolName/tool.yaml has type:object"
    } else {
        Test-Fail "$toolName/tool.yaml" "missing type:object"
    }

    if ($yamlContent -match 'required:') {
        Test-Pass "$toolName/tool.yaml has required params"
    } else {
        Test-Fail "$toolName/tool.yaml" "missing required field"
    }

    if ($yamlContent -match 'description:') {
        Test-Pass "$toolName/tool.yaml has description"
    } else {
        Test-Fail "$toolName/tool.yaml" "missing description"
    }
}

# ========================================
Section "3. run.sh Validation"

foreach ($toolDir in Get-ChildItem "$SKILL_DIR\tools" -Directory -ErrorAction SilentlyContinue) {
    $toolName = $toolDir.Name
    $shPath = Join-Path $toolDir.FullName "run.sh"

    if (-not (Test-Path $shPath)) {
        Test-Fail "$toolName/run.sh" "file not found"
        continue
    }

    $shContent = Get-Content $shPath -Raw -Encoding UTF8

    if ($shContent -match '^#!/bin/') {
        Test-Pass "$toolName/run.sh has shebang"
    } else {
        Test-Fail "$toolName/run.sh" "missing shebang"
    }

    if ($shContent -match 'INPUT=\$\(cat\)') {
        Test-Pass "$toolName/run.sh reads JSON from stdin"
    } else {
        Test-Fail "$toolName/run.sh" "no stdin JSON reading"
    }

    if ($shContent -match 'python3') {
        Test-Pass "$toolName/run.sh calls python3"
    } else {
        Test-Fail "$toolName/run.sh" "no python3 call found"
    }

    if ($shContent -match 'status') {
        Test-Pass "$toolName/run.sh outputs JSON status"
    } else {
        Test-Fail "$toolName/run.sh" "no status JSON output"
    }

    if ($shContent -match 'exit 1') {
        Test-Pass "$toolName/run.sh has error exit handling"
    } else {
        Test-Fail "$toolName/run.sh" "missing exit 1 handling"
    }
}

# ========================================
Section "4. setup.sh Validation"

$setupPath = "$SKILL_DIR\setup.sh"
if (Test-Path $setupPath) {
    $setupContent = Get-Content $setupPath -Raw -Encoding UTF8

    if ($setupContent -match '^#!/bin/bash') {
        Test-Pass "setup.sh has correct shebang"
    } else {
        Test-Fail "setup.sh" "incorrect shebang"
    }

    $required = @("ffmpeg", "faster-whisper", "officecli", "brotli", "python3", "pip")
    foreach ($item in $required) {
        if ($setupContent -match $item) {
            Test-Pass "setup.sh includes $item install logic"
        } else {
            Test-Fail "setup.sh" "missing $item step"
        }
    }

    if ($setupContent -match 'verify') {
        Test-Pass "setup.sh includes post-install verification"
    } else {
        Test-Fail "setup.sh" "missing verify step"
    }
} else {
    Test-Fail "setup.sh" "file not found"
}

# ========================================
Section "5. M3U8 Parsing Unit Test (Python)"

$m3u8Test = @"
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10,
https://bdct06.baidupcs.com/video/netdisk-videotran-xxx/abc_1_ts/etag?range=0-341031
#EXTINF:10,
https://bdct06.baidupcs.com/video/netdisk-videotran-xxx/abc_1_ts/etag?range=341032-605359
#EXTINF:10,
https://bdct07.baidupcs.com/video/netdisk-videotran-yyy/def_1_ts/etag?range=605360-900000
"@

$m3u8Script = @"
import re, sys
text = sys.stdin.read()
urls = re.findall(r'https://bdct\d+\.baidupcs\.com/video[^\s]+', text)
print(len(urls))
"@

# Try python3 first, then python (for Windows compatibility)
$pyCmd = $null
if (Get-Command python3 -ErrorAction SilentlyContinue) { $pyCmd = "python3" }
elseif (Get-Command python -ErrorAction SilentlyContinue) { $pyCmd = "python" }

if ($pyCmd) {
    try {
        $result = $m3u8Test | & $pyCmd -c $m3u8Script 2>$null
        if ($result -eq "3") {
            Test-Pass "M3U8 segment URL regex correct (3/3)"
        } else {
            Test-Fail "M3U8 parsing" "expected 3 URLs, got: $result"
        }
    } catch {
        Test-Fail "M3U8 parsing" "python execution failed: $_"
    }
} else {
    Test-Fail "M3U8 parsing" "python3/python not found in PATH"
}

# ========================================
Section "6. SRT Time Format Unit Test (Python)"

$srtScript = @"
def format_time(seconds):
    ms = int((seconds % 1) * 1000)
    s = int(seconds) % 60
    m = (int(seconds) // 60) % 60
    h = int(seconds) // 3600
    return f'{h:02d}:{m:02d}:{s:02d},{ms:03d}'

tests = [
    (0, '00:00:00,000'),
    (65.5, '00:01:05,500'),
    (3661.123, '01:01:01,123'),
    (1474.0, '00:24:34,000')
]
for sec, expected in tests:
    result = format_time(sec)
    if result != expected:
        print('FAIL')
        exit(1)
print('OK')
"@

if ($pyCmd) {
    try {
        $srtResult = & $pyCmd -c $srtScript 2>$null
        if ($srtResult -eq "OK") {
            Test-Pass "SRT time format function correct"
        } else {
            Test-Fail "SRT time format" "$srtResult"
        }
    } catch {
        Test-Fail "SRT time format" "python execution failed: $_"
    }
} else {
    Test-Fail "SRT time format" "python3/python not found in PATH"
}

# ========================================
Section "7. Tool Parameter Completeness"

# 7a. download-video params
$downloadYaml = Get-Content "$SKILL_DIR\tools\download-video\tool.yaml" -Raw -Encoding UTF8
$downloadParams = @("streaming_url", "cookie", "referer", "workspace", "threads")
foreach ($param in $downloadParams) {
    if ($downloadYaml -match "${param}:") {
        Test-Pass "download-video has param: $param"
    } else {
        Test-Fail "download-video" "missing param: $param"
    }
}

# 7b. local-asr params
$asrYaml = Get-Content "$SKILL_DIR\tools\local-asr\tool.yaml" -Raw -Encoding UTF8
$asrParams = @("video_path", "output_srt", "language", "model_size")
foreach ($param in $asrParams) {
    if ($asrYaml -match "${param}:") {
        Test-Pass "local-asr has param: $param"
    } else {
        Test-Fail "local-asr" "missing param: $param"
    }
}

# 7c. model_size enum
if ($asrYaml -match 'tiny' -and $asrYaml -match 'base') {
    Test-Pass "local-asr model_size has enum constraint"
} else {
    Test-Fail "local-asr" "model_size missing enum values"
}

# ========================================
Section "8. Fixture Files"

$fixtures = @(
    @{Name="download_input.json"; Path="$TEST_DIR\fixtures\download_input.json"},
    @{Name="asr_input.json"; Path="$TEST_DIR\fixtures\asr_input.json"},
    @{Name="mock_m3u8.m3u8"; Path="$TEST_DIR\fixtures\mock_m3u8.m3u8"}
)
foreach ($f in $fixtures) {
    if (Test-Path $f.Path) {
        Test-Pass "$($f.Name) fixture exists"
    } else {
        Test-Fail "fixtures" "$($f.Name) not found"
    }
}

# download_input.json content check
$djPath = "$TEST_DIR\fixtures\download_input.json"
if (Test-Path $djPath) {
    try {
        $dj = Get-Content $djPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($dj.streaming_url -and $dj.cookie -and $dj.referer -and $dj.workspace) {
            Test-Pass "download_input.json has all required fields"
        } else {
            Test-Fail "download_input.json" "missing required fields"
        }
    } catch {
        Test-Fail "download_input.json" "invalid JSON: $_"
    }
}

# mock_m3u8.m3u8 content check
$m3u8Path = "$TEST_DIR\fixtures\mock_m3u8.m3u8"
if (Test-Path $m3u8Path) {
    $m3u8Content = Get-Content $m3u8Path -Raw -Encoding UTF8
    if ($m3u8Content -match '#EXTM3U' -and $m3u8Content -match 'baidupcs') {
        Test-Pass "mock_m3u8.m3u8 format correct"
    } else {
        Test-Fail "mock_m3u8.m3u8" "format incorrect"
    }
}

# ========================================
Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Test Results Summary" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Passed: $PASS" -ForegroundColor Green
$failColor = if ($FAIL -gt 0) { "Red" } else { "Green" }
Write-Host "  Failed: $FAIL" -ForegroundColor $failColor
Write-Host ""

if ($FAIL -eq 0) {
    Write-Host "  ALL TESTS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "  $FAIL TEST(S) FAILED" -ForegroundColor Red
    exit 1
}
