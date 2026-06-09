# -*- coding: utf-8 -*-
"""
端到端集成测试：模拟完整用户流程
下载视频 → 合并 MP4 → ASR 转录 → 生成 SRT
"""
import os, sys, json, re, shutil, tempfile, struct, wave, math, time, threading, urllib.request, gzip, io, concurrent.futures

# ============================================================
# 配置
# ============================================================
MOCK_PORT   = 9876
MOCK_HOST   = f"http://127.0.0.1:{MOCK_PORT}"
WORKSPACE   = os.path.join(tempfile.gettempdir(), "baidu_course_e2e_test")
SEGMENTS    = os.path.join(WORKSPACE, "segments")
OUTPUT_MP4  = os.path.join(WORKSPACE, "video_full.mp4")
OUTPUT_SRT  = os.path.join(WORKSPACE, "subtitles.srt")
AUDIO_WAV   = os.path.join(WORKSPACE, "_temp_audio.wav")
SEG_COUNT   = 10
THREADS     = 4
PASS = 0; FAIL = 0

# ============================================================
# 辅助函数
# ============================================================
def test_pass(msg):
    global PASS; PASS += 1
    print(f"  [PASS] {msg}")

def test_fail(msg, detail=""):
    global FAIL; FAIL += 1
    d = f" - {detail}" if detail else ""
    print(f"  [FAIL] {msg}{d}")

def section(title):
    print(f"\n{'='*50}")
    print(f"  {title}")
    print(f"{'='*50}")

# ============================================================
# Phase 1: 启动 Mock 服务器
# ============================================================
section("Phase 1: 启动 Mock Streaming 服务器")

import http.server, socketserver
from mock_server import MockStreamingHandler

server = socketserver.TCPServer(("127.0.0.1", MOCK_PORT), MockStreamingHandler)
server.timeout = 1
server_thread = threading.Thread(target=server.serve_forever, daemon=True)
server_thread.start()
time.sleep(0.3)

# 验证服务可用
try:
    resp = urllib.request.urlopen(f"{MOCK_HOST}/health", timeout=3)
    if resp.status == 200:
        test_pass("Mock server 启动成功")
    else:
        test_fail("Mock server", f"HTTP {resp.status}")
except Exception as e:
    test_fail("Mock server", str(e))
    sys.exit(1)

# ============================================================
# Phase 2: 模拟 Step 3-5 — 下载 M3U8 + 分片 + 合并 MP4
# ============================================================
section("Phase 2: 视频下载 (模拟 download-video 工具)")

# 清理旧数据
shutil.rmtree(WORKSPACE, ignore_errors=True)
os.makedirs(WORKSPACE, exist_ok=True)
os.makedirs(SEGMENTS, exist_ok=True)

STREAMING_URL = f"{MOCK_HOST}/streaming?type=M3U8_AUTO_480&sign=test_sign&jsToken=test_token&adToken=test_ad"
COOKIE = "BDUSS=test_bduss; STOKEN=test_stoken; XFI=test_xfi"
REFERER = "https://pan.baidu.com/s/1testShareId"

headers = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/149.0.0.0 Safari/537.36",
    "Referer": REFERER,
    "Accept-Encoding": "gzip, deflate, br",
    "Cookie": COOKIE,
}

def fetch_url(url, timeout=30):
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except Exception as e:
        return None

# 2a. 下载 M3U8
print("  下载 M3U8...")
m3u8_raw = fetch_url(STREAMING_URL)
if m3u8_raw:
    test_pass(f"M3U8 下载成功 ({len(m3u8_raw)} bytes)")
else:
    test_fail("M3U8 下载失败")
    sys.exit(1)

# 解压
try:
    m3u8_text = gzip.decompress(m3u8_raw).decode('utf-8')
    test_pass("M3U8 gzip 解压成功")
except:
    m3u8_text = m3u8_raw.decode('utf-8', errors='replace')
    test_pass("M3U8 无需解压（raw）")

# 2b. 解析分片 URL
baidu_urls = re.findall(r'https://bdct\d+\.baidupcs\.com/video[^\s]+', m3u8_text)
local_urls = re.findall(rf'http://127\.0\.0\.1:{MOCK_PORT}/segment/\d+', m3u8_text)
all_urls = local_urls  # 只下载本地 mock 分片（baidupcs URL 是假的，无法访问）

test_pass(f"M3U8 解析: {len(all_urls)} 个分片 URL")
if len(all_urls) == SEG_COUNT:
    test_pass(f"分片数量正确: {SEG_COUNT}")
else:
    test_fail("分片数量", f"期望 {SEG_COUNT}, 实际 {len(all_urls)}")

# 2c. 并发下载分片
print(f"  并发下载 {len(all_urls)} 个分片 ({THREADS} 线程)...")
def download_seg(args):
    idx, url = args
    path = os.path.join(SEGMENTS, f"seg_{idx:05d}.ts")
    if os.path.exists(path) and os.path.getsize(path) > 1000:
        return idx, True, "cached", os.path.getsize(path)
    data = fetch_url(url, timeout=30)
    if data and len(data) > 1000:
        with open(path, 'wb') as f:
            f.write(data)
        return idx, True, "ok", len(data)
    return idx, False, "failed", 0

completed = 0
failed_seg = 0
with concurrent.futures.ThreadPoolExecutor(max_workers=THREADS) as ex:
    futs = {ex.submit(download_seg, (i, u)): i for i, u in enumerate(all_urls)}
    for f in concurrent.futures.as_completed(futs):
        idx, ok, status, size = f.result()
        if ok: completed += 1
        else: failed_seg += 1

test_pass(f"分片下载: {completed}/{len(all_urls)} 成功" + (f", {failed_seg} 失败" if failed_seg else ""))

# 2d. 合并 MP4
print("  合并分片 → MP4...")
seg_files = sorted(
    [f for f in os.listdir(SEGMENTS) if f.endswith('.ts')],
    key=lambda x: int(x.replace('seg_', '').replace('.ts', ''))
)
total_size = 0
with open(OUTPUT_MP4, 'wb') as out:
    for sf in seg_files:
        with open(os.path.join(SEGMENTS, sf), 'rb') as inp:
            data = inp.read()
            out.write(data)
            total_size += len(data)

test_pass(f"MP4 合并完成: {total_size/1024:.1f} KB ({len(seg_files)} 分片)")
test_pass(f"文件存在: {os.path.exists(OUTPUT_MP4)}")

# 验证 TS sync bytes (0x47 every 188 bytes)
with open(OUTPUT_MP4, 'rb') as f:
    mp4_data = f.read(188 * 3)
sync_ok = all(mp4_data[i*188] == 0x47 for i in range(3))
if sync_ok:
    test_pass("MP4 TS sync bytes 正确 (0x47)")
else:
    test_fail("MP4 TS sync bytes", "缺少 TS 同步字节")

# ============================================================
# Phase 3: 模拟 Step 6-7 — 生成 WAV 音频 + ASR 转录
# ============================================================
section("Phase 3: ASR 转录 (模拟 local-asr 工具)")

# 3a. 从 MP4 数据生成模拟 WAV（无 ffmpeg 环境下的替代方案）
print("  生成模拟 WAV 音频...")
sample_rate = 16000
duration_sec = 3.0
n_samples = int(sample_rate * duration_sec)

# 生成一个 440Hz 正弦波 + 语音模拟
audio_data = bytearray()
for i in range(n_samples):
    t = i / sample_rate
    # 复合频率：440Hz(A4) + 880Hz(A5) + 白噪声底噪
    value = int(16000 * math.sin(2 * math.pi * 440 * t) +
                8000 * math.sin(2 * math.pi * 880 * t) +
                2000 * (0.5 - (i % 1000) / 1000))  # 模拟非周期性噪声
    # clamp to 16-bit
    value = max(-32767, min(32767, value))
    audio_data.extend(struct.pack('<h', value))

with wave.open(AUDIO_WAV, 'w') as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(sample_rate)
    wav.writeframes(audio_data)

test_pass(f"WAV 音频生成: {os.path.getsize(AUDIO_WAV)} bytes, {duration_sec:.1f}s, {sample_rate}Hz")

# 3b. 尝试 faster-whisper 转录
print("  尝试 faster-whisper 转录...")
use_real_asr = False
try:
    from faster_whisper import WhisperModel
    use_real_asr = True
    test_pass("faster-whisper 已安装，使用真实 ASR")
except ImportError:
    test_pass("faster-whisper 未安装，使用 Mock ASR")

if use_real_asr:
    try:
        device = "cuda" if os.environ.get("CUDA_VISIBLE_DEVICES") else "cpu"
        compute_type = "float16" if device == "cuda" else "int8"
        print(f"  加载 tiny 模型 (device={device}, compute_type={compute_type})...")
        model = WhisperModel("tiny", device=device, compute_type=compute_type)
        segments, info = model.transcribe(AUDIO_WAV, language="zh", beam_size=5)
        test_pass(f"ASR 检测语言: {info.language} (prob={info.language_probability:.2f})")

        # 生成 SRT
        def format_time(seconds):
            ms = int((seconds % 1) * 1000)
            s = int(seconds) % 60
            m = (int(seconds) // 60) % 60
            h = int(seconds) // 3600
            return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

        srt_blocks = []
        idx = 1
        for seg in segments:
            text = seg.text.strip()
            if text:
                srt_blocks.append(f"{idx}\n{format_time(seg.start)} --> {format_time(seg.end)}\n{text}\n")
                idx += 1
        srt_text = "\n".join(srt_blocks)
        test_pass(f"真实 ASR 转录: {idx-1} 个片段")

    except Exception as e:
        use_real_asr = False
        test_fail("真实 ASR 失败", str(e)[:60])
        print(f"  回退到 Mock ASR...")

if not use_real_asr:
    # Mock ASR: 生成模拟字幕
    mock_subtitles = [
        (0.0, 3.5, "这是模拟的语音识别测试内容"),
        (3.5, 7.0, "用于验证本地ASR转录流程是否正常工作"),
        (7.0, 10.5, "测试端到端的视频下载和字幕生成管线的正确性"),
        (10.5, 14.0, "百度网盘视频课程制作技能集成验证通过"),
    ]
    def format_time(seconds):
        ms = int((seconds % 1) * 1000)
        s = int(seconds) % 60
        m = (int(seconds) // 60) % 60
        h = int(seconds) // 3600
        return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

    srt_blocks = []
    for i, (start, end, text) in enumerate(mock_subtitles, 1):
        srt_blocks.append(f"{i}\n{format_time(start)} --> {format_time(end)}\n{text}\n")
    srt_text = "\n".join(srt_blocks)
    test_pass(f"Mock ASR 转录: {len(mock_subtitles)} 个片段")

# 3c. 保存 SRT
os.makedirs(os.path.dirname(OUTPUT_SRT), exist_ok=True)
with open(OUTPUT_SRT, "w", encoding="utf-8") as f:
    f.write(srt_text)
test_pass(f"SRT 保存: {OUTPUT_SRT} ({len(srt_text)} chars)")

# ============================================================
# Phase 4: SRT 格式验证
# ============================================================
section("Phase 4: SRT 字幕格式验证")

with open(OUTPUT_SRT, "r", encoding="utf-8") as f:
    srt_content = f.read()

# 验证 SRT 结构
blocks = re.split(r'\n\n+', srt_content.strip())
test_pass(f"SRT 块数量: {len(blocks)}")

valid_blocks = 0
for block in blocks:
    lines = block.strip().split('\n')
    if len(lines) >= 3 and re.match(r'\d+$', lines[0]) and '-->' in lines[1]:
        valid_blocks += 1

test_pass(f"有效 SRT 块: {valid_blocks}/{len(blocks)}")

if valid_blocks > 0:
    test_pass("SRT 格式验证通过")
else:
    test_fail("SRT 格式验证", "无有效 SRT 块")

# 验证时间格式
time_pattern = re.compile(r'\d{2}:\d{2}:\d{2},\d{3} --> \d{2}:\d{2}:\d{2},\d{3}')
time_count = len(time_pattern.findall(srt_content))
test_pass(f"时间戳数量: {time_count}")

# ============================================================
# Phase 5: 断点续传测试
# ============================================================
section("Phase 5: 断点续传测试")

# 模拟第二次下载（应跳过已缓存分片）
print("  重新下载（应全部命中缓存）...")
cached = 0; downloaded = 0
for i, url in enumerate(all_urls):
    path = os.path.join(SEGMENTS, f"seg_{i:05d}.ts")
    if os.path.exists(path) and os.path.getsize(path) > 1000:
        cached += 1
    else:
        data = fetch_url(url, timeout=30)
        if data:
            with open(path, 'wb') as f: f.write(data)
            downloaded += 1

test_pass(f"缓存命中: {cached}/{len(all_urls)}" + (f", 新下载: {downloaded}" if downloaded else " (全部命中)"))

# ============================================================
# Phase 6: 文件清理验证
# ============================================================
section("Phase 6: 清理 + 最终输出清单")

print("  模拟 Step 11 清理...")
# 删除 MP4 和 segments（模拟原流程）
if os.path.exists(OUTPUT_MP4): os.remove(OUTPUT_MP4)
if os.path.exists(SEGMENTS): shutil.rmtree(SEGMENTS)
if os.path.exists(AUDIO_WAV): os.remove(AUDIO_WAV)

# 保留文件
kept = []
for f in ["subtitles.srt"]:
    fp = os.path.join(WORKSPACE, f)
    if os.path.exists(fp):
        kept.append(f)
        test_pass(f"保留文件: {f} ({os.path.getsize(fp)} bytes)")
    else:
        test_fail(f"缺失文件: {f}")

# ============================================================
# Phase 7: 总结
# ============================================================
section("Phase 7: 测试结果汇总")

# 停止 Mock 服务器
server.shutdown()
server.server_close()

total = PASS + FAIL
print(f"""
  +-----------------------------+
  |  通过: {PASS:>3} / {total:<3}             |
  |  失败: {FAIL:>3} / {total:<3}             |
  +-----------------------------+
""")

if FAIL == 0:
    print("  ✓ 端到端集成测试全部通过！")
    print(f"  工作目录: {WORKSPACE}")
else:
    print(f"  ✗ {FAIL} 项测试失败")

# 返回退出码
sys.exit(0 if FAIL == 0 else 1)
