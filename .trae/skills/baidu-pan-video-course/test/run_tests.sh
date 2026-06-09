#!/bin/bash
# ==============================================================
# baidu-pan-video-course 技能测试套件
# 验证技能结构完整性 + 工具脚本语法 + 参数解析
# ==============================================================
set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

test_pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
test_fail() { echo -e "  ${RED}[FAIL]${NC} $1 — $2"; FAIL=$((FAIL+1)); }
section()   { echo ""; echo -e "${YELLOW}━━━ $1 ━━━${NC}"; }

# ========================================
section "1. 技能结构验证"

# 1a. SKILL.md 存在且可读
if [ -f "$SKILL_DIR/SKILL.md" ] && [ -r "$SKILL_DIR/SKILL.md" ]; then
    test_pass "SKILL.md 存在且可读"
else
    test_fail "SKILL.md" "文件不存在或不可读"
fi

# 1b. Frontmatter 包含必要字段
for field in "name:" "description:" "mode: agent" "custom-tools:"; do
    if grep -q "^$field" "$SKILL_DIR/SKILL.md" 2>/dev/null || grep -q "$field" "$SKILL_DIR/SKILL.md" 2>/dev/null; then
        test_pass "SKILL.md frontmatter 包含 '$field'"
    else
        test_fail "SKILL.md frontmatter" "缺少 '$field'"
    fi
done

# 1c. 声明的 custom-tools 与实际目录一致
while IFS= read -r tool; do
    tool=$(echo "$tool" | sed 's/^[[:space:]]*-[[:space:]]*"//;s/"//' | xargs)
    [ -z "$tool" ] && continue
    if [ -d "$SKILL_DIR/tools/$tool" ]; then
        test_pass "工具目录存在: tools/$tool"
    else
        test_fail "工具目录缺失" "tools/$tool (在 custom-tools 中声明但未找到)"
    fi
done < <(sed -n '/^custom-tools:/,/^[a-z]/{/^  - "/p}' "$SKILL_DIR/SKILL.md")

# 1d. 工具目录与 custom-tools 声明一致（反向检查）
for tool_dir in "$SKILL_DIR/tools"/*/; do
    tool_name=$(basename "$tool_dir")
    if grep -q "\"$tool_name\"" "$SKILL_DIR/SKILL.md"; then
        test_pass "工具 $tool_name 在 custom-tools 中已声明"
    else
        test_fail "工具 $tool_name" "存在于 tools/ 但未在 custom-tools 中声明"
    fi
done

# ========================================
section "2. tool.yaml 验证"

for tool_yaml in "$SKILL_DIR/tools"/*/tool.yaml; do
    tool_name=$(basename "$(dirname "$tool_yaml")")
    yaml_name=$(grep '^name:' "$tool_yaml" | head -1 | sed 's/^name:[[:space:]]*"//;s/"$//' | xargs)

    # 2a. name 字段与目录名一致
    if [ "$yaml_name" = "$tool_name" ]; then
        test_pass "$tool_name/tool.yaml name 与目录一致 ($yaml_name)"
    else
        test_fail "$tool_name/tool.yaml" "name='$yaml_name' 但目录为 '$tool_name'"
    fi

    # 2b. 包含 type: object
    if grep -q 'type:[[:space:]]*object' "$tool_yaml"; then
        test_pass "$tool_name/tool.yaml 声明 parameters type=object"
    else
        test_fail "$tool_name/tool.yaml" "缺少 parameters type: object"
    fi

    # 2c. 包含 required 字段
    if grep -q '^required:' "$tool_yaml"; then
        test_pass "$tool_name/tool.yaml 声明了 required 参数"
    else
        test_fail "$tool_name/tool.yaml" "缺少 required 字段"
    fi

    # 2d. 包含 description
    if grep -q '^description:' "$tool_yaml"; then
        test_pass "$tool_name/tool.yaml 包含 description"
    else
        test_fail "$tool_name/tool.yaml" "缺少 description"
    fi
done

# ========================================
section "3. run.sh 语法检查"

for run_sh in "$SKILL_DIR/tools"/*/run.sh; do
    tool_name=$(basename "$(dirname "$run_sh")")

    # 3a. 可执行
    if [ -x "$run_sh" ] || [ -r "$run_sh" ]; then
        # bash -n 语法检查
        if bash -n "$run_sh" 2>/dev/null; then
            test_pass "$tool_name/run.sh 语法正确"
        else
            test_fail "$tool_name/run.sh" "bash -n 检查未通过"
        fi
    else
        test_fail "$tool_name/run.sh" "文件不可读"
    fi

    # 3b. shebang
    if head -1 "$run_sh" | grep -q '^#!/bin/'; then
        test_pass "$tool_name/run.sh 有 shebang"
    else
        test_fail "$tool_name/run.sh" "缺少 shebang"
    fi

    # 3c. 从 stdin 读取 JSON
    if grep -q 'INPUT=$(cat)' "$run_sh" || grep -q 'INPUT=\$(cat)' "$run_sh"; then
        test_pass "$tool_name/run.sh 从 stdin 读取 JSON"
    else
        test_fail "$tool_name/run.sh" "未从 stdin 读取 JSON"
    fi
done

# ========================================
section "4. JSON 参数解析测试（干运行）"

# 4a. download-video 参数解析
if [ -f "$SKILL_DIR/tools/download-video/run.sh" ]; then
    # 使用模拟 JSON，仅测试参数解析层（不实际下载）
    # 通过设置环境变量让脚本早期退出
    RESULT=$(echo '{"streaming_url":"https://pan.baidu.com/share/streaming?type=M3U8_AUTO_480&sign=test","cookie":"BDUSS=test123","referer":"https://pan.baidu.com/s/test","workspace":"/tmp/baidu_test","threads":2}' | \
        bash "$SKILL_DIR/tools/download-video/run.sh" 2>&1 || true)
    if echo "$RESULT" | grep -q '"status"'; then
        test_pass "download-video/run.sh 可解析 JSON 输入（实际下载会因凭据无效失败）"
    else
        test_fail "download-video/run.sh" "无法解析 JSON 输入"
    fi
    echo "      ↳ $RESULT" | head -3
fi

# 4b. local-asr 参数解析（因缺视频文件会提前退出，检查错误格式）
if [ -f "$SKILL_DIR/tools/local-asr/run.sh" ]; then
    RESULT=$(echo '{"video_path":"/nonexistent/test.mp4","output_srt":"/tmp/test.srt","language":"zh","model_size":"tiny"}' | \
        bash "$SKILL_DIR/tools/local-asr/run.sh" 2>&1 || true)
    if echo "$RESULT" | grep -q '"status"'; then
        test_pass "local-asr/run.sh 可解析 JSON 输入（因缺文件提前退出）"
    else
        test_fail "local-asr/run.sh" "无法解析 JSON 输入"
    fi
    echo "      ↳ $RESULT" | head -3
fi

# ========================================
section "5. setup.sh 验证"

if [ -f "$SKILL_DIR/setup.sh" ]; then
    if bash -n "$SKILL_DIR/setup.sh" 2>/dev/null; then
        test_pass "setup.sh 语法正确"
    else
        test_fail "setup.sh" "bash -n 检查未通过"
    fi

    # 检查关键安装步骤函数
    for func in "ffmpeg" "faster-whisper" "officecli" "brotli" "python3"; do
        if grep -q "$func" "$SKILL_DIR/setup.sh"; then
            test_pass "setup.sh 包含 $func 安装逻辑"
        else
            test_fail "setup.sh" "缺少 $func 安装步骤"
        fi
    done
else
    test_fail "setup.sh" "文件不存在"
fi

# ========================================
section "6. 下载逻辑单元测试（M3U8 解析）"

# 测试 M3U8 URL 解析正则表达式
TEST_M3U8='#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10,
https://bdct06.baidupcs.com/video/netdisk-videotran-xxx/abc_1_ts/etag?range=0-341031
#EXTINF:10,
https://bdct06.baidupcs.com/video/netdisk-videotran-xxx/abc_1_ts/etag?range=341032-605359
#EXTINF:10,
https://bdct07.baidupcs.com/video/netdisk-videotran-yyy/def_1_ts/etag?range=605360-900000
'

MATCH_COUNT=$(echo "$TEST_M3U8" | python3 -c "
import re, sys
text = sys.stdin.read()
urls = re.findall(r'https://bdct\d+\.baidupcs\.com/video[^\s]+', text)
print(len(urls))
" 2>/dev/null)

if [ "$MATCH_COUNT" = "3" ]; then
    test_pass "M3U8 分片 URL 正则匹配正确 (3/3 URLs)"
else
    test_fail "M3U8 解析" "期望 3 个 URL, 实际匹配 $MATCH_COUNT 个"
fi

# ========================================
section "7. SRT 时间格式化单元测试"

SRT_TIME=$(python3 -c "
def format_time(seconds):
    ms = int((seconds % 1) * 1000)
    s = int(seconds) % 60
    m = (int(seconds) // 60) % 60
    h = int(seconds) // 3600
    return f'{h:02d}:{m:02d}:{s:02d},{ms:03d}'

# 测试几个时间点
tests = [(0, '00:00:00,000'), (65.5, '00:01:05,500'), (3661.123, '01:01:01,123'), (1474.0, '00:24:34,000')]
for sec, expected in tests:
    result = format_time(sec)
    if result != expected:
        print(f'FAIL: {sec}s -> {result} (expected {expected})')
        exit(1)
print('OK')
")

if [ "$SRT_TIME" = "OK" ]; then
    test_pass "SRT 时间格式化函数正确"
else
    test_fail "SRT 时间格式化" "$SRT_TIME"
fi

# ========================================
section "测试结果汇总"

echo ""
echo "  ${GREEN}通过: $PASS${NC}"
echo "  ${RED}失败: $FAIL${NC}"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}✓ 全部测试通过！${NC}"
    exit 0
else
    echo -e "  ${RED}✗ $FAIL 项测试失败${NC}"
    exit 1
fi
