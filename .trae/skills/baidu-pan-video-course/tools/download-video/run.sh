#!/bin/bash
# download-video: 百度网盘视频 TS 分片并发下载器
# 从 stdin 读取 JSON 参数，动态生成 Python 脚本并执行

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)

# 解析 JSON 参数
STREAMING_URL=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['streaming_url'])")
COOKIE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['cookie'])")
REFERER=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['referer'])")
WORKSPACE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['workspace'])")
THREADS=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('threads', 8))")

OUTPUT_MP4="${WORKSPACE}/video_full.mp4"
SEGMENTS_DIR="${WORKSPACE}/segments"

# 创建 workspace
mkdir -p "$WORKSPACE" "$SEGMENTS_DIR"

# 动态生成 Python 下载脚本
python3 << PYEOF
import urllib.request, re, os, concurrent.futures, sys

STREAMING_URL = """${STREAMING_URL}"""
COOKIE = """${COOKIE}"""
REFERER = """${REFERER}"""
WORKSPACE = """${WORKSPACE}"""
OUTPUT_MP4 = """${OUTPUT_MP4}"""
SEGMENTS_DIR = """${SEGMENTS_DIR}"""
THREADS = ${THREADS}

headers = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36",
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
        print(f"  [ERROR] fetch failed: {e}", file=sys.stderr)
        return None

# 1. 获取 M3U8
print("Fetching M3U8...")
m3u8_data = fetch_url(STREAMING_URL)
if not m3u8_data:
    print("FAILED: unable to fetch M3U8")
    sys.exit(1)

# 解压响应 (gzip / br / raw)
m3u8_text = None
try:
    import brotli
    m3u8_text = brotli.decompress(m3u8_data).decode('utf-8')
    print("Decompressed: brotli")
except:
    try:
        import zlib
        m3u8_text = zlib.decompress(m3u8_data, 16 + zlib.MAX_WBITS).decode('utf-8')
        print("Decompressed: gzip")
    except:
        m3u8_text = m3u8_data.decode('utf-8', errors='replace')
        print("No compression detected")

# 2. 解析所有分片 URL
segment_urls = re.findall(r'https://bdct\d+\.baidupcs\.com/video[^\s]+', m3u8_text)
if not segment_urls:
    # 备选：匹配任何以 https:// 开头且含 baidupcs 的 URL
    segment_urls = re.findall(r'https?://[^\s]*baidupcs[^\s]*', m3u8_text)
print(f"Total segments found: {len(segment_urls)}")

# 3. 并发下载
def download_seg(args):
    idx, url = args
    path = os.path.join(SEGMENTS_DIR, f"seg_{idx:05d}.ts")
    # 断点续传：已缓存且大小 > 1KB 则跳过
    if os.path.exists(path) and os.path.getsize(path) > 1000:
        return idx, True, "cached", os.path.getsize(path)
    data = fetch_url(url, timeout=60)
    if data and len(data) > 1000:
        with open(path, 'wb') as f:
            f.write(data)
        return idx, True, "ok", len(data)
    return idx, False, "failed", 0

print(f"Downloading {len(segment_urls)} segments with {THREADS} threads...")
completed, failed = 0, 0
with concurrent.futures.ThreadPoolExecutor(max_workers=THREADS) as ex:
    futures = {ex.submit(download_seg, (i, u)): i for i, u in enumerate(segment_urls)}
    for f in concurrent.futures.as_completed(futures):
        idx, ok, status, size = f.result()
        if ok:
            completed += 1
        else:
            failed += 1
        mb = size / 1024 / 1024
        print(f"  [{idx+1}/{len(segment_urls)}] {'OK' if ok else 'FAIL'} | {status} | {mb:.2f} MB")

print(f"\nDownload complete: {completed} OK, {failed} FAILED")

if failed > len(segment_urls) * 0.1:
    print(f"WARNING: {failed} segments failed (>10%). sign may have expired. Re-fetch streaming URL and retry.")

# 4. 合并为 MP4
print("Merging segments into MP4...")
seg_files = sorted(
    [f for f in os.listdir(SEGMENTS_DIR) if f.endswith('.ts')],
    key=lambda x: int(x.replace('seg_', '').replace('.ts', ''))
)
total_size = 0
with open(OUTPUT_MP4, 'wb') as out:
    for sf in seg_files:
        sp = os.path.join(SEGMENTS_DIR, sf)
        with open(sp, 'rb') as inp:
            data = inp.read()
            out.write(data)
            total_size += len(data)

print(f"Done: {OUTPUT_MP4} ({total_size/1024/1024:.1f} MB, {len(seg_files)} segments)")
PYEOF

# 输出结果
if [ -f "$OUTPUT_MP4" ]; then
    SIZE=$(du -h "$OUTPUT_MP4" 2>/dev/null | cut -f1 || echo "unknown")
    echo "{\"status\":\"success\",\"output_mp4\":\"${OUTPUT_MP4}\",\"size\":\"${SIZE}\"}"
else
    echo "{\"status\":\"failed\",\"error\":\"MP4 file not created\"}"
    exit 1
fi
