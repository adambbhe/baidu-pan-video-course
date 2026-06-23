#!/usr/bin/env python3
"""
generate-report: 基于 ASR 转录结果生成 Word 文档和 ASR 记录文档
===============================================================
从 stdin 读取 JSON 参数，使用 python-docx 生成：
  1. ASR_完整记录.docx — 完整 ASR 转录记录（含说话人标记、时间轴、按人分组）
  2. 视频总结报告.docx — 视频内容总结报告（摘要、要点、统计）

用法:
  echo '{"transcript_json":"...","summary_json":"...","output_dir":"...","course_title":"..."}' | python3 run.sh
"""

import sys
import os
import json
from pathlib import Path
from datetime import datetime

try:
    from docx import Document
    from docx.shared import Inches, Pt, Cm, RGBColor, Emu
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.enum.table import WD_TABLE_ALIGNMENT
    from docx.enum.section import WD_ORIENT
    from docx.oxml.ns import qn, nsdecls
    from docx.oxml import parse_xml
except ImportError:
    print("ERROR: python-docx not installed. Run: pip install python-docx", file=sys.stderr)
    sys.exit(1)


def read_input():
    """从 stdin 读取 JSON 参数"""
    raw = sys.stdin.read()
    if not raw:
        print("ERROR: No input received", file=sys.stderr)
        sys.exit(1)
    return json.loads(raw)


# ============== 文档样式工具函数 ==============

def set_cell_shading(cell, color):
    """设置单元格背景色"""
    shading = parse_xml(f'<w:shd {nsdecls("w")} w:fill="{color}"/>')
    cell._tc.get_or_add_tcPr().append(shading)


def add_styled_paragraph(doc, text, style='Normal', bold=False, size=None, color=None,
                          alignment=None, space_before=None, space_after=None):
    """添加带样式的段落"""
    p = doc.add_paragraph(style=style)
    run = p.add_run(text)
    if bold:
        run.bold = True
    if size:
        run.font.size = Pt(size)
    if color:
        run.font.color.rgb = RGBColor(*color)
    if alignment is not None:
        p.alignment = alignment
    if space_before is not None:
        p.paragraph_format.space_before = Pt(space_before)
    if space_after is not None:
        p.paragraph_format.space_after = Pt(space_after)
    return p, run


def add_code_block(doc, text, font_size=9):
    """添加代码/引用块样式的段落"""
    p = doc.add_paragraph()
    p.paragraph_format.left_indent = Cm(1)
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after = Pt(4)
    run = p.add_run(text)
    run.font.size = Pt(font_size)
    run.font.name = 'Consolas'
    run._element.rPr.rFonts.set(qn('w:eastAsia'), 'SimSun')
    return p


def add_colored_heading(doc, text, level=1, color=(44, 95, 45)):
    """添加带颜色的标题"""
    heading = doc.add_heading(text, level=level)
    for run in heading.runs:
        run.font.color.rgb = RGBColor(*color)
    return heading


def add_separator(doc):
    """添加分隔线"""
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(6)
    p.paragraph_format.space_after = Pt(6)
    run = p.add_run('─' * 60)
    run.font.size = Pt(8)
    run.font.color.rgb = RGBColor(150, 150, 150)


# ============== 文档 1: ASR 完整记录 ==============

def generate_asr_record(params):
    """生成完整 ASR 转录记录 Word 文档"""
    transcript_json = params['transcript_json']
    summary_json = params['summary_json']
    output_dir = params['output_dir']
    course_title = params.get('course_title', '视频课程')
    frames_dir = params.get('frames_dir', '')
    include_keyframes = params.get('include_keyframes', True)

    # 读取转录数据
    with open(transcript_json, 'r', encoding='utf-8') as f:
        data = json.load(f)

    with open(summary_json, 'r', encoding='utf-8') as f:
        summary = json.load(f)

    doc = Document()

    # ---- 页面设置 ----
    section = doc.sections[0]
    section.page_width = Cm(21)
    section.page_height = Cm(29.7)
    section.top_margin = Cm(2.5)
    section.bottom_margin = Cm(2.5)
    section.left_margin = Cm(2.5)
    section.right_margin = Cm(2.5)

    # ---- 封面 ----
    # 空行留白
    for _ in range(6):
        doc.add_paragraph()

    # 主标题
    p, run = add_styled_paragraph(
        doc, course_title,
        alignment=WD_ALIGN_PARAGRAPH.CENTER,
        size=28, bold=True, color=(44, 95, 45),
        space_after=6
    )

    # 副标题
    add_styled_paragraph(
        doc, 'ASR 完整转录记录',
        alignment=WD_ALIGN_PARAGRAPH.CENTER,
        size=18, color=(100, 100, 100),
        space_after=12
    )

    # 分隔线
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    run = p.add_run('━' * 40)
    run.font.color.rgb = RGBColor(44, 95, 45)

    # 元信息表格
    info_table = doc.add_table(rows=5, cols=2)
    info_table.alignment = WD_TABLE_ALIGNMENT.CENTER
    info_data = [
        ('视频文件', data.get('video_file', 'N/A')),
        ('音频时长', data.get('duration_formatted', 'N/A')),
        ('识别语言', f"{data.get('language', 'N/A')} (概率: {data.get('language_probability', 'N/A')})"),
        ('模型', f"{data.get('model', 'N/A')} ({data.get('device', 'N/A')})"),
        ('说话人数', str(summary.get('speaker_count', 0))),
    ]
    for i, (key, val) in enumerate(info_data):
        cell_k = info_table.cell(i, 0)
        cell_v = info_table.cell(i, 1)
        cell_k.text = key
        cell_v.text = str(val)
        set_cell_shading(cell_k, '2C5F2D')
        for p in cell_k.paragraphs:
            for r in p.runs:
                r.font.color.rgb = RGBColor(255, 255, 255)
                r.font.size = Pt(10)
                r.bold = True
        for p in cell_v.paragraphs:
            for r in p.runs:
                r.font.size = Pt(10)

    doc.add_page_break()

    # ---- 目录提示 ----
    add_styled_paragraph(
        doc, '目  录',
        size=18, bold=True, color=(44, 95, 45),
        alignment=WD_ALIGN_PARAGRAPH.CENTER,
        space_after=12
    )
    toc_items = [
        '一、转录概要',
        '二、完整时间轴文稿（含说话人标记）',
        '三、按说话人分组内容',
        '四、单词级时间轴（详细）',
        '五、转录统计',
    ]
    for item in toc_items:
        add_styled_paragraph(doc, item, size=12, color=(80, 80, 80), space_before=4, space_after=4)

    doc.add_page_break()

    # ---- 一、转录概要 ----
    add_colored_heading(doc, '一、转录概要', level=1)

    # 概要统计表
    stat_table = doc.add_table(rows=7, cols=2)
    stat_table.style = 'Light Grid Accent 1'
    stat_data = [
        ('总时长', summary.get('total_duration_formatted', 'N/A')),
        ('总片段数', str(summary.get('total_segments', 0))),
        ('总字数', str(summary.get('total_words', 0))),
        ('片段密度', f"{summary.get('segments_per_minute', 0)} 段/分钟"),
        ('说话人数', str(summary.get('speaker_count', 0))),
        ('模型', data.get('model', 'N/A')),
        ('生成时间', datetime.now().strftime('%Y-%m-%d %H:%M:%S')),
    ]
    for i, (key, val) in enumerate(stat_data):
        stat_table.cell(i, 0).text = key
        stat_table.cell(i, 1).text = str(val)
        for p in stat_table.cell(i, 0).paragraphs:
            for r in p.runs:
                r.bold = True
                r.font.size = Pt(10)

    doc.add_paragraph()

    # ---- 说话人统计 ----
    speaker_stats = summary.get('speaker_stats', {})
    if speaker_stats:
        add_colored_heading(doc, '说话人时长分布', level=2)
        sp_table = doc.add_table(rows=len(speaker_stats) + 1, cols=4)
        sp_table.style = 'Light Grid Accent 1'
        headers = ['说话人', '片段数', '总时长', '占比']
        for j, h in enumerate(headers):
            sp_table.cell(0, j).text = h
            for p in sp_table.cell(0, j).paragraphs:
                for r in p.runs:
                    r.bold = True

        total_dur = summary.get('total_duration_sec', 1)
        for row_idx, (sp, stats) in enumerate(sorted(speaker_stats.items()), 1):
            sp_table.cell(row_idx, 0).text = sp
            sp_table.cell(row_idx, 1).text = str(stats['segments'])
            dur_min = stats['duration'] / 60
            sp_table.cell(row_idx, 2).text = f"{dur_min:.1f} 分钟"
            pct = (stats['duration'] / total_dur) * 100
            sp_table.cell(row_idx, 3).text = f"{pct:.1f}%"

    doc.add_page_break()

    # ---- 二、完整时间轴文稿 ----
    add_colored_heading(doc, '二、完整时间轴文稿（含说话人标记）', level=1)

    segments = data.get('segments', [])
    # 每 20 段为一组，分页处理大量数据
    group_size = 50
    for group_idx in range(0, len(segments), group_size):
        group = segments[group_idx:group_idx + group_size]
        if group_idx > 0:
            doc.add_page_break()
            add_colored_heading(doc, f'二、完整时间轴文稿（续 {group_idx//group_size + 1}）', level=1)

        for seg in group:
            ts = f"{int(seg['start']//60):02d}:{int(seg['start']%60):02d}"
            speaker = seg.get('speaker', '')
            speaker_tag = f'[{speaker}] ' if speaker else ''

            # 时间戳（灰色小字）
            p = doc.add_paragraph()
            run_ts = p.add_run(f'[{ts}] ')
            run_ts.font.size = Pt(8)
            run_ts.font.color.rgb = RGBColor(150, 150, 150)

            # 说话人标签（绿色加粗）
            if speaker_tag:
                run_sp = p.add_run(speaker_tag)
                run_sp.font.size = Pt(9)
                run_sp.bold = True
                run_sp.font.color.rgb = RGBColor(44, 95, 45)

            # 文字内容
            run_text = p.add_run(seg['text'])
            run_text.font.size = Pt(10)
            p.paragraph_format.space_before = Pt(1)
            p.paragraph_format.space_after = Pt(1)

    doc.add_page_break()

    # ---- 三、按说话人分组 ----
    add_colored_heading(doc, '三、按说话人分组内容', level=1)

    if speaker_stats:
        speakers_content = {}
        for seg in segments:
            sp = seg.get('speaker', '未知')
            if sp not in speakers_content:
                speakers_content[sp] = []
            speakers_content[sp].append(seg)

        for sp_name in sorted(speakers_content.keys()):
            sp_segs = speakers_content[sp_name]
            sp_dur = sum(s['duration'] for s in sp_segs)
            stats = speaker_stats.get(sp_name, {})

            add_colored_heading(doc, f'{sp_name}', level=2)
            dur_min_total = sp_dur / 60
            pct = (sp_dur / max(summary.get('total_duration_sec', 1), 1)) * 100
            p = doc.add_paragraph()
            run = p.add_run(f'共 {len(sp_segs)} 段, {dur_min_total:.1f} 分钟, 占比 {pct:.1f}%')
            run.font.size = Pt(10)
            run.font.color.rgb = RGBColor(100, 100, 100)
            run.italic = True

            # 该说话人的所有文字
            all_text = ' '.join(s['text'] for s in sp_segs)
            add_code_block(doc, all_text, font_size=10)

            # 说话人的时间线
            p = doc.add_paragraph()
            run = p.add_run('时间线: ')
            run.bold = True
            run.font.size = Pt(9)
            timestamps = [f"{int(s['start']//60):02d}:{int(s['start']%60):02d}" for s in sp_segs]
            run_ts = p.add_run(' → '.join(timestamps))
            run_ts.font.size = Pt(8)
            run_ts.font.color.rgb = RGBColor(130, 130, 130)

    doc.add_page_break()

    # ---- 四、单词级时间轴摘要 ----
    add_colored_heading(doc, '四、单词级时间轴（摘要）', level=1)
    p = doc.add_paragraph()
    run = p.add_run('以下为每个转录片段的单词级时间轴（展示前 3 个单词的时间戳）：')
    run.font.size = Pt(10)
    run.font.color.rgb = RGBColor(100, 100, 100)

    for seg in segments[:30]:  # 仅展示前 30 段，避免文档过大
        ts = f"{int(seg['start']//60):02d}:{int(seg['start']%60):02d}"
        speaker = seg.get('speaker', '')
        text_preview = seg['text'][:80] + ('...' if len(seg['text']) > 80 else '')
        words_preview = seg.get('words', [])[:3]

        p = doc.add_paragraph()
        run_ts = p.add_run(f'[{ts}]')
        run_ts.font.size = Pt(8)
        run_ts.font.color.rgb = RGBColor(150, 150, 150)

        if speaker:
            run_sp = p.add_run(f' [{speaker}]')
            run_sp.font.size = Pt(9)
            run_sp.bold = True
            run_sp.font.color.rgb = RGBColor(44, 95, 45)

        run_text = p.add_run(f' {text_preview}')
        run_text.font.size = Pt(10)
        p.paragraph_format.space_before = Pt(2)
        p.paragraph_format.space_after = Pt(2)

        if words_preview:
            words_detail = ', '.join(
                f'"{w["word"]}" [{w["start"]:.1f}s-{w["end"]:.1f}s]'
                for w in words_preview if w.get('word')
            )
            p2 = doc.add_paragraph()
            run_w = p2.add_run(f'  单词: {words_detail}')
            run_w.font.size = Pt(8)
            run_w.font.color.rgb = RGBColor(130, 130, 130)
            p2.paragraph_format.space_before = Pt(0)
            p2.paragraph_format.space_after = Pt(1)

    doc.add_page_break()

    # ---- 五、转录统计 ----
    add_colored_heading(doc, '五、转录统计', level=1)

    # 转录参数表
    add_colored_heading(doc, '转录参数', level=2)
    params_table = doc.add_table(rows=5, cols=2)
    params_table.style = 'Light Grid Accent 1'
    tp_data = data.get('transcription_params', {})
    params_info = [
        ('模型大小', data.get('model', 'N/A')),
        ('设备', data.get('device', 'N/A')),
        ('束搜索大小', str(tp_data.get('beam_size', 'N/A'))),
        ('VAD 过滤', str(tp_data.get('vad_filter', 'N/A'))),
        ('单词级时间轴', str(tp_data.get('word_timestamps', 'N/A'))),
    ]
    for i, (key, val) in enumerate(params_info):
        params_table.cell(i, 0).text = key
        params_table.cell(i, 1).text = val
        for p in params_table.cell(i, 0).paragraphs:
            for r in p.runs:
                r.bold = True

    doc.add_paragraph()

    # 说话人识别参数
    sd = data.get('speaker_diarization', {})
    if sd.get('enabled'):
        add_colored_heading(doc, '说话人识别参数', level=2)
        sd_table = doc.add_table(rows=3, cols=2)
        sd_table.style = 'Light Grid Accent 1'
        sd_info = [
            ('启用状态', str(sd.get('enabled', False))),
            ('算法', sd.get('method', 'N/A')),
            ('识别说话人数', str(sd.get('speaker_count', 0))),
        ]
        for i, (key, val) in enumerate(sd_info):
            sd_table.cell(i, 0).text = key
            sd_table.cell(i, 1).text = val
            for p in sd_table.cell(i, 0).paragraphs:
                for r in p.runs:
                    r.bold = True

    doc.add_paragraph()
    add_separator(doc)
    p = doc.add_paragraph()
    run = p.add_run(f'本文档由 baidu-pan-video-course generate-report 工具自动生成\n')
    run.font.size = Pt(9)
    run.font.color.rgb = RGBColor(150, 150, 150)
    run2 = p.add_run(f'生成时间: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}')
    run2.font.size = Pt(9)
    run2.font.color.rgb = RGBColor(150, 150, 150)

    # ---- 保存 ----
    output_path = os.path.join(output_dir, 'ASR_完整记录.docx')
    os.makedirs(output_dir, exist_ok=True)
    doc.save(output_path)
    print(f"ASR 记录文档保存: {output_path}")
    return output_path


# ============== 文档 2: 视频总结报告 ==============

def generate_summary_report(params):
    """生成视频总结报告 Word 文档"""
    transcript_json = params['transcript_json']
    summary_json = params['summary_json']
    output_dir = params['output_dir']
    course_title = params.get('course_title', '视频课程')
    frames_dir = params.get('frames_dir', '')
    include_keyframes = params.get('include_keyframes', True)

    with open(transcript_json, 'r', encoding='utf-8') as f:
        data = json.load(f)

    with open(summary_json, 'r', encoding='utf-8') as f:
        summary = json.load(f)

    doc = Document()

    # 页面设置
    section = doc.sections[0]
    section.page_width = Cm(21)
    section.page_height = Cm(29.7)
    section.top_margin = Cm(2.5)
    section.bottom_margin = Cm(2.5)
    section.left_margin = Cm(2.5)
    section.right_margin = Cm(2.5)

    # ---- 封面 ----
    for _ in range(8):
        doc.add_paragraph()

    p, run = add_styled_paragraph(
        doc, course_title,
        alignment=WD_ALIGN_PARAGRAPH.CENTER,
        size=28, bold=True, color=(44, 95, 45),
        space_after=6
    )

    add_styled_paragraph(
        doc, '视频内容总结报告',
        alignment=WD_ALIGN_PARAGRAPH.CENTER,
        size=16, color=(100, 100, 100),
        space_after=8
    )

    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    run = p.add_run('━' * 30)
    run.font.color.rgb = RGBColor(44, 95, 45)

    info_lines = [
        f'时长: {summary.get("total_duration_formatted", "N/A")}',
        f'语言: {data.get("language", "N/A")}',
        f'说话人: {summary.get("speaker_count", 0)} 位',
        f'生成: {datetime.now().strftime("%Y-%m-%d %H:%M")}',
    ]
    for line in info_lines:
        add_styled_paragraph(
            doc, line,
            size=11, color=(80, 80, 80),
            alignment=WD_ALIGN_PARAGRAPH.CENTER,
            space_before=2
        )

    doc.add_page_break()

    # ---- 1. 视频概览 ----
    add_colored_heading(doc, '一、视频概览', level=1)

    overview_table = doc.add_table(rows=6, cols=2)
    overview_table.style = 'Light Grid Accent 1'
    overview_data = [
        ('视频名称', course_title),
        ('总时长', summary.get('total_duration_formatted', 'N/A')),
        ('识别语言', f"{data.get('language', 'N/A')} (置信度: {summary.get('language_probability', 'N/A')})"),
        ('总段数', str(summary.get('total_segments', 0))),
        ('说话人数', str(summary.get('speaker_count', 0))),
        ('生成时间', datetime.now().strftime('%Y-%m-%d %H:%M')),
    ]
    for i, (key, val) in enumerate(overview_data):
        overview_table.cell(i, 0).text = key
        overview_table.cell(i, 1).text = str(val)
        for p in overview_table.cell(i, 0).paragraphs:
            for r in p.runs:
                r.bold = True
                r.font.size = Pt(10)

    doc.add_paragraph()

    # ---- 2. 转录统计 ----
    add_colored_heading(doc, '二、转录统计', level=1)

    stat_table2 = doc.add_table(rows=4, cols=2)
    stat_table2.style = 'Light Grid Accent 1'
    stat_data2 = [
        ('总片段数', str(summary.get('total_segments', 0))),
        ('总字数', str(summary.get('total_words', 0))),
        ('片段密度', f"{summary.get('segments_per_minute', 0)} 段/分钟"),
        ('模型', data.get('model', 'N/A')),
    ]
    for i, (key, val) in enumerate(stat_data2):
        stat_table2.cell(i, 0).text = key
        stat_table2.cell(i, 1).text = str(val)
        for p in stat_table2.cell(i, 0).paragraphs:
            for r in p.runs:
                r.bold = True

    doc.add_paragraph()

    # ---- 3. 说话人分析 ----
    speaker_stats = summary.get('speaker_stats', {})
    if speaker_stats:
        add_colored_heading(doc, '三、说话人分析', level=1)
        p = doc.add_paragraph()
        run = p.add_run(f'共识别出 {len(speaker_stats)} 位说话人')
        run.font.size = Pt(11)

        sp_table2 = doc.add_table(rows=len(speaker_stats) + 1, cols=5)
        sp_table2.style = 'Light Grid Accent 1'
        headers2 = ['说话人', '片段数', '总时长(秒)', '占比(%)', '平均语速(字/段)']
        for j, h in enumerate(headers2):
            sp_table2.cell(0, j).text = h
            for p in sp_table2.cell(0, j).paragraphs:
                for r in p.runs:
                    r.bold = True

        total_dur = summary.get('total_duration_sec', 1)
        segments = data.get('segments', [])
        for row_idx, (sp, stats) in enumerate(sorted(speaker_stats.items()), 1):
            sp_table2.cell(row_idx, 0).text = sp
            sp_table2.cell(row_idx, 1).text = str(stats['segments'])
            sp_table2.cell(row_idx, 2).text = f"{stats['duration']:.1f}"
            sp_table2.cell(row_idx, 3).text = f"{(stats['duration'] / total_dur * 100):.1f}"
            avg_words = len(stats.get('text', '')) / max(stats['segments'], 1)
            sp_table2.cell(row_idx, 4).text = f"{avg_words:.1f}"

        doc.add_paragraph()

        # 说话人文字样本
        add_colored_heading(doc, '说话人内容样本', level=2)
        sp_sample = {}
        for seg in segments:
            sp = seg.get('speaker', '未知')
            if sp not in sp_sample:
                sp_sample[sp] = []
            sp_sample[sp].append(seg)

        for sp_name in sorted(sp_sample.keys()):
            sp_segs = sp_sample[sp_name]
            # 取前 5 段作为样本
            sample_texts = [s['text'] for s in sp_segs[:5]]
            sample = ' | '.join(sample_texts)
            p = doc.add_paragraph()
            run_sp = p.add_run(f'{sp_name}: ')
            run_sp.bold = True
            run_sp.font.size = Pt(10)
            run_sp.font.color.rgb = RGBColor(44, 95, 45)
            run_text = p.add_run(sample[:200] + ('...' if len(sample) > 200 else ''))
            run_text.font.size = Pt(10)

    # ---- 4. 完整文稿 ----
    doc.add_page_break()
    add_colored_heading(doc, '四、完整文字稿', level=1)

    segments = data.get('segments', [])
    for seg in segments:
        ts = f"{int(seg['start']//60):02d}:{int(seg['start']%60):02d}"
        speaker = seg.get('speaker', '')
        speaker_tag = f'[{speaker}] ' if speaker else ''

        p = doc.add_paragraph()
        run_ts = p.add_run(f'[{ts}] ')
        run_ts.font.size = Pt(8)
        run_ts.font.color.rgb = RGBColor(150, 150, 150)

        if speaker_tag:
            run_sp = p.add_run(speaker_tag)
            run_sp.font.size = Pt(9)
            run_sp.bold = True
            run_sp.font.color.rgb = RGBColor(44, 95, 45)

        run_text = p.add_run(seg['text'])
        run_text.font.size = Pt(10)
        p.paragraph_format.space_before = Pt(1)
        p.paragraph_format.space_after = Pt(1)

    # ---- Footer ----
    doc.add_paragraph()
    add_separator(doc)
    p = doc.add_paragraph()
    run = p.add_run(f'本文档由 baidu-pan-video-course generate-report 工具自动生成\n')
    run.font.size = Pt(9)
    run.font.color.rgb = RGBColor(150, 150, 150)
    run2 = p.add_run(f'生成时间: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}')
    run2.font.size = Pt(9)
    run2.font.color.rgb = RGBColor(150, 150, 150)

    # ---- 保存 ----
    output_path = os.path.join(output_dir, '视频总结报告.docx')
    os.makedirs(output_dir, exist_ok=True)
    doc.save(output_path)
    print(f"总结报告保存: {output_path}")
    return output_path


# ============== 主入口 ==============

def main():
    params = read_input()
    output_dir = params['output_dir']
    os.makedirs(output_dir, exist_ok=True)

    print(f"生成 ASR 记录文档和总结报告...")
    print(f"  输出目录: {output_dir}")
    print(f"  课程标题: {params.get('course_title', '视频课程')}")

    # 生成 ASR 完整记录
    asr_path = generate_asr_record(params)

    # 生成总结报告
    summary_path = generate_summary_report(params)

    # 输出结果
    result = {
        "status": "success",
        "asr_record_docx": asr_path,
        "summary_report_docx": summary_path,
        "output_dir": output_dir,
    }
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()