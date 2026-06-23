#!/bin/bash
# ==============================================================
# baidu-pan-video-course 一键环境安装脚本
# 自动检测系统并安装所有依赖
# ==============================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[FAIL]${NC}  $1"; }
check_cmd() { command -v "$1" &>/dev/null; }

# ---------- 系统检测 ----------
OS="unknown"
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    OS="windows-git-bash"
fi

echo "=================================================="
echo "  baidu-pan-video-course 环境安装"
echo "  操作系统: $OS"
echo "=================================================="
echo ""

# ---------- 1. Python 3 ----------
log_info "检测 Python 3 ..."
if check_cmd python3; then
    PY_VER=$(python3 --version 2>&1)
    log_ok "已安装: $PY_VER"
else
    log_error "未安装 Python 3，请先安装: https://www.python.org/downloads/"
    exit 1
fi

# ---------- 2. pip ----------
log_info "检测 pip ..."
if python3 -m pip --version &>/dev/null; then
    log_ok "pip 可用"
else
    log_warn "pip 未配置，尝试安装..."
    python3 -m ensurepip --upgrade 2>/dev/null || {
        log_error "无法安装 pip，请手动安装"
        exit 1
    }
    log_ok "pip 已安装"
fi

# ---------- 3. ffmpeg ----------
log_info "检测 ffmpeg ..."
if check_cmd ffmpeg; then
    FF_VER=$(ffmpeg -version 2>&1 | head -1)
    log_ok "已安装: $FF_VER"
else
    log_warn "ffmpeg 未安装，正在安装..."
    case "$OS" in
        linux)
            if check_cmd apt; then
                sudo apt update -qq && sudo apt install -y -qq ffmpeg
            elif check_cmd dnf; then
                sudo dnf install -y ffmpeg-free
            elif check_cmd pacman; then
                sudo pacman -S --noconfirm ffmpeg
            else
                log_error "未识别的 Linux 包管理器，请手动安装 ffmpeg"
                exit 1
            fi
            ;;
        macos)
            if check_cmd brew; then
                brew install ffmpeg
            else
                log_error "请先安装 Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
                exit 1
            fi
            ;;
        windows-git-bash)
            log_warn "Windows 环境请手动下载 ffmpeg: https://ffmpeg.org/download.html"
            log_warn "  下载后将 ffmpeg.exe 所在目录加入 PATH"
            ;;
    esac
    check_cmd ffmpeg && log_ok "ffmpeg 安装成功" || log_error "ffmpeg 安装失败"
fi

# ---------- 4. faster-whisper ----------
log_info "安装 faster-whisper (tiny 模型) ..."
python3 -m pip install faster-whisper -q 2>&1 | tail -1
python3 -c "import faster_whisper" 2>/dev/null && \
    log_ok "faster-whisper 安装成功 (tiny 模型将在首次运行时自动下载)" || \
    log_error "faster-whisper 安装失败"

# ---------- 5. officecli ----------
log_info "检测 officecli ..."
if check_cmd officecli; then
    OCLI_VER=$(officecli --version 2>/dev/null || echo "已安装")
    log_ok "已安装: $OCLI_VER"
else
    log_warn "officecli 未安装，正在安装..."
    if check_cmd curl; then
        curl -fsSL https://d.officecli.ai/install.sh | bash 2>&1 | tail -3
        # 刷新 PATH
        export PATH="$HOME/.local/bin:$PATH"
        hash -r 2>/dev/null
        check_cmd officecli && log_ok "officecli 安装成功" || \
            log_warn "officecli 已下载但未加入 PATH，请手动执行: export PATH=\"\$HOME/.local/bin:\$PATH\""
    else
        log_error "curl 未安装，请手动安装 officecli"
    fi
fi

# ---------- 6. python-docx ----------
log_info "安装 python-docx (用于生成 Word 报告) ..."
python3 -m pip install python-docx -q 2>&1 | tail -1
python3 -c "from docx import Document" 2>/dev/null && \
    log_ok "python-docx 安装成功" || \
    log_error "python-docx 安装失败"

# ---------- 7. brotli (可选) ----------
log_info "安装 brotli (可选，用于解压 br 压缩响应) ..."
python3 -m pip install brotli -q 2>&1 | tail -1
python3 -c "import brotli" 2>/dev/null && \
    log_ok "brotli 安装成功" || \
    log_warn "brotli 安装失败（不影响核心功能，仅解压时回退到 gzip）"

# ---------- 验证 ----------
echo ""
echo "=================================================="
echo "  安装完成，验证依赖状态："
echo "=================================================="

verify() {
    local name=$1; local cmd=$2
    if eval "$cmd" &>/dev/null; then
        echo -e "  ${GREEN}[✓]${NC} $name"
    else
        echo -e "  ${RED}[✗]${NC} $name"
    fi
}

verify "Python 3"            "python3 --version"
verify "pip"                 "python3 -m pip --version"
verify "ffmpeg"              "ffmpeg -version"
verify "faster-whisper"      "python3 -c 'import faster_whisper'"
verify "officecli"           "officecli --version"
verify "python-docx"         "python3 -c 'from docx import Document'"
verify "brotli (可选)"       "python3 -c 'import brotli'"

echo ""
echo "=================================================="
echo "  一切就绪！"
echo "  首次运行 local-asr 时会在 ~/.cache/huggingface/"
echo "  自动下载 faster-whisper tiny 模型 (~75MB)"
echo "=================================================="
