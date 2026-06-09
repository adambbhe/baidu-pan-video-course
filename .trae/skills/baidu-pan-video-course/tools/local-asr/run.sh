#!/bin/bash
# local-asr: 本地语音识别工具
# 使用 ffmpeg 提取音频 + faster-whisper tiny 模型转录 → 生成 SRT 字幕
# 从 stdin 读取 JSON 参数

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)

# 解析 JSON 参数
VIDEO_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['video_path'])")
OUTPUT_SRT=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['output_srt'])")
LANGUAGE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('language', 'zh'))")
MODEL_SIZE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('model_size', 'tiny'))")

# 检查依赖
if ! command -v ffmpeg &> /dev/null; then
    echo "{\"status\":\"failed\",\"error\":\"ffmpeg not found. Install: apt install ffmpeg\"}"
    exit 1
fi

if ! python3 -c "import faster_whisper" 2>/dev/null; then
    echo "{\"status\":\"failed\",\"error\":\"faster-whisper not installed. Install: pip install faster-whisper\"}"
    exit 1
fi

# 检查视频文件
if [ ! -f "$VIDEO_PATH" ]; then
    echo "{\"status\":\"failed\",\"error\":\"video file not found: ${VIDEO_PATH}\"}"
    exit 1
fi

VIDEO_DIR=$(dirname "$VIDEO_PATH")
AUDIO_WAV="${VIDEO_DIR}/_temp_audio.wav"

echo "{\"status\":\"processing\",\"step\":\"extracting_audio\",\"video\":\"${VIDEO_PATH}\"}"

# Step 1: 用 ffmpeg 提取音频 (16kHz 单声道 WAV)
ffmpeg -i "$VIDEO_PATH" -ar 16000 -ac 1 -vn -y "$AUDIO_WAV" 2>&1 | tail -1

if [ ! -f "$AUDIO_WAV" ] || [ $(stat -c%s "$AUDIO_WAV" 2>/dev/null || echo 0) -lt 1000 ]; then
    echo "{\"status\":\"failed\",\"error\":\"audio extraction failed\"}"
    exit 1
fi

echo "{\"status\":\"processing\",\"step\":\"transcribing\",\"model\":\"${MODEL_SIZE}\",\"language\":\"${LANGUAGE}\"}"

# Step 2: faster-whisper 转录 → 生成 SRT
python3 << PYEOF
import sys, os

VIDEO_PATH = """${VIDEO_PATH}"""
AUDIO_WAV = """${AUDIO_WAV}"""
OUTPUT_SRT = """${OUTPUT_SRT}"""
LANGUAGE = """${LANGUAGE}"""
MODEL_SIZE = """${MODEL_SIZE}"""

try:
    from faster_whisper import WhisperModel
except ImportError:
    print("ERROR: faster-whisper not installed. Run: pip install faster-whisper", file=sys.stderr)
    sys.exit(1)

# 检测 GPU 可用性
import os as _os
device = "cuda" if _os.environ.get("CUDA_VISIBLE_DEVICES") else "cpu"
compute_type = "float16" if device == "cuda" else "int8"

print(f"Loading model: {MODEL_SIZE} (device={device}, compute_type={compute_type})")
print(f"Note: First run will download the model (~75MB for tiny) to ~/.cache/huggingface/")

try:
    model = WhisperModel(MODEL_SIZE, device=device, compute_type=compute_type)
except Exception as e:
    print(f"Model load failed: {e}", file=sys.stderr)
    sys.exit(1)

print(f"Transcribing audio: {AUDIO_WAV}")
segments, info = model.transcribe(AUDIO_WAV, language=LANGUAGE, beam_size=5)
print(f"Detected language: {info.language} (probability: {info.language_probability:.2f})")

# 生成 SRT 格式
def format_time(seconds):
    """将秒数转换为 SRT 时间格式 HH:MM:SS,mmm"""
    ms = int((seconds % 1) * 1000)
    s = int(seconds) % 60
    m = (int(seconds) // 60) % 60
    h = int(seconds) // 3600
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

srt_blocks = []
idx = 1
for segment in segments:
    start = format_time(segment.start)
    end = format_time(segment.end)
    text = segment.text.strip()
    if text:
        srt_blocks.append(f"{idx}\n{start} --> {end}\n{text}\n")
        idx += 1

srt_content = "\n".join(srt_blocks)

os.makedirs(os.path.dirname(OUTPUT_SRT) if os.path.dirname(OUTPUT_SRT) else ".", exist_ok=True)
with open(OUTPUT_SRT, "w", encoding="utf-8") as f:
    f.write(srt_content)

duration_m = info.duration / 60
print(f"Transcription complete: {idx-1} segments, duration: {duration_m:.1f} min")
print(f"SRT saved: {OUTPUT_SRT}")
PYEOF

# Step 3: 清理临时音频文件
rm -f "$AUDIO_WAV"

# 输出结果
if [ -f "$OUTPUT_SRT" ]; then
    LINE_COUNT=$(wc -l < "$OUTPUT_SRT")
    SIZE=$(du -h "$OUTPUT_SRT" 2>/dev/null | cut -f1 || echo "unknown")
    echo "{\"status\":\"success\",\"output_srt\":\"${OUTPUT_SRT}\",\"lines\":${LINE_COUNT},\"size\":\"${SIZE}\"}"
else
    echo "{\"status\":\"failed\",\"error\":\"SRT file not created\"}"
    exit 1
fi
