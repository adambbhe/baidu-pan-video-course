#!/bin/bash
# local-asr: 本地语音识别工具（增强版）
# 使用 ffmpeg 提取音频 + faster-whisper 模型转录
# 输出：
#   1. SRT 字幕（兼容原格式）
#   2. 全量转录 JSON（含时间戳、置信度、说话人标签）
#   3. 详细文字稿 TXT（含说话人标记、时间轴）
# 从 stdin 读取 JSON 参数

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)

# 解析 JSON 参数
VIDEO_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['video_path'])")
OUTPUT_DIR=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('output_dir', os.path.dirname(json.load(sys.stdin)['output_srt'])))" 2>/dev/null || echo "$(dirname "$VIDEO_PATH")")
LANGUAGE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('language', 'zh'))")
MODEL_SIZE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('model_size', 'tiny'))")
ENABLE_SPEAKER_DIARIZATION=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('enable_speaker_diarization', 'true'))")
BEAM_SIZE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('beam_size', 5))")

# 文件路径
VIDEO_BASENAME=$(basename "$VIDEO_PATH" .mp4)
OUTPUT_SRT="${OUTPUT_DIR}/subtitles.srt"
OUTPUT_JSON="${OUTPUT_DIR}/transcript_full.json"
OUTPUT_TXT="${OUTPUT_DIR}/transcript_detailed.txt"
OUTPUT_SUMMARY="${OUTPUT_DIR}/transcript_summary.json"

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

mkdir -p "$OUTPUT_DIR"

VIDEO_DIR="$(dirname "$VIDEO_PATH")"
AUDIO_WAV="${VIDEO_DIR}/_temp_audio_$$.wav"

echo "{\"status\":\"processing\",\"step\":\"extracting_audio\",\"video\":\"${VIDEO_PATH}\"}"

# Step 1: 用 ffmpeg 提取音频 (16kHz 单声道 WAV)
ffmpeg -i "$VIDEO_PATH" -ar 16000 -ac 1 -vn -y "$AUDIO_WAV" 2>&1 | tail -1

if [ ! -f "$AUDIO_WAV" ] || [ $(stat -c%s "$AUDIO_WAV" 2>/dev/null || echo 0) -lt 1000 ]; then
    echo "{\"status\":\"failed\",\"error\":\"audio extraction failed\"}"
    exit 1
fi

AUDIO_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$AUDIO_WAV" 2>/dev/null || echo 0)
echo "{\"status\":\"processing\",\"step\":\"transcribing\",\"model\":\"${MODEL_SIZE}\",\"language\":\"${LANGUAGE}\",\"audio_duration_sec\":${AUDIO_DURATION}}"

# Step 2: faster-whisper 转录 → 全量输出
python3 << PYEOF
import sys, os, json, math

VIDEO_PATH = """${VIDEO_PATH}"""
AUDIO_WAV = """${AUDIO_WAV}"""
OUTPUT_DIR = """${OUTPUT_DIR}"""
OUTPUT_SRT = """${OUTPUT_SRT}"""
OUTPUT_JSON = """${OUTPUT_JSON}"""
OUTPUT_TXT = """${OUTPUT_TXT}"""
OUTPUT_SUMMARY = """${OUTPUT_SUMMARY}"""
LANGUAGE = """${LANGUAGE}"""
MODEL_SIZE = """${MODEL_SIZE}"""
ENABLE_DIARIZATION = """${ENABLE_SPEAKER_DIARIZATION}""".lower() == 'true'
BEAM_SIZE = ${BEAM_SIZE}
AUDIO_DURATION = float("""${AUDIO_DURATION}""" or 0)

try:
    from faster_whisper import WhisperModel
except ImportError:
    print("ERROR: faster-whisper not installed. Run: pip install faster-whisper", file=sys.stderr)
    sys.exit(1)

# 检测 GPU 可用性
device = "cuda" if os.environ.get("CUDA_VISIBLE_DEVICES") else "cpu"
compute_type = "float16" if device == "cuda" else "int8"

print(f"Loading model: {MODEL_SIZE} (device={device}, compute_type={compute_type})")

try:
    model = WhisperModel(MODEL_SIZE, device=device, compute_type=compute_type)
except Exception as e:
    print(f"Model load failed: {e}", file=sys.stderr)
    sys.exit(1)

print(f"Transcribing audio: {AUDIO_WAV}")
segments, info = model.transcribe(
    AUDIO_WAV,
    language=LANGUAGE,
    beam_size=BEAM_SIZE,
    vad_filter=True,
    vad_parameters=dict(
        min_silence_duration_ms=500,
        threshold=0.5,
        min_speech_duration_ms=250,
        max_speech_duration_s=30.0,
    ),
    word_timestamps=True,
)
print(f"Detected language: {info.language} (probability: {info.language_probability:.2f})")

# ========== 收集所有转录片段 ==========
all_segments = []
for seg in segments:
    words_info = []
    if seg.words:
        for w in seg.words:
            words_info.append({
                "word": w.word.strip(),
                "start": round(w.start, 2),
                "end": round(w.end, 2),
                "probability": round(float(w.probability), 3) if hasattr(w, 'probability') and w.probability else None,
            })
    all_segments.append({
        "id": len(all_segments) + 1,
        "start": round(seg.start, 2),
        "end": round(seg.end, 2),
        "duration": round(seg.end - seg.start, 2),
        "text": seg.text.strip(),
        "avg_logprob": round(float(seg.avg_logprob), 3) if hasattr(seg, 'avg_logprob') and seg.avg_logprob else None,
        "no_speech_prob": round(float(seg.no_speech_prob), 3) if hasattr(seg, 'no_speech_prob') and seg.no_speech_prob else None,
        "words": words_info,
        "speaker": None,
    })

if not all_segments:
    print("No transcription segments generated", file=sys.stderr)
    sys.exit(1)

# ========== 说话人识别（基于时序分析和停顿模式） ==========
if ENABLE_DIARIZATION:
    print("Running speaker diarization (timing-based clustering)...")
    # 策略：基于静默间隔和语速模式检测说话人切换
    # 将片段分组，相邻片段间的静默间隔 > 1.5s 视为可能的说话人切换
    # 同时根据语速（字/秒）辅助聚类
    
    segments_list = all_segments
    speaker_labels = []
    current_speaker = 1
    
    # 第一个片段
    speaker_labels.append(current_speaker)
    
    for i in range(1, len(segments_list)):
        prev = segments_list[i - 1]
        curr = segments_list[i]
        gap = curr["start"] - prev["end"]
        
        # 获取语速（字/秒）
        prev_speed = len(prev["text"]) / max(prev["duration"], 0.1)
        curr_speed = len(curr["text"]) / max(curr["duration"], 0.1)
        speed_diff = abs(prev_speed - curr_speed)
        
        # 判断是否切换说话人：
        # 1. 静默间隔 > 1.5s
        # 2. 或静默 > 0.8s 且语速差异 > 3
        # 3. 或静默 > 0.5s 且语速差异 > 5
        if gap > 1.5:
            current_speaker = 3 - current_speaker  # 在1和2之间切换
        elif gap > 0.8 and speed_diff > 3:
            current_speaker = 3 - current_speaker
        elif gap > 0.5 and speed_diff > 5:
            current_speaker = 3 - current_speaker
        
        speaker_labels.append(current_speaker)
    
    # 分配说话人标签
    for i, seg in enumerate(segments_list):
        seg["speaker"] = f"说话人{speaker_labels[i]}"
    
    # 统计说话人时长
    speaker_stats = {}
    for seg in segments_list:
        sp = seg["speaker"]
        if sp not in speaker_stats:
            speaker_stats[sp] = {"duration": 0, "segments": 0, "text": ""}
        speaker_stats[sp]["duration"] += seg["duration"]
        speaker_stats[sp]["segments"] += 1
        speaker_stats[sp]["text"] += seg["text"] + " "
    
    print(f"Speaker diarization complete: {len(speaker_stats)} speakers identified")
    for sp, stats in speaker_stats.items():
        dur_m = stats["duration"] / 60
        print(f"  {sp}: {dur_m:.1f} min, {stats['segments']} segments")

# ========== 输出 1: SRT 字幕 ==========
def format_time(seconds):
    ms = int((seconds % 1) * 1000)
    s = int(seconds) % 60
    m = (int(seconds) // 60) % 60
    h = int(seconds) // 3600
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

srt_blocks = []
for seg in all_segments:
    start = format_time(seg["start"])
    end = format_time(seg["end"])
    speaker_tag = f"[{seg['speaker']}] " if seg["speaker"] else ""
    text = f"{speaker_tag}{seg['text']}"
    srt_blocks.append(f"{seg['id']}\n{start} --> {end}\n{text}\n")

os.makedirs(os.path.dirname(OUTPUT_SRT) if os.path.dirname(OUTPUT_SRT) else ".", exist_ok=True)
with open(OUTPUT_SRT, "w", encoding="utf-8") as f:
    f.write("\n".join(srt_blocks))
print(f"SRT saved: {OUTPUT_SRT} ({len(srt_blocks)} blocks)")

# ========== 输出 2: 全量转录 JSON ==========
full_output = {
    "video_file": os.path.basename(VIDEO_PATH),
    "audio_duration_sec": AUDIO_DURATION or (all_segments[-1]["end"] if all_segments else 0),
    "duration_formatted": f"{int((AUDIO_DURATION or 0)//3600):02d}:{int((AUDIO_DURATION or 0)//60%60):02d}:{int((AUDIO_DURATION or 0)%60):02d}",
    "language": info.language,
    "language_probability": round(float(info.language_probability), 3),
    "model": MODEL_SIZE,
    "device": device,
    "transcription_params": {
        "beam_size": BEAM_SIZE,
        "vad_filter": True,
        "word_timestamps": True,
    },
    "speaker_diarization": {
        "enabled": ENABLE_DIARIZATION,
        "method": "timing-based clustering",
        "speaker_count": len(set(s["speaker"] for s in all_segments if s["speaker"])),
    } if ENABLE_DIARIZATION else {"enabled": False},
    "total_segments": len(all_segments),
    "segments": all_segments,
}

with open(OUTPUT_JSON, "w", encoding="utf-8") as f:
    json.dump(full_output, f, ensure_ascii=False, indent=2)
print(f"Full JSON transcript saved: {OUTPUT_JSON}")

# ========== 输出 3: 详细文字稿 TXT（带说话人标记和时间轴） ==========
txt_lines = []
txt_lines.append("=" * 70)
txt_lines.append(f"视频文件: {os.path.basename(VIDEO_PATH)}")
dur = AUDIO_DURATION or (all_segments[-1]["end"] if all_segments else 0)
txt_lines.append(f"音频时长: {int(dur//3600):02d}:{int(dur//60%60):02d}:{int(dur%60):02d}")
txt_lines.append(f"识别语言: {info.language}")
txt_lines.append(f"模型: {MODEL_SIZE}")
txt_lines.append(f"总片段数: {len(all_segments)}")
txt_lines.append("=" * 70)
txt_lines.append("")

# 完整时间轴文稿
txt_lines.append("【完整转写文稿】")
txt_lines.append("")

for seg in all_segments:
    ts = f"{int(seg['start']//60):02d}:{int(seg['start']%60):02d}"
    speaker = f"[{seg['speaker']}] " if seg["speaker"] else ""
    txt_lines.append(f"[{ts}] {speaker}{seg['text']}")

txt_lines.append("")
txt_lines.append("=" * 70)
txt_lines.append("")

# 纯文本（无时间戳）
txt_lines.append("【纯文字稿】")
txt_lines.append("")
pure_text = "\n".join(seg["text"] for seg in all_segments if seg["text"])
txt_lines.append(pure_text)

txt_lines.append("")
txt_lines.append("=" * 70)
txt_lines.append("")

# 按说话人分组
if ENABLE_DIARIZATION:
    txt_lines.append("【按说话人分组】")
    txt_lines.append("")
    speakers = {}
    for seg in all_segments:
        sp = seg.get("speaker", "未知")
        if sp not in speakers:
            speakers[sp] = []
        speakers[sp].append(seg)
    
    for sp_name, sp_segs in speakers.items():
        sp_dur = sum(s["duration"] for s in sp_segs)
        txt_lines.append(f"--- {sp_name} (共{len(sp_segs)}段, {sp_dur:.1f}秒) ---")
        for s in sp_segs:
            ts = f"{int(s['start']//60):02d}:{int(s['start']%60):02d}"
            txt_lines.append(f"  [{ts}] {s['text']}")
        txt_lines.append("")

with open(OUTPUT_TXT, "w", encoding="utf-8") as f:
    f.write("\n".join(txt_lines))
print(f"Detailed transcript saved: {OUTPUT_TXT}")

# ========== 输出 4: 总结 JSON ==========
total_duration = AUDIO_DURATION or (all_segments[-1]["end"] if all_segments else 0)
summary = {
    "video_file": os.path.basename(VIDEO_PATH),
    "total_duration_sec": total_duration,
    "total_duration_formatted": f"{int(total_duration//3600):02d}:{int(total_duration//60%60):02d}:{int(total_duration%60):02d}",
    "language": info.language,
    "language_probability": round(float(info.language_probability), 3),
    "model": MODEL_SIZE,
    "total_segments": len(all_segments),
    "total_words": sum(len(s["text"]) for s in all_segments),
    "segments_per_minute": round(len(all_segments) / max(total_duration / 60, 1), 1),
    "speaker_count": len(set(s.get("speaker") for s in all_segments if s.get("speaker"))),
    "speaker_stats": speaker_stats if ENABLE_DIARIZATION else {},
    "output_files": {
        "srt": str(OUTPUT_SRT),
        "json": str(OUTPUT_JSON),
        "txt": str(OUTPUT_TXT),
        "summary": str(OUTPUT_SUMMARY),
    }
}

with open(OUTPUT_SUMMARY, "w", encoding="utf-8") as f:
    json.dump(summary, f, ensure_ascii=False, indent=2)
print(f"Summary saved: {OUTPUT_SUMMARY}")

# ========== 最终统计输出 ==========
total_min = total_duration / 60
print(f"\n{'='*50}")
print(f"转录完成!")
print(f"  总时长: {total_min:.1f} 分钟")
print(f"  片段数: {len(all_segments)}")
print(f"  语言: {info.language}")
if ENABLE_DIARIZATION:
    print(f"  说话人: {len(set(s.get('speaker') for s in all_segments if s.get('speaker')))} 位")
print(f"{'='*50}")

PYEOF

# Step 3: 清理临时音频文件
rm -f "$AUDIO_WAV"

# 输出结果
if [ -f "$OUTPUT_SRT" ] && [ -f "$OUTPUT_JSON" ]; then
    SRT_LINES=$(wc -l < "$OUTPUT_SRT")
    JSON_SIZE=$(du -h "$OUTPUT_JSON" 2>/dev/null | cut -f1 || echo "unknown")
    echo "{\"status\":\"success\",\"output_srt\":\"${OUTPUT_SRT}\",\"output_json\":\"${OUTPUT_JSON}\",\"output_txt\":\"${OUTPUT_TXT}\",\"output_summary\":\"${OUTPUT_SUMMARY}\",\"srt_lines\":${SRT_LINES},\"json_size\":\"${JSON_SIZE}\"}"
else
    echo "{\"status\":\"failed\",\"error\":\"Output files not created\"}"
    exit 1
fi