# Baidu Pan Video → Course Materials Skill

[![Tests](https://img.shields.io/badge/tests-52%2F52%20passed-brightgreen)](test/)
[![E2E](https://img.shields.io/badge/e2e-19%2F19%20passed-brightgreen)](test/integration/)

从百度网盘分享链接一键生成视频课件：**下载视频 → 本地 ASR 提取字幕 → 生成 PPT + Word 笔记**。

## 功能

| 步骤 | 说明 |
|------|------|
| ① 浏览器登录 | OpenClaw chrome-devtools 自动登录百度网盘 |
| ② Network 抓包 | 拦截 `share/streaming` 请求，提取 M3U8 + Cookie |
| ③ 并发下载 `download-video` | 8 线程下载 TS 分片 → 二进制合并 MP4（断点续传） |
| ④ 百度 AI 字幕 | 优先获取百度服务端已有字幕（如有） |
| ⑤ 本地 ASR `local-asr` | faster-whisper tiny 模型离线语音转文字 → SRT |
| ⑥ PPT 生成 | officecli 森林苔藓色系 8 页课件 |
| ⑦ 关键帧截图 | 浏览器 JS 控制视频跳转，每 2 分钟截一张 |
| ⑧ Word 笔记 | officecli DOCX 含目录 + 章节内容 + 截图 |
| ⑨ 清理 | 删除视频文件，保留字幕/课件/笔记 |

## 快速开始

```bash
# 1. 一键安装依赖
bash setup.sh

# 2. 运行测试
pwsh test/run_tests.ps1       # Windows
bash test/run_tests.sh        # Linux/macOS

# 3. 端到端集成测试
pwsh test/integration/run_integration.ps1
python test/integration/run_e2e_test.py
```

## 依赖

| 依赖 | 用途 | 安装 |
|------|------|------|
| `chrome-devtools` | 浏览器控制 | OpenClaw 内置 |
| `officecli` | PPT/DOCX 生成 | `curl -fsSL https://d.officecli.ai/install.sh \| bash` |
| Python 3 | 脚本执行 | 系统自带 |
| `faster-whisper` | 本地 ASR | `pip install faster-whisper` |
| `ffmpeg` | 音频提取 | `apt install ffmpeg` / `brew install ffmpeg` |

## 技能结构

```
baidu-pan-video-course/
├── SKILL.md                        # Skill 定义（agent 模式）
├── setup.sh                        # 一键环境安装
└── tools/
    ├── download-video/
    │   ├── tool.yaml               # 下载工具参数定义
    │   └── run.sh                  # M3U8 解析 → 分片下载 → MP4 合并
    └── local-asr/
        ├── tool.yaml               # ASR 工具参数定义
        └── run.sh                  # ffmpeg 提取音频 → faster-whisper 转录 → SRT
```

## 测试

```bash
# 单元测试 (52 项)
pwsh test/run_tests.ps1

# 端到端测试 (19 阶段)
python test/integration/run_e2e_test.py
```
