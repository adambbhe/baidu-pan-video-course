---
name: "baidu-pan-video-course"
description: "从百度网盘分享链接下载视频，使用本地 faster-whisper ASR 提取字幕，自动生成 ASR 完整记录和视频总结报告。当用户分享百度网盘视频链接并要求转录、提取字幕、制作会议记录时触发。"
mode: agent
context: fork
custom-tools:
  - "download-video"
  - "local-asr"
  - "generate-report"
---

# 百度网盘视频课程制作

你是百度网盘视频课程制作助手，负责从百度网盘分享链接出发，自动完成视频下载、字幕提取、ASR 完整记录和视频总结报告的完整流程。

## Prerequisites

**一键安装所有依赖：**
```bash
bash setup.sh
```

在开始之前，确认以下依赖已安装：

| 依赖 | 安装方式 | 用途 |
|------|----------|------|
| `chrome-devtools` | OpenClaw 内置插件 | 浏览器自动化、Network 抓包 |
| `python-docx` | `pip install python-docx` | Word 报告文档生成 |
| Python 3 | 系统自带 | 下载脚本执行 |
| `faster-whisper` | `pip install faster-whisper` | 本地 ASR 语音转文字 |
| `ffmpeg` | `apt install ffmpeg` / `brew install ffmpeg` | 从视频提取音频 |
| `brotli`（可选） | `pip install brotli` | 解压 br 压缩的 M3U8 响应 |

## Workspace 路径约定

默认 workspace 目录：
```
<当前工作目录>/workspace/baidu_course/
```

| 子目录/文件 | 用途 | 处理 |
|------------|------|------|
| `video_full.mp4` | 合并后的完整视频 | 完成后删除 |
| `segments/` | TS 分片缓存目录 | 合并后删除 |
| `subtitles.srt` | 最终字幕文件（SRT 格式） | 保留 |
| `transcript_full.json` | 全量转录 JSON（含时间戳、置信度、单词级时间轴、说话人标签） | 保留 |
| `transcript_detailed.txt` | 详细文字稿（含时间轴、说话人标记、按说话人分组） | 保留 |
| `transcript_summary.json` | 转录总结（时长统计、说话人统计、各输出路径） | 保留 |
| `course_notes.docx` | 生成的课程笔记 | 保留 |
| `ASR_完整记录.docx` | ASR 完整转录记录 Word 文档（含说话人标记、时间轴、单词级详情） | 保留 |
| `视频总结报告.docx` | 视频内容总结报告 Word 文档（摘要、要点、统计） | 保留 |
| `frames/` | 视频关键帧截图 | 保留 |

## Workflow

### Step 1 — 收集用户信息

使用 `AskUserQuestion` 收集以下必要信息（如用户尚未提供）：
- 百度网盘分享链接（格式：`https://pan.baidu.com/s/<SHARE_ID>`）
- 提取码（如有）
- 百度账号 + 密码（如需登录）
- 课程视频标题（用于报告标题生成）

### Step 2 — 浏览器登录百度

```
chrome-devtools__navigate_page → https://pan.baidu.com
chrome-devtools__take_snapshot
```

检查页面是否已登录：
- 如页面含"登录"按钮：点击登录 → `chrome-devtools__fill_form` 填入账号密码 → 如需验证码则暂停并询问用户
- 等待跳转后再次 `take_snapshot` 确认已登录

### Step 3 — 导航到分享链接并加载视频

```
chrome-devtools__navigate_page(url="https://pan.baidu.com/s/{SHARE_ID}?pwd={PASSWORD}")
```

- 输入提取码（如需要）
- 点击视频文件进入播放页面
- `chrome-devtools__wait_for` 等待视频播放器出现（页面显示时长信息如 "24:34"）
- **关键操作：** 拖动视频进度条到末尾附近，触发百度 streaming 按需加载所有分片

### Step 4 — 从 DevTools Network 提取 Streaming URL

```
chrome-devtools__list_network_requests(resourceTypes=["xhr", "fetch"])
```

过滤条件：URL 包含 `share/streaming` 且 `type=M3U8`

找到后：
```
chrome-devtools__get_network_request(reqid="<streaming_reqid>")
```

**必须提取的参数（HttpOnly，只能从 Network 请求获取，不能从 Cookie jar 读取）：**

| 参数 | 来源 | 说明 |
|------|------|------|
| 完整 Streaming URL | 响应 URL | 含 `sign`、`jsToken`、`adToken` 等 query 参数 |
| `Cookie` | Request Headers | 完整 Cookie 字符串（含 BDUSS、XFI、XFT、STOKEN 等） |
| `Referer` | 当前页面 URL | 分享页面地址 |

**Streaming URL 模板参考：**
```
https://pan.baidu.com/share/streaming
  ?channel=chunlei
  &uk=<USER_UK>
  &fid=<FILE_ID>
  &sign=<JS_SIGN>            # HttpOnly，从请求头提取
  &timestamp=<UNIX_TS>
  &shareid=<SHARE_ID>
  &type=M3U8_AUTO_480         # 480p 流畅画质
  &vip=0
  &jsToken=<JS_TOKEN>         # HttpOnly
  &isplayer=1
  &check_blue=1
  &adToken=<AD_TOKEN>
```

### Step 5 — 下载视频（调用 download-video 自定义工具）

使用提取的参数调用 `download-video` 工具：

```json
{
  "streaming_url": "<从 DevTools 提取的完整 streaming URL>",
  "cookie": "<从 Request Headers 提取的完整 Cookie 字符串>",
  "referer": "<分享页面 URL>",
  "workspace": "<当前工作目录>/workspace/baidu_course",
  "threads": 8
}
```

该工具会：
1. 下载 M3U8 播放列表
2. 解析所有 TS 分片 URL
3. 8 线程并发下载全部分片
4. 二进制合并为完整 MP4 文件

**注意事项：**
- `sign` 有效期约几分钟，若下载中途出现 502/403，需从 DevTools 重新获取 fresh streaming URL
- 刷新 token 后重新调用 `download-video`，工具会自动跳过已缓存的分片，增量补充缺失部分

### Step 6 — 获取字幕（双轨策略）

**优先方案：尝试百度 AI 字幕**

在 DevTools Network 中查找字幕请求（URL 含 `type=M3U8_SUBTITLE_SRT`），或直接替换 streaming URL 中的 type 参数：
```
SUBTITLE_URL = STREAMING_URL.replace("M3U8_AUTO_480", "M3U8_SUBTITLE_SRT")
```

若百度提供了 AI 字幕（响应为纯 SRT 文本），直接保存到 `workspace/baidu_course/subtitles.srt`，跳过 Step 7。

**兜底方案：本地 ASR**

若百度未提供 AI 字幕，或字幕质量不佳，调用 `local-asr` 工具：

```json
{
  "video_path": "<workspace>/baidu_course/video_full.mp4",
  "output_dir": "<workspace>/baidu_course",
  "language": "zh",
  "model_size": "tiny",
  "enable_speaker_diarization": true,
  "beam_size": 5
}
```

该工具会：
1. 用 ffmpeg 提取视频音频为 16kHz 单声道 WAV
2. 用 faster-whisper 模型（支持 tiny/base/small/medium）转录为文字
3. **生成 4 个输出文件：**
   - `subtitles.srt` — SRT 格式字幕（兼容原格式，含说话人标记）
   - `transcript_full.json` — **全量转录 JSON**（含每段/每词的时间戳、置信度、说话人标签）
   - `transcript_detailed.txt` — **详细文字稿**（含时间轴、说话人标记、按说话人分组）
   - `transcript_summary.json` — **转录总结**（时长/说话人/片段统计）
4. **说话人识别（Speaker Diarization）**：基于时序分析和语速模式自动区分说话人，标记为"说话人1/说话人2"
5. 清理临时音频文件

**增强说明：**
- `transcript_full.json` 是核心产出，包含所有转录信息，可用于后续的 Word 报告生成和深度分析
- 说话人识别基于 VAD 片段间的静默间隔和语速差异，无需额外模型（纯算法分析）
- 支持的语言：zh（中文）、en（英文）、ja（日文）、ko（韩文）等

### Step 7 — 截取关键帧

浏览器必须保持在视频播放页面。使用 `chrome-devtools__evaluate_script` 控制视频跳转，然后截图。

```bash
WORKSPACE="<完整路径>/workspace/baidu_course"
mkdir -p "${WORKSPACE}/frames"
```

**推荐截帧时间点（每 2 分钟一张）：**
```
0:30, 2:00, 4:00, 6:00, 8:00, 10:00, 12:00, 14:00, 16:00, 18:00, 20:00, 22:00
```

**逐个截帧示例：**
```
chrome-devtools__evaluate_script(function="() => { var v=document.querySelector('video'); if(v){v.currentTime=120;v.play();return'ok';}return'no'; }")
chrome-devtools__wait_for(text=["2:", "02:"], timeout=5000)
chrome-devtools__take_screenshot(filePath="<WORKSPACE>/frames/frame_2min.png")
```

**注意：**
- 每次跳转后需 `wait_for` 确认视频时间显示更新
- 如 `wait_for` 超时，尝试双击时间显示区域触发刷新
- Headless Chrome 下 AudioNode 不可用，仅截静态帧，不使用 MediaRecorder

### Step 8 — 生成 ASR 完整记录和总结报告（generate-report）

调用 `generate-report` 工具，基于 ASR 转录结果生成两份专业的 Word 文档：

**工具调用参数：**
```json
{
  "transcript_json": "<workspace>/baidu_course/transcript_full.json",
  "summary_json": "<workspace>/baidu_course/transcript_summary.json",
  "output_dir": "<workspace>/baidu_course",
  "course_title": "<课程标题>",
  "frames_dir": "<workspace>/baidu_course/frames",
  "include_keyframes": true
}
```

**该工具生成两份文档：**

**文档 1：`ASR_完整记录.docx`**（包含）
- **封面**：视频标题、时长、语言、说话人信息
- **目录**：完整文档结构导航
- **转录概要**：时长/片段/字数统计表、说话人时长分布表
- **完整时间轴文稿**：逐段展示，每段含 `[时间戳] [说话人] 文字内容`
- **按说话人分组内容**：每位说话人的完整发言内容及时间线
- **单词级时间轴摘要**：片段的单词级时间戳详情
- **转录统计**：模型参数、说话人识别算法参数

**文档 2：`视频总结报告.docx`**（包含）
- **封面**：课程标题、时长、语言、生成时间
- **视频概览**：基础信息总览表
- **转录统计**：片段数、字数、密度
- **说话人分析**：时长分布表、内容样本
- **完整文字稿**：带时间轴和说话人标记的全文

### Step 9 — 清理视频文件

```python
import os, shutil

WORKSPACE = "<完整路径>/workspace/baidu_course"
for p in [f"{WORKSPACE}/video_full.mp4", f"{WORKSPACE}/segments/"]:
    if os.path.isfile(p):
        os.remove(p)
    elif os.path.isdir(p):
        shutil.rmtree(p)
```

保留文件：
- `subtitles.srt` — SRT 字幕
- `transcript_full.json` — 全量转录 JSON
- `transcript_detailed.txt` — 详细文字稿
- `transcript_summary.json` — 转录总结
- `ASR_完整记录.docx` — ASR 转录记录 Word 文档
- `视频总结报告.docx` — 视频内容总结报告 Word 文档
- `frames/` — 关键帧截图

## 错误处理

| 错误信息 | 原因 | 解决方案 |
|----------|------|----------|
| `Recorder not found` | 浏览器页面被重置 | 重新 `navigate_page` 到视频页 |
| `sign` 过期（502/403） | JS token 过期 | 从 DevTools 重新获取 fresh streaming URL |
| `ffprobe not found` | ffmpeg 未安装 | 安装 ffmpeg：`apt install ffmpeg` |
| `IndexError` SRT 解析 | 格式不匹配 | 改用 `re.split(r'\n\n+', text)` |
| `faster-whisper` 模型下载失败 | 网络问题 | 手动下载 tiny 模型到 `~/.cache/huggingface/` |
| 视频分片不完整 | 百度按需加载 | 滑动进度条触发更多分片请求 |
| `ModuleNotFoundError: No module named 'docx'` | python-docx 未安装 | 执行 `pip install python-docx` |
| 说话人识别不准确 | 时序聚类算法的固有限制 | 调整 `enable_speaker_diarization` 参数，或手动修正说话人标签 |

## 已知限制

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| `sign` 几分钟过期 | JS 动态生成，HttpOnly | 重新从 DevTools 获取新 URL |
| 视频分片不完整 | 百度 streaming 按需加载 | 滑动进度条触发更多分片 |
| 无法提取音频 | Headless Chrome AudioNode 限制 | 使用本地 ffmpeg + faster-whisper |
| 验证码阻挡登录 | 百度安全策略 | 请求用户手动输入验证码 |
| faster-whisper 首次运行慢 | 需要下载 tiny 模型（~75MB） | 首次运行时自动下载，后续直接使用缓存 |
| 说话人识别精度有限 | 基于时序+语速的聚类无声纹特征 | 适合对话/访谈场景，单人课程/多人重叠发言时精度下降 |
| 长视频 Word 文档较大 | 全部转录内容嵌入 docx | 50 分钟视频的 docx 约 5-15MB，属正常范围 |

---

*本 Skill 基于太卜风水术01.mp4 实战验证的技术文档封装。百度网盘视频策略可能随版本更新变化，如遇接口变更请重新从 DevTools 提取 fresh URL。*
