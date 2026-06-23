# 百度网盘视频课程全流程 — 技术说明文档

> 基于太卜风水术01.mp4（百度网盘分享）的实际验证。记录完整工具链、技术原理、参数细节和已知限制。

---

## 一、整体流程

```
用户输入分享链接 + 账号（如需登录）
        ↓
① 浏览器登录百度（如未登录）
        ↓
② 导航到分享链接，等待视频播放器加载
        ↓
③ DevTools Network 拦截 share/streaming 请求
        ↓
④ 提取 M3U8 + 所有分片 URL + Cookie
        ↓
⑤ 并发下载全部 TS 分片 → 合并为 MP4
        ↓
⑥ 提取 AI 字幕（SRT）
        ↓
⑦ 本地 ASR local-asr（全量 JSON + TXT + 说话人识别）
        ↓
⑧ 浏览器 JS 控制视频跳转关键帧 → 截图
    ↓
⑨ 生成 ASR 完整记录 + 视频总结报告（generate-report, python-docx）
    ↓
⑩ 删除视频文件（保留字幕/ASR记录/报告/截图）
```

---

## 二、工具依赖

| 工具 | 版本/来源 | 用途 |
|------|----------|------|
| **chrome-devtools** | OpenClaw 内置 | 浏览器自动化：登录、播放、Network 抓包 |
| **python-docx** | `pip install python-docx` | ASR 报告 Word 文档生成（ASR_完整记录.docx + 视频总结报告.docx） |
| **faster-whisper** | `pip install faster-whisper` | 本地 ASR 语音转文字 + 说话人识别 |
| **ffmpeg** | `apt install ffmpeg` | 视频音频提取（16kHz 单声道 WAV） |
| Python 3 | 标准库 | 并发下载、SRT 解析、文件合并、报告生成 |
| `re` / `urllib` / `concurrent.futures` | Python 内置 | HTTP 请求、分片下载、并发控制 |
| `gzip` / `zlib` | Python 内置 | 解压 M3U8 响应 |
| `brotli` | `pip install brotli` (可选) | 解压 br 压缩响应 |

**已安装并成为核心依赖：**
- `ffmpeg` — 音频提取（16kHz WAV，faster-whisper 输入）
- `faster-whisper` — 语音转文字 + 说话人识别

**未成功安装（可绕过）：**
- `opencv` — 视频帧提取（用浏览器 JS 截图替代）

---

## 三、百度网盘视频下载原理

### 3.1 Streaming URL 的结构

百度网盘分享视频通过 `share/streaming` API 以 HLS (M3U8) 协议分发。

完整 URL 模板：
```
https://pan.baidu.com/share/streaming
  ?channel=chunlei
  &uk=<USER_UK>               # 分享者的 UK（从分享链接提取）
  &fid=<FILE_ID>              # 文件 ID（从分享链接提取）
  &sign=<DYNAMIC_SIGN>         # JS 动态生成，HttpOnly
  &timestamp=<UNIX_TS>         # Unix 时间戳
  &shareid=<SHARE_ID>          # 分享 ID
  &type=M3U8_AUTO_480          # 画质：480p 流畅
  &vip=0                       # 非会员
  &jsToken=<JS_TOKEN>           # JS 动态生成
  &isplayer=1
  &check_blue=1
  &adToken=<AD_TOKEN>           # 播放器初始化获取
```

### 3.2 关键参数提取方法

**绝对不能从 Cookie jar 读取的参数**（因为是 HttpOnly）：
- `sign` — 必须从 **Network 请求头** 中提取
- `jsToken` — 同上
- `adToken` — 同上

**提取步骤：**
1. `chrome-devtools__list_network_requests` → 过滤 `xhr`/`fetch`，找 `share/streaming` URL
2. `chrome-devtools__get_network_request` → 获取请求的完整 URL 和 Request Headers
3. 从 Request Headers 中提取 `Cookie` 字符串（包含 BDUSS 等全部认证 cookie）
4. 从 URL query string 中提取 `sign=`、`jsToken=`、`adToken=` 的值

### 3.3 M3U8 响应格式

响应体是 MPEG-TS 分片列表：
```
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10,
https://bdct06.baidupcs.com/video/netdisk-videotran-xxx/{MD5}_1_ts/{ETAG}?ts_size=6291232&...&range=0-341031&...
#EXTINF:10,
https://bdct06.baidupcs.com/video/netdisk-videotran-xxx/{MD5}_1_ts/{ETAG}?ts_size=6291232&...&range=341032-605359&...
...
```

每个分片 URL 中的 `range=` 参数是该分片在完整视频中的字节偏移量。

**太卜风水术01.mp4 实际数据：**
- 总时长：24分34秒（1474秒）
- 分片数：223 个
- 每个分片时长：约10秒
- 文件大小：66.35 MB（标称）/ 69.57 MB（实际）

### 3.4 并发下载策略

```python
# 8线程并发下载，缓存已完成的分片
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
    futures = {ex.submit(download_segment, (i, url)): i for i, url in enumerate(segment_urls)}
```

**注意：** `sign` 和 `jsToken` 有效期约几分钟。完整下载 223 个分片约需 5-10 分钟，在此期间 token 可能过期。若遇到 502/403，逐步重新请求 M3U8（触发浏览器发起新请求刷新 token），增量补充缺失的分片。

### 3.5 TS → MP4 合并

```python
with open(output_mp4, 'wb') as out:
    for sf in sorted(os.listdir(SEGMENTS_DIR), key=lambda x: int(...)):
        with open(os.path.join(SEGMENTS_DIR, sf), 'rb') as inp:
            out.write(inp.read())
```

MPEG-TS 流可以直接二进制拼接，不需要重新编码。

---

## 四、字幕提取原理

### 4.1 百度 AI 字幕接口

视频播放时百度自动请求字幕，URL 模式：
```
https://pan.baidu.com/share/streaming
  ?...（同 streaming URL）...
  &type=M3U8_SUBTITLE_SRT
```

响应是纯 SRT 文本（无 M3U8 包装），直接保存即可。

### 4.2 SRT 解析

```python
def parse_srt(srt_text):
    entries = []
    for block in re.split(r'\n\n+', srt_text.strip()):
        lines = block.split('\n')
        if len(lines) >= 3 and re.match(r'\d+$', lines[0]) and '-->' in lines[1]:
            tc = lines[1].split('-->')[0].strip()
            h, m, s = map(float, tc.split(':'))
            entries.append({'time': h*3600+m*60+s, 'text': '\n'.join(lines[2:])})
    return entries
```

太卜风水术01.mp4 字幕：467条，覆盖 00:00 ~ 24:14。

---

## 六、关键帧截图

### 6.1 方法：浏览器 JS 控制 video.currentTime

```javascript
// 跳转到指定秒数
chrome-devtools__evaluate_script(function=`() => {
  var video = document.querySelector('video');
  if (video) { video.currentTime = 120; video.play(); return 'seeked'; }
  return 'no video';
}`)

// 截图
chrome-devtools__take_screenshot(filePath="/tmp/frame_2min.png")
```

**注意：** 视频必须已加载（等待 `wait_for` 确认时间显示更新）。浏览器必须保持在视频页面。

### 6.2 推荐截帧时间点
每 2 分钟截一张：0:30, 2:00, 4:00, 6:00, 8:00, 10:00, 12:00, 14:00, 16:00, 18:00, 20:00, 22:00

---

## 七、文件清理

```python
import os, shutil

for path in [video_mp4, segments_dir]:
    if os.path.isfile(path): os.remove(path)
    elif os.path.isdir(path): shutil.rmtree(path)
```

**保留：** 字幕 `.srt`、全量转录 `.json`、详细文稿 `.txt`、ASR 记录 `.docx`、总结报告 `.docx`、截帧图片

---

## 八、已知限制

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| `sign` 几分钟过期 | JS 动态生成，HttpOnly | 重新从 DevTools 获取新 URL |
| 视频分片不完整 | 百度 streaming 按需加载 | 滑动进度条触发更多分片 |
| 无法提取音频 | Headless Chrome AudioNode 限制 | 使用百度内置 AI 字幕代替 |
| 验证码阻挡登录 | 百度安全策略 | 请求用户手动输入验证码 |

---

## 九、相关文件路径

| 文件 | 路径 |
|------|------|
| 下载器脚本 | `/home/adambb/.openclaw/workspace_soft/baidu_pan_downloader.py` |
| 字幕文件 | `/tmp/baidu_test/taibu_subtitles.srt` |
| 部分视频 | `/mnt/c/Users/Adambb/Desktop/太卜风水术01_full.mp4` (37.74 MB / ~16分钟) |

---

*文档版本：2026-06-08 | 基于太卜风水术01实战验证*