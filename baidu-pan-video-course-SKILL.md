# Baidu Pan Video → Course Materials Skill

> **版本：** v1.0  
> **日期：** 2026-06-08  
> **验证：** 基于太卜风水术01.mp4（百度网盘分享）实战完成  
> **触发词：** "百度网盘视频课件", "视频转课程", "下载视频做PPT", "baidu pan video course"

---

## 一、概述

本 Skill 实现从百度网盘分享链接出发，自动完成以下全流程：

```
分享链接 + 账号密码
    ↓
① 浏览器登录百度（如需）
    ↓
② 导航分享链接，等待视频加载
    ↓
③ DevTools Network 拦截 streaming 请求
    ↓
④ 提取 M3U8 + 分片 URL + Cookie
    ↓
⑤ 并发下载全部 TS 分片 → 合并 MP4
    ↓
⑥ 提取百度 AI 字幕（SRT）
    ↓
⑦ 本地 ASR local-asr（full JSON + TXT + 说话人识别）
    ↓
⑧ 浏览器 JS 控制视频截帧（每2分钟一张）
    ↓
⑨ 生成 ASR 完整记录 + 视频总结报告（generate-report）
    ↓
⑩ 删除视频文件（保留字幕/ASR记录/报告）
```

---

## 二、workspace 路径约定

所有文件均存储在本地 workspace 目录：

```
WORKSPACE = "/home/adambb/.openclaw/workspace_soft/baidu_course"
```

| 子目录/文件 | 用途 | 处理 |
|------------|------|------|
| `video_full.mp4` | 合并后的完整视频 | ❌ 完成后删除 |
| `segments/` | TS 分片缓存目录 | ❌ 合并后删除 |
| `subtitles.srt` | 百度 AI 字幕 | ✅ 保留 |
| `transcript_full.json` | 全量转录 JSON（片段+单词级时间轴+说话人标签） | ✅ 保留 |
| `transcript_detailed.txt` | 详细文字稿（时间轴+说话人标记+分组） | ✅ 保留 |
| `transcript_summary.json` | 转录总结（时长/说话人/片段统计） | ✅ 保留 |
| `ASR_完整记录.docx` | ASR 完整转录记录 Word 文档 | ✅ 保留 |
| `视频总结报告.docx` | 视频内容总结报告 Word 文档 | ✅ 保留 |
| `frames/` | 视频关键帧截图 | ✅ 保留 |

---

## 三、工具依赖

| 工具 | 用途 | 安装方式 |
|------|------|----------|
| `chrome-devtools` | 浏览器控制、Network 抓包 | OpenClaw 内置插件 |
| `python-docx` | ASR 报告 Word 文档生成 | `pip install python-docx` |
| `faster-whisper` | 本地 ASR 语音转文字（含说话人识别） | `pip install faster-whisper` |
| `ffmpeg` | 视频音频提取 | `apt install ffmpeg / brew install ffmpeg` |
| Python 3 | 下载、解析、合并、报告生成 | 系统自带 |

**Python 标准库（无需安装）：**
- `urllib.request` — HTTP 下载
- `re` — 正则解析 M3U8 和 SRT
- `concurrent.futures` — 8线程并发
- `gzip` / `zlib` — 解压响应
- `os` / `shutil` — 文件操作

---

## 四、Step-by-Step 详解

### Step 1 — 登录百度（如未登录）

```
chrome-devtools__navigate_page → https://pan.baidu.com
chrome-devtools__take_snapshot
```

如页面含"登录"按钮：
1. 点击登录按钮
2. `chrome-devtools__fill_form` 填入账号 + 密码
3. 如需验证码 → 暂停并询问用户：「需要百度账号验证码，请提供」
4. 等待跳转完成，再次 `take_snapshot` 确认已登录

---

### Step 2 — 导航到分享链接

```
chrome-devtools__navigate_page(url="https://pan.baidu.com/s/{SHARE_ID}?pwd={PASSWORD}")
chrome-devtools__wait_for(text=["视频", "时长", "24:", "百度网盘"], timeout=30000)
```

等待视频播放器出现（页面显示时长如 "24:34"）。

---

### Step 3 — 提取 Streaming URL（核心步骤）

**目标：** 在 Network 请求中找到 `share/streaming` XHR，提取完整 URL 和全部认证参数。

```
chrome-devtools__list_network_requests(resourceTypes=["xhr", "fetch"])
```

过滤条件：`URL 包含 "share/streaming"` 且 `type=M3U8`

找到后：
```
chrome-devtools__get_network_request(reqid="<streaming_reqid>")
```

**必须从 Request Headers 中提取的参数**（这些是 HttpOnly，无法从 Cookie jar 读取）：

| 参数 | 来源 | 说明 |
|------|------|------|
| `sign` | URL query / Request Header | JS 动态生成，约几分钟有效 |
| `jsToken` | URL query / Request Header | JS 动态生成 |
| `adToken` | URL query / Request Header | 播放器初始化时获取 |
| `Cookie` | Request Header | 完整字符串，含 BDUSS/XFI/XFT/STOKEN 等 |

**M3U8 响应体示例：**
```
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10,
https://bdct06.baidupcs.com/video/netdisk-videotran-xxx/{MD5}_1_ts/{ETAG}?range=0-341031&...
#EXTINF:10,
https://bdct06.baidupcs.com/video/netdisk-videotran-xxx/{MD5}_1_ts/{ETAG}?range=341032-605359&...
...
```

**太卜风水术01 实际数据：**
- 分片数：223 个
- 每片时长：约10秒
- 总时长：24分34秒
- 文件大小：66.35 MB

---

### Step 4 — 下载 TS 分片

Python 脚本（保存到 `~/workspace_soft/baidu_downloader.py`）：

```python
#!/usr/bin/env python3
"""百度网盘视频分片下载器"""

import urllib.request, re, os, concurrent.futures

# ===== workspace 路径配置 =====
WORKSPACE      = "/home/adambb/.openclaw/workspace_soft/baidu_course"
STREAMING_URL  = "<从DevTools提取的完整streaming URL>"
COOKIE         = "<从Request Headers提取的完整Cookie>"
OUTPUT_MP4     = f"{WORKSPACE}/video_full.mp4"
SEGMENTS_DIR   = f"{WORKSPACE}/segments"
THREADS        = 8

os.makedirs(WORKSPACE, exist_ok=True)
os.makedirs(SEGMENTS_DIR, exist_ok=True)

headers = {
    "User-Agent": "Mozilla/5.0 (X11; Ubuntu; Linux x86_64) AppleWebKit/537.36 Chrome/149.0.0.0 Safari/537.36",
    "Referer": "https://pan.baidu.com/s/1...",
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

# 1. 获取 M3U8
print("Fetching M3U8...")
m3u8_data = fetch_url(STREAMING_URL)
if not m3u8_data:
    print("FAILED: 无法获取 M3U8"); exit(1)

# 解压（gzip/br）
try:
    import brotli
    m3u8_text = brotli.decompress(m3u8_data).decode('utf-8')
except:
    try:
        import zlib
        m3u8_text = zlib.decompress(m3u8_data, 16 + zlib.MAX_WBITS).decode('utf-8')
    except:
        m3u8_text = m3u8_data.decode('utf-8', errors='replace')

# 2. 解析所有分片 URL
segment_urls = re.findall(r'https://bdct\d+\.baidupcs\.com/video[^\s]+', m3u8_text)
print(f"Total segments: {len(segment_urls)}")

# 3. 并发下载
def download_seg(args):
    idx, url = args
    path = f"{SEGMENTS_DIR}/seg_{idx:03d}.ts"
    if os.path.exists(path) and os.path.getsize(path) > 1000:
        return idx, True, "cached"
    data = fetch_url(url)
    if data and len(data) > 1000:
        with open(path, 'wb') as f: f.write(data)
        return idx, True, len(data)
    return idx, False, "failed"

print(f"Downloading {len(segment_urls)} segments...")
with concurrent.futures.ThreadPoolExecutor(max_workers=THREADS) as ex:
    futures = {ex.submit(download_seg, (i, u)): i for i, u in enumerate(segment_urls)}
    for f in concurrent.futures.as_completed(futures):
        idx, ok, sz = f.result()
        print(f"  [{idx+1}/{len(segment_urls)}] {'OK' if ok else 'FAIL'} ({sz})")

# 4. 合并为 MP4
print("Merging segments...")
with open(OUTPUT_MP4, 'wb') as out:
    for sf in sorted(os.listdir(SEGMENTS_DIR),
                    key=lambda x: int(x.split('_')[1].split('.')[0])):
        with open(os.path.join(SEGMENTS_DIR, sf), 'rb') as inp:
            out.write(inp.read())

print(f"Done: {OUTPUT_MP4} ({os.path.getsize(OUTPUT_MP4)/1024/1024:.1f} MB)")
```

**运行：**
```bash
python3 /home/adambb/.openclaw/workspace_soft/baidu_downloader.py
```

**注意：** `sign` 约几分钟过期。如下载中途出现 502/403，从 DevTools 重新获取 fresh URL，增量补全缺失分片。

---

### Step 5 — 提取 AI 字幕

在 DevTools Network 中找到字幕请求（`type=M3U8_SUBTITLE_SRT`），或直接替换 URL：

```python
SUBTITLE_URL = STREAMING_URL.replace("M3U8_AUTO_480", "M3U8_SUBTITLE_SRT")
```

保存并解析：

```python
import urllib.request, re

WORKSPACE = "/home/adambb/.openclaw/workspace_soft/baidu_course"
SUBTITLE_URL = "<从DevTools或STREAMING_URL替换获取>"
SUBTITLES_SRT = f"{WORKSPACE}/subtitles.srt"

req = urllib.request.Request(SUBTITLE_URL, headers=headers)
with urllib.request.urlopen(req) as resp:
    srt_text = resp.read().decode('utf-8', errors='replace')

with open(SUBTITLES_SRT, "w", encoding="utf-8") as f:
    f.write(srt_text)
print(f"Subtitles saved: {SUBTITLES_SRT}")

def parse_srt(text):
    entries = []
    for block in re.split(r'\n\n+', text.strip()):
        lines = block.split('\n')
        if len(lines) >= 3 and re.match(r'\d+$', lines[0]) and '-->' in lines[1]:
            tc = lines[1].split('-->')[0].strip()
            h, m, s = map(float, tc.split(':'))
            entries.append({'time': h*3600 + m*60 + s, 'text': '\n'.join(lines[2:])})
    return entries

entries = parse_srt(srt_text)
print(f"Total entries: {len(entries)}, Duration: {entries[-1]['time']:.0f}s")
```

太卜风水术01字幕：467条，覆盖 00:00 ~ 24:14。

---

### Step 6 — 提取关键帧

浏览器 JS 控制视频跳转时间，截图保存到 workspace：

```bash
WORKSPACE="/home/adambb/.openclaw/workspace_soft/baidu_course"

# 跳转到第2分钟
chrome-devtools__evaluate_script(function="() => { var v=document.querySelector('video'); if(v){v.currentTime=120;v.play();return'ok';}return'no'; }")
chrome-devtools__wait_for(text=["2:", "02:", "2分"], timeout=5000)
chrome-devtools__take_screenshot(filePath="${WORKSPACE}/frames/frame_2min.png")

# 跳转到第4分钟
chrome-devtools__evaluate_script(function="() => { var v=document.querySelector('video'); if(v){v.currentTime=240;return'ok';}return'no'; }")
chrome-devtools__wait_for(text=["4:", "04:", "4分"], timeout=5000)
chrome-devtools__take_screenshot(filePath="${WORKSPACE}/frames/frame_4min.png")
```

**推荐截帧时间点（每2分钟）：**
```
0:30, 2:00, 4:00, 6:00, 8:00, 10:00, 12:00, 14:00, 16:00, 18:00, 20:00, 22:00
```

**注意：** 视频必须已加载到该时间点，`wait_for` 确认时间显示更新后再截图。

---

---

### Step 7 — 清理视频文件

```python
import os, shutil

WORKSPACE = "/home/adambb/.openclaw/workspace_soft/baidu_course"
paths = [
    f"{WORKSPACE}/video_full.mp4",
    f"{WORKSPACE}/segments/",
]

for p in paths:
    if os.path.isfile(p):
        os.remove(p)
        print(f"Deleted: {p}")
    elif os.path.isdir(p):
        shutil.rmtree(p)
        print(f"Deleted dir: {p}")

# 保留的文件
print(f"Kept: {WORKSPACE}/subtitles.srt")
```

---

## 五、错误处理

| 错误信息 | 原因 | 解决方案 |
|----------|------|----------|
| `Recorder not found` | 浏览器页面被重置 | 重新 `navigate_page` 到视频页 |
| `Overload resolution failed`（AudioNode）| Headless Chrome 音频路由限制 | 使用百度内置 AI 字幕代替 MediaRecorder |
| `sign` 过期（502/403）| JS token 过期 | 从 DevTools 重新获取 fresh streaming URL |
| `ffprobe not found` | ffmpeg 未安装 | 使用百度 AI 字幕代替 |
| `IndexError: list index out of range` | SRT 解析格式不匹配 | 改用 `re.split(r'\n\n+', srt_text)` 分割块 |

---

## 六、百度网盘 Streaming 技术参数

### 完整 URL 模板
```
https://pan.baidu.com/share/streaming
  ?channel=chunlei
  &uk=<USER_UK>            # 从分享链接提取
  &fid=<FILE_ID>           # 从分享链接提取
  &sign=<JS_SIGN>           # 从请求头提取（HttpOnly）
  &timestamp=<UNIX_TS>
  &shareid=<SHARE_ID>
  &type=M3U8_AUTO_480       # 480p 流畅画质
  &vip=0
  &jsToken=<JS_TOKEN>       # 从请求头提取（HttpOnly）
  &isplayer=1
  &check_blue=1
  &adToken=<AD_TOKEN>       # 从请求头提取
```

### 必须从 Request Headers 提取（不是 Cookie jar）
- `sign` — JS 动态生成，HttpOnly
- `jsToken` — JS 动态生成，HttpOnly
- `adToken` — 播放器初始化获取
- 完整 Cookie 字符串（含 `BDUSS`, `csrfToken`, `XFI`, `XFT`, `STOKEN`, `PANPSC` 等）

### 字幕 URL
```
https://pan.baidu.com/share/streaming?...&type=M3U8_SUBTITLE_SRT
# 响应：纯 SRT 文本，直接保存到 WORKSPACE/subtitles.srt
```

---

## 七、文件输出清单

所有输出文件均位于 `~/workspace_soft/baidu_course/`：

| 文件 | 路径（workspace） | 处理 |
|------|------|------|
| 视频 MP4 | `workspace_soft/baidu_course/video_full.mp4` | ❌ 下载完成后删除 |
| TS 分片目录 | `workspace_soft/baidu_course/segments/` | ❌ 合并后删除 |
| 字幕 SRT | `workspace_soft/baidu_course/subtitles.srt` | ✅ 保留 |
| 全量转录 JSON | `workspace_soft/baidu_course/transcript_full.json` | ✅ 保留 |
| 详细文字稿 TXT | `workspace_soft/baidu_course/transcript_detailed.txt` | ✅ 保留 |
| 转录总结 JSON | `workspace_soft/baidu_course/transcript_summary.json` | ✅ 保留 |
| ASR 完整记录 DOCX | `workspace_soft/baidu_course/ASR_完整记录.docx` | ✅ 保留 |
| 视频总结报告 DOCX | `workspace_soft/baidu_course/视频总结报告.docx` | ✅ 保留 |
| 关键帧图片 | `workspace_soft/baidu_course/frames/` | ✅ 保留 |

---

## 八、核心难点提示

1. **`sign` 是 HttpOnly** — 必须从 Network 请求头提取，不是 `document.cookie`
2. **百度 streaming 按需加载** — 需滑动视频进度条触发更多分片请求
3. **Headless Chrome AudioNode 不可用** — 音频录制失败，用百度内置 AI 字幕代替
4. **`sign` 有效期短** — 下载 223 个分片（约5-10分钟）期间可能过期，需增量刷新

---

*本 Skill 基于太卜风水术01.mp4 实战验证生成。百度网盘视频策略可能随版本更新变化，如遇接口变更请重新从 DevTools 提取 fresh URL。*