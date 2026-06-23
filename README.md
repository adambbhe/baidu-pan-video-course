# Baidu Pan Video → Course Materials Skill

[![Tests](https://img.shields.io/badge/tests-52%2F52%20passed-brightgreen)](test/)
[![E2E](https://img.shields.io/badge/e2e-19%2F19%20passed-brightgreen)](test/integration/)

从百度网盘分享链接一键生成视频转录与分析报告：**下载视频 → 本地 ASR 提取字幕（含说话人识别） → ASR 完整记录 + 视频总结报告**。

## 功能

| 步骤 | 说明 |
|------|------|
| ① 浏览器登录 | OpenClaw chrome-devtools 自动登录百度网盘 |
| ② Network 抓包 | 拦截 `share/streaming` 请求，提取 M3U8 + Cookie |
| ③ 并发下载 `download-video` | 8 线程下载 TS 分片 → 二进制合并 MP4（断点续传） |
| ④ 百度 AI 字幕 | 优先获取百度服务端已有字幕（如有） |
| ⑤ 本地 ASR `local-asr` | faster-whisper 离线语音转文字 → SRT + 全量 JSON + 详细 TXT + 总结 |
| ⑥ 说话人识别 | 基于 VAD 时序聚类自动标记说话人1/说话人2 |
| ⑦ 关键帧截图 | 浏览器 JS 控制视频跳转，每 2 分钟截一张 |
| ⑧ ASR 报告 `generate-report` | ASR 完整记录.docx + 视频总结报告.docx |
| ⑨ 清理 | 删除视频文件，保留字幕/ASR记录/报告/截图 |

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
| `python-docx` | ASR 报告 Word 文档 | `pip install python-docx` |
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
    ├── local-asr/
    │   ├── tool.yaml               # ASR 工具参数定义（增强版：全量JSON+TXT+说话人）
    │   └── run.sh                  # ffmpeg → faster-whisper → SRT + JSON + TXT + 说话人
    └── generate-report/
        ├── tool.yaml               # 报告生成工具参数定义
        └── run.sh                  # ASR 完整记录.docx + 视频总结报告.docx
```

## 测试

```bash
# 单元测试 (52 项)
pwsh test/run_tests.ps1

# 端到端测试 (19 阶段)
python test/integration/run_e2e_test.py
```
